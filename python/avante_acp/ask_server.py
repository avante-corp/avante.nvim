"""An MCP server avante hosts so that any agent can ask the user a question.

Not every agent can. claude-agent-acp maps its `AskUserQuestion` tool onto
`elicitation/create` and works. cursor-agent decides its own AskQuestion tool
is unavailable and never sends `cursor/ask_question` at all -- the observable
symptom is that it gives up and asks its question as prose in the chat, and
Cursor's ACP docs name no client capability that turns it back on.

So avante supplies the capability itself rather than waiting on each vendor: a
one-tool MCP server, injected into `session/new`, whose handler routes to the
same `ui/elicitation` request the native path uses. One question UI for every
agent.

Transport is MCP Streamable HTTP because that is what agents advertise
(`mcpCapabilities.http`). It is hand-rolled for the same reason `jsonrpc.py`
is: this package ships one dependency, and what is needed here is one POST
route and four methods. Streamable HTTP permits answering a POST with a plain
JSON body, so none of the SSE machinery is required.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import secrets
from typing import Any

from . import forms
from .jsonrpc import (
    INTERNAL_ERROR,
    METHOD_NOT_FOUND,
    PARSE_ERROR,
    Peer,
    RpcError,
)

log = logging.getLogger(__name__)

SERVER_NAME = "avante"
SERVER_VERSION = "0.1.0"
TOOL_NAME = "ask_user_question"

#: Answered only when the agent sends no version of its own.
MCP_PROTOCOL_VERSION = "2025-06-18"

#: A question blocks on a human reading it, so it gets no deadline.
NO_DEADLINE = 0.0

#: Enough for any plausible question; a bound stops a malformed
#: Content-Length from making us buffer without limit.
MAX_BODY_BYTES = 1 << 20
MAX_HEADER_BYTES = 1 << 16

TOOL = {
    "name": TOOL_NAME,
    "title": "Ask the user a question",
    "description": (
        "Ask the user one or more multiple-choice questions and wait for the "
        "answer. Use this when you are blocked on a decision that is genuinely "
        "the user's to make -- one you cannot resolve from the request, the "
        "code, or a sensible default. Do not use it for choices with an obvious "
        "convention, or for facts you could look up yourself. The user can "
        "always write a free-text answer instead of picking one of the options, "
        "so do not add your own 'Other' or 'Something else' option."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "questions": {
                "type": "array",
                "minItems": 1,
                "maxItems": 4,
                "description": "The questions to ask, at most four.",
                "items": {
                    "type": "object",
                    "properties": {
                        "question": {
                            "type": "string",
                            "description": "The question, phrased in full and ending in a question mark.",
                        },
                        "header": {
                            "type": "string",
                            "description": "A short label for the question, at most 12 characters.",
                        },
                        "multiSelect": {
                            "type": "boolean",
                            "description": "Whether the user may choose more than one option.",
                        },
                        "options": {
                            "type": "array",
                            "minItems": 2,
                            "maxItems": 4,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "label": {
                                        "type": "string",
                                        "description": "The choice itself, in a few words.",
                                    },
                                    "description": {
                                        "type": "string",
                                        "description": "What picking this means, or its trade-off.",
                                    },
                                },
                                "required": ["label"],
                            },
                        },
                    },
                    "required": ["question", "options"],
                },
            }
        },
        "required": ["questions"],
    },
}


class AskServer:
    """A loopback MCP endpoint exposing `ask_user_question` for one agent."""

    def __init__(self, agent_id: str, peer: Peer) -> None:
        self._agent_id = agent_id
        self._peer = peer
        # The port is loopback, but every other process on the machine can
        # still reach it, and this tool puts text in front of the user.
        self.token = secrets.token_urlsafe(24)
        self.url: str | None = None
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> str:
        self._server = await asyncio.start_server(self._serve, host="127.0.0.1", port=0)
        port = self._server.sockets[0].getsockname()[1]
        self.url = f"http://127.0.0.1:{port}/mcp"
        log.debug("ask_user_question server for %s listening on %s", self._agent_id, self.url)
        return self.url

    async def stop(self) -> None:
        if self._server is None:
            return
        self._server.close()
        with contextlib.suppress(Exception):
            await self._server.wait_closed()
        self._server = None

    def mcp_server_entry(self) -> dict[str, Any]:
        """This server in the shape `session/new` wants."""
        return {
            "type": "http",
            "name": SERVER_NAME,
            "url": self.url,
            "headers": [{"name": "Authorization", "value": f"Bearer {self.token}"}],
        }

    # -- HTTP ------------------------------------------------------------

    async def _serve(self, reader: asyncio.StreamReader, writer: Any) -> None:
        try:
            while True:
                request = await _read_request(reader)
                if request is None:
                    return
                method, headers, body = request

                status, payload = await self._route(method, headers, body)
                await _write_response(writer, status, payload)

                if headers.get("connection", "").lower() == "close":
                    return
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            return
        except Exception:
            log.exception("ask_user_question connection failed")
        finally:
            with contextlib.suppress(Exception):
                writer.close()

    async def _route(
        self, method: str, headers: dict[str, str], body: bytes
    ) -> tuple[int, Any]:
        if headers.get("authorization", "") != f"Bearer {self.token}":
            return 401, {"error": "unauthorized"}

        if method != "POST":
            # Notably a GET, which is how a client opens the server-to-client
            # SSE stream. Refusing outright is better than accepting and never
            # sending anything, which would leave it waiting.
            return 405, {"error": "Only POST is supported on this endpoint"}

        try:
            message = json.loads(body)
        except json.JSONDecodeError:
            return 200, _error(None, PARSE_ERROR, "Parse error")

        if isinstance(message, list):
            responses = [await self._handle(item) for item in message if isinstance(item, dict)]
            responses = [item for item in responses if item is not None]
            return (200, responses) if responses else (202, None)

        if not isinstance(message, dict):
            return 200, _error(None, PARSE_ERROR, "Expected a JSON-RPC object")

        response = await self._handle(message)
        return (200, response) if response is not None else (202, None)

    # -- JSON-RPC --------------------------------------------------------

    async def _handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        message_id = message.get("id")
        if message_id is None:
            # A notification -- `notifications/initialized` and friends. Nothing
            # to answer, and answering anyway would be a protocol error.
            return None

        method = message.get("method") or ""
        params = message.get("params")
        if not isinstance(params, dict):
            params = {}

        try:
            result = await self._call(method, params)
        except RpcError as exc:
            return {"jsonrpc": "2.0", "id": message_id, "error": exc.to_wire()}
        except Exception as exc:
            log.exception("ask_user_question method %s failed", method)
            return _error(message_id, INTERNAL_ERROR, str(exc))

        return {"jsonrpc": "2.0", "id": message_id, "result": result}

    async def _call(self, method: str, params: dict[str, Any]) -> Any:
        if method == "initialize":
            requested = params.get("protocolVersion")
            return {
                "protocolVersion": requested
                if isinstance(requested, str)
                else MCP_PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [TOOL]}
        if method == "tools/call":
            return await self._call_tool(params)
        raise RpcError(METHOD_NOT_FOUND, f"Method not found: {method}")

    async def _call_tool(self, params: dict[str, Any]) -> dict[str, Any]:
        name = params.get("name")
        if name != TOOL_NAME:
            raise RpcError(METHOD_NOT_FOUND, f"Unknown tool: {name}")

        questions = _questions_from(params.get("arguments") or {})
        if not questions:
            # A tool error rather than a protocol error: the agent can read it
            # and retry with a well-formed call.
            return _text_result(
                f"{TOOL_NAME} needs at least one question, each with two or more options.",
                is_error=True,
            )

        request = forms.build_form(questions)
        try:
            answer = await self._peer.request(
                "ui/elicitation",
                {"agentId": self._agent_id, **request},
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            log.warning("ask_user_question could not reach Neovim (%s)", exc)
            return _text_result(
                "The question could not be shown to the user. Continue without an answer, "
                "stating the assumption you are making.",
                is_error=True,
            )

        return _result_from_answer(answer or {}, questions)


def _questions_from(arguments: dict[str, Any]) -> list[forms.Question]:
    """Validate the tool input into questions, dropping anything unusable."""
    questions = []

    for raw in arguments.get("questions") or []:
        if not isinstance(raw, dict):
            continue
        prompt = raw.get("question")
        if not prompt:
            continue

        options = []
        for index, option in enumerate(raw.get("options") or []):
            if not isinstance(option, dict):
                continue
            label = option.get("label")
            if not label:
                continue
            # The label is what the user picked, and it is what the agent needs
            # back; a positional id would just have to be mapped again.
            options.append(
                forms.Option(
                    value=str(label),
                    label=str(label),
                    description=option.get("description"),
                )
            )

        if len(options) < 2:
            continue

        questions.append(
            forms.Question(
                prompt=str(prompt),
                title=raw.get("header"),
                options=tuple(options),
                multi=bool(raw.get("multiSelect")),
                allow_custom=True,
            )
        )

    return questions


def _result_from_answer(
    answer: dict[str, Any], questions: list[forms.Question]
) -> dict[str, Any]:
    action = answer.get("action")

    if action == "accept":
        parsed = forms.read_answers(answer.get("content"), len(questions))
        lines = []
        for question, given in zip(questions, parsed):
            if not given.answered:
                continue
            text = given.custom or ", ".join(given.values)
            lines.append(f"Q: {question.prompt}\nA: {text}")
        if lines:
            return _text_result("\n\n".join(lines))
        # Accepted with nothing filled in is the same information as a skip.
        action = "decline"

    if action == "decline":
        return _text_result(
            "The user skipped the question. Proceed using your best judgement and "
            "say which assumption you made."
        )

    # Cancelled, or an action we do not recognise. Flagging it as an error stops
    # the agent inventing an answer the user never gave.
    return _text_result(
        "The user dismissed the question without answering. Stop and wait for "
        "further instructions rather than guessing.",
        is_error=True,
    )


def _text_result(text: str, *, is_error: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def _error(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


# -- minimal HTTP/1.1 ----------------------------------------------------


async def _read_request(
    reader: asyncio.StreamReader,
) -> tuple[str, dict[str, str], bytes] | None:
    """One request, or None at end of stream."""
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except asyncio.IncompleteReadError:
        return None
    except asyncio.LimitOverrunError:
        return None
    if not head or len(head) > MAX_HEADER_BYTES:
        return None

    lines = head.decode("latin-1").split("\r\n")
    request_line = lines[0].split(" ")
    if len(request_line) < 2:
        return None
    method = request_line[0].upper()

    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()

    try:
        length = int(headers.get("content-length", "0"))
    except ValueError:
        length = 0
    length = max(0, min(length, MAX_BODY_BYTES))

    body = await reader.readexactly(length) if length else b""
    return method, headers, body


async def _write_response(writer: Any, status: int, payload: Any) -> None:
    reason = {200: "OK", 202: "Accepted", 401: "Unauthorized", 405: "Method Not Allowed"}.get(
        status, "OK"
    )
    body = b"" if payload is None else json.dumps(payload, separators=(",", ":")).encode()

    head = [
        f"HTTP/1.1 {status} {reason}",
        f"Content-Length: {len(body)}",
        "Connection: keep-alive",
    ]
    if body:
        head.append("Content-Type: application/json")

    writer.write("\r\n".join(head).encode() + b"\r\n\r\n" + body)
    drain = getattr(writer, "drain", None)
    if drain is not None:
        await drain()
