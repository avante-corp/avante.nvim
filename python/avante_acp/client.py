"""The ACP ``Client`` half: what the agent calls on us.

Every method here blocks the agent until it returns, so the governing rule is
that none of them may hang or propagate an exception. Anything that goes wrong
degrades to a defined answer (cancel the permission, error the file read) so the
agent can make progress or fail cleanly.
"""

from __future__ import annotations

import logging
from typing import Any

from acp import RequestError
from acp.interfaces import Client
from acp.schema import (
    AllowedOutcome,
    CreateTerminalResponse,
    DeniedOutcome,
    ReadTextFileResponse,
    RequestPermissionResponse,
    TerminalExitStatus,
    TerminalOutputResponse,
    WaitForTerminalExitResponse,
)

from . import vendor
from .jsonrpc import Peer, RpcError
from .terminal import TerminalManager, TerminalNotFound

log = logging.getLogger(__name__)

# Neovim-side UI calls are driven by a human, so they get no deadline. The user
# is allowed to stare at a permission prompt for as long as they like.
NO_DEADLINE = 0.0

# Filesystem calls round-trip to the editor and should be quick; if Neovim is
# wedged we would rather fail the read than stall the whole turn.
FS_TIMEOUT = 15.0


def _dump(model: Any) -> Any:
    """Convert a pydantic model to wire-shaped JSON, leaving plain data alone."""
    if hasattr(model, "model_dump"):
        return model.model_dump(by_alias=True, exclude_none=True, mode="json")
    return model


