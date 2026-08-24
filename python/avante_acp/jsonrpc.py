"""Newline-delimited JSON-RPC 2.0 peer for the Neovim <-> bridge hop.

This is deliberately not the ACP connection: the ACP side is handled by the
`acp` SDK. This is the small, stable protocol avante's Lua code speaks to the
bridge.

The invariants here exist because their absence is what made the previous
Lua-only implementation hang:

* every outbound request has a deadline, and expiring it resolves the caller
* every inbound request produces exactly one reply, including on handler crash
* unknown inbound methods get ``-32601`` rather than silence
* tearing down the peer fails all in-flight requests instead of orphaning them
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any

log = logging.getLogger(__name__)

# JSON-RPC 2.0
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
# avante-internal
TIMEOUT_ERROR = -32003
CONNECTION_CLOSED = -32004

DEFAULT_TIMEOUT = 30.0

RequestHandler = Callable[[dict[str, Any]], Awaitable[Any]]
NotificationHandler = Callable[[dict[str, Any]], Awaitable[None]]


class RpcError(Exception):
    """A JSON-RPC error, either received from the peer or raised by a handler."""

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data

    def to_wire(self) -> dict[str, Any]:
        err: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.data is not None:
            err["data"] = self.data
        return err

    @classmethod
    def method_not_found(cls, method: str) -> RpcError:
        return cls(METHOD_NOT_FOUND, f"Method not found: {method}")

    @classmethod
    def invalid_params(cls, message: str) -> RpcError:
        return cls(INVALID_PARAMS, message)


class Peer:
    """A bidirectional NDJSON JSON-RPC endpoint over a pair of asyncio streams."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: Any,
        *,
        default_timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._default_timeout = default_timeout

        self._next_id = 0
        self._pending: dict[int, asyncio.Future[Any]] = {}
        self._request_handlers: dict[str, RequestHandler] = {}
        self._notification_handlers: dict[str, NotificationHandler] = {}

        self._write_lock = asyncio.Lock()
        self._inflight: set[asyncio.Task[None]] = set()
        self._closed = False

    # -- registration ----------------------------------------------------

    def on_request(self, method: str, handler: RequestHandler) -> None:
        self._request_handlers[method] = handler

    def on_notification(self, method: str, handler: NotificationHandler) -> None:
        self._notification_handlers[method] = handler

    # -- outbound --------------------------------------------------------

    async def request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        """Send a request and await its result.

        ``timeout`` of ``None`` uses the peer default; ``0`` means no deadline,
        for calls whose duration is genuinely unbounded (a user staring at a
        permission prompt, an agent thinking).
        """
        if self._closed:
            raise RpcError(CONNECTION_CLOSED, f"Cannot send {method!r}: peer is closed")

        self._next_id += 1
        request_id = self._next_id
        future: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future

        await self._send(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
        )

        effective = self._default_timeout if timeout is None else timeout
        try:
            if effective and effective > 0:
                return await asyncio.wait_for(future, effective)
            return await future
        except asyncio.TimeoutError:
            raise RpcError(
                TIMEOUT_ERROR,
                f"Request {method!r} timed out after {effective}s",
                {"method": method, "timeout": effective},
            ) from None
        finally:
            self._pending.pop(request_id, None)

    async def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        if self._closed:
            log.debug("Dropping notification %s: peer is closed", method)
            return
        await self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    async def _send(self, message: dict[str, Any]) -> None:
        data = json.dumps(message, separators=(",", ":"), default=str)
        async with self._write_lock:
            self._writer.write(data.encode() + b"\n")
            drain = getattr(self._writer, "drain", None)
            if drain is not None:
                await drain()

    # -- inbound ---------------------------------------------------------

    async def run(self) -> None:
        """Read and dispatch until EOF, then release everything still waiting."""
        try:
            while True:
                line = await self._reader.readline()
                if not line:
                    break
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    message = json.loads(stripped)
                except json.JSONDecodeError:
                    log.warning("Discarding malformed JSON from peer: %r", stripped[:200])
                    continue
                if isinstance(message, dict):
                    self._dispatch(message)
                else:
                    log.warning("Discarding non-object JSON-RPC message: %r", message)
        finally:
            await self.close("Bridge connection closed")

    def _dispatch(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        message_id = message.get("id")

        if method is None:
            self._resolve(message_id, message)
            return

        params = message.get("params") or {}
        if not isinstance(params, dict):
            params = {"value": params}

        task = asyncio.create_task(self._handle_inbound(message_id, method, params))
        self._inflight.add(task)
        task.add_done_callback(self._inflight.discard)

    def _resolve(self, message_id: Any, message: dict[str, Any]) -> None:
        if message_id is None:
            log.warning("Discarding response with no id: %r", message)
            return
        future = self._pending.pop(message_id, None)
        if future is None or future.done():
            # Already timed out, or the peer answered twice. Either way there is
            # nobody left to hand this to.
            return
        error = message.get("error")
        if error:
            future.set_exception(
                RpcError(
                    error.get("code", INTERNAL_ERROR),
                    error.get("message", "Unknown error"),
                    error.get("data"),
                )
            )
        else:
            future.set_result(message.get("result"))

    async def _handle_inbound(
        self, message_id: Any, method: str, params: dict[str, Any]
    ) -> None:
        is_request = message_id is not None

        if method in self._notification_handlers and not is_request:
            try:
                await self._notification_handlers[method](params)
            except Exception:
                log.exception("Notification handler for %s failed", method)
            return

        handler = self._request_handlers.get(method)
        if handler is None:
            # A notification we do not know about is ignored, per spec. A
            # request MUST be answered or the caller blocks forever.
            if is_request:
                await self._reply_error(message_id, RpcError.method_not_found(method))
            else:
                log.debug("Ignoring unknown notification %s", method)
            return

        try:
            result = await handler(params)
        except RpcError as exc:
            if is_request:
                await self._reply_error(message_id, exc)
            else:
                log.warning("Notification handler %s errored: %s", method, exc)
            return
        except asyncio.CancelledError:
            if is_request:
                await self._reply_error(
                    message_id, RpcError(INTERNAL_ERROR, f"{method} was cancelled")
                )
            raise
        except Exception as exc:
            log.exception("Request handler for %s failed", method)
            if is_request:
                await self._reply_error(message_id, RpcError(INTERNAL_ERROR, str(exc)))
            return

        if is_request:
            await self._send({"jsonrpc": "2.0", "id": message_id, "result": result})

    async def _reply_error(self, message_id: Any, error: RpcError) -> None:
        await self._send(
            {"jsonrpc": "2.0", "id": message_id, "error": error.to_wire()}
        )

    # -- teardown --------------------------------------------------------

    async def close(self, reason: str = "Peer closed") -> None:
        if self._closed:
            return
        self._closed = True

        for future in list(self._pending.values()):
            if not future.done():
                future.set_exception(RpcError(CONNECTION_CLOSED, reason))
        self._pending.clear()

        for task in list(self._inflight):
            task.cancel()
        if self._inflight:
            await asyncio.gather(*self._inflight, return_exceptions=True)
        self._inflight.clear()
