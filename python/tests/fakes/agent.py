#!/usr/bin/env python3
"""A scriptable ACP agent for tests.

The prompt text is a command telling the agent what to do back at the client,
so a single binary can exercise every client-side capability:

    say:<text>        stream an agent_message_chunk
    think:<text>      stream an agent_thought_chunk
    plan              send a plan update
    permission        ask for permission to run a tool
    read:<path>       call fs/read_text_file
    write:<path>:<s>  call fs/write_text_file
    shell:<cmd>       create a terminal, wait for it, report its output
    shell-kill:<cmd>  create a terminal then kill it
    elicit:<message>  call elicitation/create
    ext:<method>      call a custom extension method
    hang              never answer (the client must time out or cancel)
    crash             exit the process mid-turn
"""

from __future__ import annotations

import asyncio
import os
import sys
from typing import Any

from acp import RequestError, run_agent
from acp.agent import AgentSideConnection
from acp.interfaces import Agent
from acp.schema import (
    AgentCapabilities,
    AgentMessageChunk,
    AgentThoughtChunk,
    AuthenticateResponse,
    ElicitationFormSessionMode,
    ElicitationSchema,
    InitializeResponse,
    ListSessionsResponse,
    NewSessionResponse,
    PermissionOption,
    PlanEntry,
    PromptResponse,
    SessionCapabilities,
    SessionInfo,
    SessionListCapabilities,
    SessionModeState,
    TextContentBlock,
)
from acp.schema import AgentPlanUpdate as PlanUpdate
from acp.schema import SessionMode


