"""The Neovim-facing API.

Deliberately small: Lua should not need to know ACP's shape, only sessions and
prompts. Capability gating happens here, so Lua never has to ask "does this
agent support resume".
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from acp import text_block
from acp.schema import (
    AudioContentBlock,
    EmbeddedResourceContentBlock,
    ImageContentBlock,
    ResourceContentBlock,
    TextContentBlock,
)

from . import providers, threads
from .jsonrpc import Peer, RpcError
from .supervisor import Supervisor

log = logging.getLogger(__name__)

BRIDGE_PROTOCOL_VERSION = 1

# A prompt turn is bounded by session/cancel and streamed updates, never by a
# clock. Everything else gets the peer default.
NO_DEADLINE = 0.0


class Bridge:
    def __init__(self, peer: Peer) -> None:
        self.peer = peer
        self.supervisor = Supervisor(peer)
        self._register()

    def _register(self) -> None:
        peer = self.peer
        peer.on_request("bridge/hello", self.hello)
        peer.on_request("agent/spawn", self.agent_spawn)
        peer.on_request("agent/kill", self.agent_kill)
        peer.on_request("agent/status", self.agent_status)
        peer.on_request("agent/authenticate", self.agent_authenticate)
        peer.on_request("session/new", self.session_new)
        peer.on_request("session/load", self.session_load)
        peer.on_request("session/resume", self.session_resume)
        peer.on_request("session/list", self.session_list)
        peer.on_request("session/close", self.session_close)
        peer.on_request("session/delete", self.session_delete)
        peer.on_request("session/set_mode", self.session_set_mode)
        peer.on_request("session/set_config_option", self.session_set_config_option)
        peer.on_request("session/prompt", self.session_prompt)
        peer.on_request("threads/list", self.threads_list)
        peer.on_notification("session/cancel", self.session_cancel)

    # -- lifecycle -------------------------------------------------------

    async def hello(self, params: dict[str, Any]) -> dict[str, Any]:
        from . import __version__

        return {
            "bridgeProtocolVersion": BRIDGE_PROTOCOL_VERSION,
            "version": __version__,
            "providers": sorted(providers.PROVIDERS),
        }

    async def agent_spawn(self, params: dict[str, Any]) -> dict[str, Any]:
        provider = params.get("provider")
        if not provider:
            raise RpcError.invalid_params("agent/spawn requires 'provider'")

        handle = await self.supervisor.spawn(
            provider,
            command=params.get("command"),
            args=params.get("args"),
            env=params.get("env"),
            cwd=params.get("cwd"),
            auto_approve=bool(params.get("autoApprove")),
            unstable=bool(params.get("unstable")),
        )
        return {
            "agentId": handle.agent_id,
            "capabilities": handle.capabilities,
            "authMethods": handle.auth_methods,
            "pid": getattr(handle.process, "pid", None),
        }

    async def agent_kill(self, params: dict[str, Any]) -> dict[str, Any]:
        await self.supervisor.kill(_require(params, "agentId"))
        return {}

    async def agent_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return {"agents": self.supervisor.status()}

    async def agent_authenticate(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        method_id = _require(params, "methodId")
        # Logging in can involve a browser round-trip, so no deadline.
        await handle.conn.authenticate(method_id=method_id)
        return {}

    # -- sessions --------------------------------------------------------

    async def session_new(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        cwd = _require(params, "cwd")

        mcp_servers = params.get("mcpServers")
        if mcp_servers is None:
            # The Lua client hardcoded {} here, so configured MCP servers never
            # reached any agent. Fall back to discovering them from disk.
            mcp_servers = providers.discover_mcp_servers(handle.provider, cwd)

        result = await handle.conn.new_session(
            cwd=cwd,
            mcp_servers=mcp_servers,
            additional_directories=params.get("additionalDirectories"),
        )
        session_id = result.session_id
        self.supervisor.bind_session(handle.agent_id, session_id)
        return {
            "sessionId": session_id,
            "modes": _dump(result.modes),
            "configOptions": _dump(result.config_options),
            "mcpServers": mcp_servers,
        }

    async def session_load(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        if not handle.supports("loadSession"):
            raise RpcError(-32601, "Agent does not support session/load")

        session_id = _require(params, "sessionId")
        cwd = _require(params, "cwd")
        result = await handle.conn.load_session(
            session_id=session_id,
            cwd=cwd,
            mcp_servers=params.get("mcpServers")
            or providers.discover_mcp_servers(handle.provider, cwd),
        )
        self.supervisor.bind_session(handle.agent_id, session_id)
        return {"sessionId": session_id, **(_dump(result) or {})}

    async def session_resume(self, params: dict[str, Any]) -> dict[str, Any]:
        """Reconnect without replaying history.

        Distinct from session/load: the Lua client collapsed the two by
        rewriting sessionCapabilities.resume into loadSession, so resume-capable
        agents replayed their entire history instead of resuming.
        """
        handle = self.supervisor.get(_require(params, "agentId"))
        if not handle.supports("sessionCapabilities", "resume"):
            raise RpcError(-32601, "Agent does not support session/resume")

        session_id = _require(params, "sessionId")
        result = await handle.conn.resume_session(
            session_id=session_id, cwd=_require(params, "cwd")
        )
        self.supervisor.bind_session(handle.agent_id, session_id)
        return {"sessionId": session_id, **(_dump(result) or {})}

    async def session_list(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        if not handle.supports("sessionCapabilities", "list"):
            raise RpcError(-32601, "Agent does not support session/list")
        result = await handle.conn.list_sessions(
            cwd=params.get("cwd"), cursor=params.get("cursor")
        )
        return _dump(result) or {}

    async def session_close(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        session_id = _require(params, "sessionId")
        if handle.supports("sessionCapabilities", "close"):
            await handle.conn.close_session(session_id=session_id)
        await self.supervisor.terminals.release_session(session_id)
        self.supervisor.release_session(session_id, handle.agent_id)
        return {}

    async def session_delete(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.get(_require(params, "agentId"))
        if not handle.supports("sessionCapabilities", "delete"):
            raise RpcError(-32601, "Agent does not support session/delete")
        session_id = _require(params, "sessionId")
        await handle.conn.ext_method("session/delete", {"sessionId": session_id})
        self.supervisor.release_session(session_id, handle.agent_id)
        return {}

    async def session_set_mode(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.for_session(
            _require(params, "sessionId"), params.get("agentId")
        )
        await handle.conn.set_session_mode(
            session_id=params["sessionId"], mode_id=_require(params, "modeId")
        )
        return {}

    async def session_set_config_option(self, params: dict[str, Any]) -> dict[str, Any]:
        handle = self.supervisor.for_session(
            _require(params, "sessionId"), params.get("agentId")
        )
        result = await handle.conn.set_config_option(
            session_id=params["sessionId"],
            config_id=_require(params, "configId"),
            value=params.get("value"),
        )
        return _dump(result) or {}

    async def session_prompt(self, params: dict[str, Any]) -> dict[str, Any]:
        session_id = _require(params, "sessionId")
        handle = self.supervisor.for_session(session_id, params.get("agentId"))

        blocks = _content_blocks(params.get("prompt"))
        if not blocks:
            raise RpcError.invalid_params("session/prompt requires non-empty 'prompt'")

        result = await handle.conn.prompt(session_id=session_id, prompt=blocks)
        return {"stopReason": result.stop_reason, "usage": _dump(result.usage)}

    # -- threads ---------------------------------------------------------

    async def threads_list(self, params: dict[str, Any]) -> dict[str, Any]:
        """List local chat histories.

        Not ACP: this reads avante's own history storage. It lives here because
        doing it in Lua meant decoding gigabytes of JSON on Neovim's main loop
        every time the picker opened.
        """
        storage_path = _require(params, "storagePath")
        limit = params.get("limit")

        # Off the event loop: a cold build reads the whole history tree, and
        # session updates must keep flowing while it does.
        return await asyncio.to_thread(
            threads.list_threads,
            storage_path,
            limit=int(limit) if limit else None,
            force=bool(params.get("force")),
        )

    async def session_cancel(self, params: dict[str, Any]) -> None:
        session_id = params.get("sessionId")
        if not session_id:
            return
        try:
            handle = self.supervisor.for_session(session_id, params.get("agentId"))
        except RpcError:
            return
        await handle.conn.cancel(session_id=session_id)

    async def shutdown(self) -> None:
        await self.supervisor.shutdown()


def _require(params: dict[str, Any], key: str) -> Any:
    value = params.get(key)
    if value in (None, ""):
        raise RpcError.invalid_params(f"Missing required parameter: {key}")
    return value


def _content_blocks(prompt: Any) -> list[Any]:
    """Accept either a plain string or a list of ACP content blocks."""
    if prompt is None:
        return []
    if isinstance(prompt, str):
        return [text_block(prompt)] if prompt else []

    blocks: list[Any] = []
    for item in prompt:
        if isinstance(item, str):
            blocks.append(text_block(item))
            continue
        if not isinstance(item, dict):
            continue
        kind = item.get("type")
        model = {
            "text": TextContentBlock,
            "image": ImageContentBlock,
            "audio": AudioContentBlock,
            "resource_link": ResourceContentBlock,
            "resource": EmbeddedResourceContentBlock,
        }.get(kind)
        if model is None:
            continue
        try:
            blocks.append(model(**item))
        except Exception:
            log.warning("Discarding malformed %s content block", kind)
    return blocks


def _dump(model: Any) -> Any:
    if model is None:
        return None
    if isinstance(model, list):
        return [_dump(item) for item in model]
    if hasattr(model, "model_dump"):
        return model.model_dump(by_alias=True, exclude_none=True, mode="json")
    return model