class BridgeClient(Client):
    """Forwards agent->client traffic to Neovim, except terminals which we own."""

    def __init__(
        self,
        agent_id: str,
        peer: Peer,
        terminals: TerminalManager,
        *,
        auto_approve: bool = False,
    ) -> None:
        self._agent_id = agent_id
        self._peer = peer
        self._terminals = terminals
        self._auto_approve = auto_approve

    # -- session updates -------------------------------------------------

    async def session_update(self, session_id: str, update: Any, **kwargs: Any) -> None:
        payload = _dump(update)
        kind = payload.get("sessionUpdate") if isinstance(payload, dict) else None
        await self._peer.notify(
            "event",
            {
                "agentId": self._agent_id,
                "sessionId": session_id,
                "kind": kind,
                "update": payload,
            },
        )

    # -- permissions -----------------------------------------------------

    async def request_permission(
        self, session_id: str, tool_call: Any, options: list[Any], **kwargs: Any
    ) -> RequestPermissionResponse:
        wire_options = [_dump(option) for option in options]

        if self._auto_approve:
            chosen = _first_option_of_kind(wire_options, ("allow_always", "allow_once"))
            if chosen is not None:
                return RequestPermissionResponse(
                    outcome=AllowedOutcome(outcome="selected", optionId=chosen)
                )

        try:
            answer = await self._peer.request(
                "ui/permission",
                {
                    "agentId": self._agent_id,
                    "sessionId": session_id,
                    "toolCall": _dump(tool_call),
                    "options": wire_options,
                },
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            # Neovim went away or refused. Cancelling is the only safe default:
            # it neither runs an unapproved tool nor leaves the agent blocked.
            log.warning("Permission request failed (%s); cancelling", exc)
            return RequestPermissionResponse(outcome=DeniedOutcome(outcome="cancelled"))

        option_id = (answer or {}).get("optionId")
        if not option_id:
            return RequestPermissionResponse(outcome=DeniedOutcome(outcome="cancelled"))
        return RequestPermissionResponse(
            outcome=AllowedOutcome(outcome="selected", optionId=option_id)
        )

    # -- filesystem ------------------------------------------------------

    async def read_text_file(
        self,
        session_id: str,
        path: str,
        line: int | None = None,
        limit: int | None = None,
        **kwargs: Any,
    ) -> ReadTextFileResponse:
        # Routed to Neovim rather than read here: only the editor knows about
        # unsaved buffer contents, and the agent must see what the user sees.
        try:
            result = await self._peer.request(
                "fs/read",
                {
                    "agentId": self._agent_id,
                    "sessionId": session_id,
                    "path": path,
                    "line": line,
                    "limit": limit,
                },
                timeout=FS_TIMEOUT,
            )
        except RpcError as exc:
            raise RequestError(code=exc.code, message=exc.message) from exc
        return ReadTextFileResponse(content=(result or {}).get("content", ""))

    async def write_text_file(
        self, session_id: str, path: str, content: str, **kwargs: Any
    ) -> None:
        try:
            await self._peer.request(
                "fs/write",
                {
                    "agentId": self._agent_id,
                    "sessionId": session_id,
                    "path": path,
                    "content": content,
                },
                timeout=FS_TIMEOUT,
            )
        except RpcError as exc:
            raise RequestError(code=exc.code, message=exc.message) from exc
        return None

    # -- terminals (handled entirely in-process) -------------------------

    async def create_terminal(
        self,
        session_id: str,
        command: str,
        args: list[str] | None = None,
        env: list[Any] | None = None,
        cwd: str | None = None,
        output_byte_limit: int | None = None,
        **kwargs: Any,
    ) -> CreateTerminalResponse:
        try:
            terminal_id = await self._terminals.create(
                session_id,
                command,
                args=args,
                env=env,
                cwd=cwd,
                output_byte_limit=output_byte_limit,
            )
        except FileNotFoundError as exc:
            raise RequestError(code=-32603, message=f"Command not found: {command}") from exc
        except OSError as exc:
            raise RequestError(code=-32603, message=str(exc)) from exc

        await self._peer.notify(
            "event",
            {
                "agentId": self._agent_id,
                "sessionId": session_id,
                "kind": "terminal_created",
                "update": {"terminalId": terminal_id, "command": command, "args": args or []},
            },
        )
        return CreateTerminalResponse(terminalId=terminal_id)

    async def terminal_output(
        self, session_id: str, terminal_id: str, **kwargs: Any
    ) -> TerminalOutputResponse:
        try:
            result = self._terminals.output(terminal_id)
        except TerminalNotFound as exc:
            raise _unknown_terminal(terminal_id) from exc
        status = result.get("exitStatus")
        return TerminalOutputResponse(
            output=result["output"],
            truncated=result["truncated"],
            exitStatus=TerminalExitStatus(**status) if status else None,
        )

    async def wait_for_terminal_exit(
        self, session_id: str, terminal_id: str, **kwargs: Any
    ) -> WaitForTerminalExitResponse:
        try:
            result = await self._terminals.wait_for_exit(terminal_id)
        except TerminalNotFound as exc:
            raise _unknown_terminal(terminal_id) from exc
        return WaitForTerminalExitResponse(
            exitCode=result["exitCode"], signal=result["signal"]
        )

    async def kill_terminal(self, session_id: str, terminal_id: str, **kwargs: Any) -> None:
        try:
            await self._terminals.kill(terminal_id)
        except TerminalNotFound as exc:
            raise _unknown_terminal(terminal_id) from exc
        return None

    async def release_terminal(self, session_id: str, terminal_id: str, **kwargs: Any) -> None:
        await self._terminals.release(terminal_id)
        return None

    # -- elicitation -----------------------------------------------------

    async def create_elicitation(self, message: str, mode: Any, **kwargs: Any) -> Any:
        """Structured user input. This is the supported replacement for the
        AskUserQuestion monkey-patch in scripts/acp-wrapper.mjs."""
        from acp.schema import CancelElicitationResponse

        try:
            answer = await self._peer.request(
                "ui/elicitation",
                {
                    "agentId": self._agent_id,
                    "message": message,
                    "mode": _dump(mode),
                },
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            log.warning("Elicitation failed (%s); cancelling", exc)
            return CancelElicitationResponse(action="cancel")

        return _elicitation_response(answer)

    async def complete_elicitation(self, elicitation_id: str, **kwargs: Any) -> None:
        await self._peer.notify(
            "event",
            {
                "agentId": self._agent_id,
                "kind": "elicitation_complete",
                "update": {"elicitationId": elicitation_id},
            },
        )

    # -- extensions ------------------------------------------------------

    async def ext_method(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """Custom ``_``-prefixed and vendor methods, e.g. Cursor's
        ``cursor/ask_question``. Unhandled ones must still be answered."""
        # Cursor's blocking extensions get translated into the shapes Neovim
        # already knows, so there is one question UI rather than one per vendor.
        if method == "cursor/ask_question":
            return await self._cursor_ask_question(params)
        if method == "cursor/create_plan":
            return await self._cursor_create_plan(params)

        try:
            result = await self._peer.request(
                "ui/ext",
                {"agentId": self._agent_id, "method": method, "params": params},
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            raise RequestError(code=exc.code, message=exc.message) from exc
        return result if isinstance(result, dict) else {}

    async def _cursor_ask_question(self, params: dict[str, Any]) -> dict[str, Any]:
        request = vendor.ask_question_to_elicitation(params)
        question_ids = request.pop("_questionIds", [])
        try:
            answer = await self._peer.request(
                "ui/elicitation",
                {"agentId": self._agent_id, **request},
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            log.warning("cursor/ask_question failed (%s); cancelling", exc)
            return {"outcome": {"outcome": "cancelled"}}
        return vendor.elicitation_to_ask_question(answer or {}, question_ids)

    async def _cursor_create_plan(self, params: dict[str, Any]) -> dict[str, Any]:
        summary = vendor.create_plan_summary(params)
        try:
            answer = await self._peer.request(
                "ui/plan_approval",
                {"agentId": self._agent_id, **summary},
                timeout=NO_DEADLINE,
            )
        except RpcError as exc:
            log.warning("cursor/create_plan failed (%s); cancelling", exc)
            return vendor.plan_response(None)
        return vendor.plan_response((answer or {}).get("accepted"))

    async def ext_notification(self, method: str, params: dict[str, Any]) -> None:
        if method == "cursor/update_todos":
            # Surface Cursor's todos through the same plan panel ACP plans use.
            await self._peer.notify(
                "event",
                {
                    "agentId": self._agent_id,
                    "kind": "plan",
                    "update": {
                        "sessionUpdate": "plan",
                        "entries": vendor.todos_to_plan_entries(params),
                    },
                },
            )
            return

        await self._peer.notify(
            "event",
            {
                "agentId": self._agent_id,
                "kind": "ext_notification",
                "update": {"method": method, "params": params},
            },
        )


def _unknown_terminal(terminal_id: str) -> RequestError:
    return RequestError(code=-32602, message=f"Unknown terminal: {terminal_id}")


def _first_option_of_kind(options: list[Any], kinds: tuple[str, ...]) -> str | None:
    for kind in kinds:
        for option in options:
            if isinstance(option, dict) and option.get("kind") == kind:
                return option.get("optionId")
    return None


def _elicitation_response(answer: dict[str, Any] | None) -> Any:
    from acp.schema import (
        AcceptElicitationResponse,
        CancelElicitationResponse,
        DeclineElicitationResponse,
    )

    action = (answer or {}).get("action")
    if action == "accept":
        return AcceptElicitationResponse(action="accept", content=(answer or {}).get("content"))
    if action == "decline":
        return DeclineElicitationResponse(action="decline")
    return CancelElicitationResponse(action="cancel")