class ScriptedAgent(Agent):
    def __init__(self, conn: AgentSideConnection) -> None:
        self.conn = conn
        # Lets a test exercise the "agent cannot list sessions" branch.
        self.supports_list = os.environ.get("AVANTE_FAKE_NO_LIST") != "1"
        self.sessions: dict[str, dict[str, Any]] = {}
        self.cancelled: set[str] = set()
        self.counter = 0

    async def initialize(
        self, protocol_version: int, client_capabilities: Any = None, client_info: Any = None, **kw: Any
    ) -> InitializeResponse:
        self.client_capabilities = client_capabilities
        return InitializeResponse(
            protocolVersion=protocol_version,
            agentCapabilities=AgentCapabilities(
                loadSession=True,
                sessionCapabilities=SessionCapabilities(
                    list=SessionListCapabilities() if self.supports_list else None
                ),
            ),
        )

    async def authenticate(self, method_id: str, **kw: Any) -> AuthenticateResponse | None:
        if method_id == "bad-method":
            raise RequestError(code=-32000, message="Authentication failed")
        return None

    async def new_session(self, cwd: str, **kw: Any) -> NewSessionResponse:
        self.counter += 1
        session_id = f"sess-{self.counter}"
        self.sessions[session_id] = {"cwd": cwd, "mcpServers": kw.get("mcp_servers") or []}
        return NewSessionResponse(
            sessionId=session_id,
            modes=SessionModeState(
                currentModeId="agent",
                availableModes=[
                    SessionMode(id="agent", name="Agent"),
                    SessionMode(id="plan", name="Plan"),
                ],
            ),
        )

    async def load_session(self, cwd: str, session_id: str, **kw: Any) -> None:
        self.sessions.setdefault(session_id, {"cwd": cwd})
        await self._say(session_id, "replayed")
        return None

    async def list_sessions(
        self, cwd: str | None = None, cursor: str | None = None, **kw: Any
    ) -> ListSessionsResponse:
        # Paginated one session per page, so the client's cursor-following is
        # actually exercised rather than assumed.
        entries = [
            SessionInfo(sessionId=f"listed-{i}", cwd=cwd or "/tmp", title=f"Thread {i}",
                        updatedAt="2026-08-24T12:00:0%d+00:00" % i)
            for i in range(3)
        ]
        index = int(cursor) if cursor else 0
        page = entries[index : index + 1]
        next_cursor = str(index + 1) if index + 1 < len(entries) else None
        return ListSessionsResponse(sessions=page, nextCursor=next_cursor)

    async def set_session_mode(self, session_id: str, mode_id: str, **kw: Any) -> None:
        self.sessions.setdefault(session_id, {})["mode"] = mode_id
        return None

    async def cancel(self, session_id: str, **kw: Any) -> None:
        self.cancelled.add(session_id)

    async def ext_method(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "_test/echo":
            return {"echoed": params}
        raise RequestError.method_not_found(method)

    async def ext_notification(self, method: str, params: dict[str, Any]) -> None:
        return None

    # -- the interesting part -------------------------------------------

    async def prompt(self, session_id: str, prompt: list[Any], **kw: Any) -> PromptResponse:
        self.cancelled.discard(session_id)
        text = "".join(
            block.text for block in prompt if isinstance(block, TextContentBlock)
        )
        command, _, argument = text.partition(":")

        handler = getattr(self, f"_do_{command.replace('-', '_')}", None)
        if handler is None:
            await self._say(session_id, f"unknown command: {command}")
            return PromptResponse(stopReason="end_turn")

        return await handler(session_id, argument)

    async def _say(self, session_id: str, text: str) -> None:
        await self.conn.session_update(
            session_id=session_id,
            update=AgentMessageChunk(
                sessionUpdate="agent_message_chunk",
                content=TextContentBlock(type="text", text=text),
            ),
        )

    async def _do_say(self, session_id: str, argument: str) -> PromptResponse:
        await self._say(session_id, argument)
        return PromptResponse(stopReason="end_turn")

    async def _do_think(self, session_id: str, argument: str) -> PromptResponse:
        await self.conn.session_update(
            session_id=session_id,
            update=AgentThoughtChunk(
                sessionUpdate="agent_thought_chunk",
                content=TextContentBlock(type="text", text=argument),
            ),
        )
        return PromptResponse(stopReason="end_turn")

    async def _do_plan(self, session_id: str, argument: str) -> PromptResponse:
        await self.conn.session_update(
            session_id=session_id,
            update=PlanUpdate(
                sessionUpdate="plan",
                entries=[
                    PlanEntry(content="first", priority="high", status="in_progress"),
                    PlanEntry(content="second", priority="low", status="pending"),
                ],
            ),
        )
        return PromptResponse(stopReason="end_turn")

    async def _do_permission(self, session_id: str, argument: str) -> PromptResponse:
        result = await self.conn.request_permission(
            session_id=session_id,
            tool_call={"toolCallId": "tc-1", "title": "Delete everything", "kind": "delete"},
            options=[
                PermissionOption(optionId="yes", name="Allow", kind="allow_once"),
                PermissionOption(optionId="no", name="Reject", kind="reject_once"),
            ],
        )
        outcome = result.outcome
        chosen = getattr(outcome, "option_id", None) or outcome.outcome
        await self._say(session_id, f"permission={chosen}")
        return PromptResponse(stopReason="end_turn")

    async def _do_read(self, session_id: str, argument: str) -> PromptResponse:
        try:
            result = await self.conn.read_text_file(session_id=session_id, path=argument)
        except RequestError as exc:
            # RequestError carries its text via str(), not a .message attribute.
            await self._say(session_id, f"read-error={exc}")
            return PromptResponse(stopReason="end_turn")
        await self._say(session_id, f"read={result.content}")
        return PromptResponse(stopReason="end_turn")

    async def _do_write(self, session_id: str, argument: str) -> PromptResponse:
        path, _, content = argument.partition(":")
        await self.conn.write_text_file(session_id=session_id, path=path, content=content)
        await self._say(session_id, "wrote")
        return PromptResponse(stopReason="end_turn")

    async def _do_shell(self, session_id: str, argument: str) -> PromptResponse:
        created = await self.conn.create_terminal(
            session_id=session_id, command="/bin/sh", args=["-c", argument]
        )
        terminal_id = created.terminal_id
        exit_status = await self.conn.wait_for_terminal_exit(
            session_id=session_id, terminal_id=terminal_id
        )
        output = await self.conn.terminal_output(
            session_id=session_id, terminal_id=terminal_id
        )
        await self.conn.release_terminal(session_id=session_id, terminal_id=terminal_id)
        await self._say(
            session_id, f"exit={exit_status.exit_code} out={output.output.strip()}"
        )
        return PromptResponse(stopReason="end_turn")

    async def _do_shell_kill(self, session_id: str, argument: str) -> PromptResponse:
        created = await self.conn.create_terminal(
            session_id=session_id, command="/bin/sh", args=["-c", argument]
        )
        await self.conn.kill_terminal(
            session_id=session_id, terminal_id=created.terminal_id
        )
        output = await self.conn.terminal_output(
            session_id=session_id, terminal_id=created.terminal_id
        )
        signal_name = output.exit_status.signal if output.exit_status else None
        await self._say(session_id, f"killed={signal_name}")
        return PromptResponse(stopReason="end_turn")

    async def _do_elicit(self, session_id: str, argument: str) -> PromptResponse:
        response = await self.conn.create_elicitation(
            message=argument,
            mode=ElicitationFormSessionMode(
                sessionId=session_id,
                requestedSchema=ElicitationSchema(type="object", properties={}),
            ),
        )
        await self._say(session_id, f"elicit={response.action}")
        return PromptResponse(stopReason="end_turn")

    async def _do_ext(self, session_id: str, argument: str) -> PromptResponse:
        try:
            result = await self.conn.ext_method(argument, {"hello": "world"})
        except RequestError as exc:
            await self._say(session_id, f"ext-error={exc.code}")
            return PromptResponse(stopReason="end_turn")
        await self._say(session_id, f"ext={result}")
        return PromptResponse(stopReason="end_turn")

    async def _do_hang(self, session_id: str, argument: str) -> PromptResponse:
        for _ in range(600):
            await asyncio.sleep(0.1)
            if session_id in self.cancelled:
                return PromptResponse(stopReason="cancelled")
        return PromptResponse(stopReason="end_turn")

    async def _do_crash(self, session_id: str, argument: str) -> PromptResponse:
        sys.stderr.write("fake agent crashing on purpose\n")
        sys.stderr.flush()
        os._exit(9)


async def main() -> None:
    # run_agent wires up stdio correctly for the platform; doing it by hand
    # against the text-mode sys.stdout silently breaks the framing.
    await run_agent(
        lambda conn: ScriptedAgent(conn),
        use_unstable_protocol=os.environ.get("AVANTE_FAKE_UNSTABLE") == "1",
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, BrokenPipeError):
        pass
