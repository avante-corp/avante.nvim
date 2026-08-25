"""End-to-end: a real ACP connection to a real agent subprocess.

The agent is driven over genuine stdio JSON-RPC, and the Neovim side is a real
Peer. Only the editor itself is simulated, so these tests cover the framing,
the SDK wiring and our client implementation together.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import sys
from pathlib import Path
from typing import Any

import pytest
from acp import PROTOCOL_VERSION, spawn_agent_process, text_block
from acp.schema import ClientCapabilities, FileSystemCapabilities, Implementation

from avante_acp.client import BridgeClient
from avante_acp.jsonrpc import Peer
from avante_acp.terminal import TerminalManager

from .conftest import LoopbackWriter

FAKE_AGENT = Path(__file__).parent / "fakes" / "agent.py"


class FakeEditor:
    """Stands in for the Lua side: records events, answers UI requests."""

    def __init__(self, peer: Peer) -> None:
        self.peer = peer
        self.events: list[dict[str, Any]] = []
        self.permission_answer: dict[str, Any] | None = {"optionId": "yes"}
        self.permission_error: Exception | None = None
        self.files: dict[str, str] = {}
        self.written: dict[str, str] = {}
        self.elicitation_answer: dict[str, Any] = {"action": "accept", "content": {"a": 1}}
        self.ext_answer: dict[str, Any] = {"ok": True}

        peer.on_notification("event", self._on_event)
        peer.on_request("ui/permission", self._on_permission)
        peer.on_request("fs/read", self._on_read)
        peer.on_request("fs/write", self._on_write)
        peer.on_request("ui/elicitation", self._on_elicitation)
        peer.on_request("ui/ext", self._on_ext)

    async def _on_event(self, params: dict[str, Any]) -> None:
        self.events.append(params)

    async def _on_permission(self, params: dict[str, Any]) -> Any:
        if self.permission_error is not None:
            raise self.permission_error
        return self.permission_answer

    async def _on_read(self, params: dict[str, Any]) -> Any:
        from avante_acp.jsonrpc import RpcError

        path = params["path"]
        if path not in self.files:
            raise RpcError(-32002, f"No such file: {path}")
        return {"content": self.files[path]}

    async def _on_write(self, params: dict[str, Any]) -> Any:
        self.written[params["path"]] = params["content"]
        return {}

    async def _on_elicitation(self, params: dict[str, Any]) -> Any:
        return self.elicitation_answer

    async def _on_ext(self, params: dict[str, Any]) -> Any:
        return self.ext_answer

    def messages(self) -> list[str]:
        return [
            event["update"]["content"]["text"]
            for event in self.events
            if event.get("kind") == "agent_message_chunk"
        ]


class Harness:
    def __init__(self, editor: FakeEditor, conn: Any, session_id: str) -> None:
        self.editor = editor
        self.conn = conn
        self.session_id = session_id

    async def run(self, command: str) -> str:
        """Send a prompt, return the last agent message.

        The prompt response and the session/update notifications travel the
        same wire in order, but the receiving Peer dispatches notifications as
        separate tasks, so a response can be delivered before an earlier
        notification has been handled. Let those drain before asserting.
        (The real editor is unaffected: Lua queues everything through
        vim.schedule, which is FIFO.)
        """
        await self.conn.prompt(session_id=self.session_id, prompt=[text_block(command)])
        await self._settle()
        messages = self.editor.messages()
        return messages[-1] if messages else ""

    async def _settle(self, rounds: int = 5) -> None:
        seen = len(self.editor.events)
        for _ in range(rounds):
            await asyncio.sleep(0)
            if len(self.editor.events) == seen:
                # Two consecutive passes with no new events: the queue is empty.
                await asyncio.sleep(0)
                if len(self.editor.events) == seen:
                    return
            seen = len(self.editor.events)


@contextlib.asynccontextmanager
async def build_harness(*, auto_approve: bool = False, unstable: bool = False):
    lua_reader = asyncio.StreamReader()
    bridge_reader = asyncio.StreamReader()

    lua_peer = Peer(lua_reader, LoopbackWriter(bridge_reader), default_timeout=10.0)
    bridge_peer = Peer(bridge_reader, LoopbackWriter(lua_reader), default_timeout=10.0)

    editor = FakeEditor(lua_peer)
    pump = [asyncio.create_task(lua_peer.run()), asyncio.create_task(bridge_peer.run())]

    terminals = TerminalManager()
    client = BridgeClient("agent-1", bridge_peer, terminals, auto_approve=auto_approve)

    env = dict(os.environ)
    if unstable:
        env["AVANTE_FAKE_UNSTABLE"] = "1"

    async with spawn_agent_process(
        client,
        sys.executable,
        str(FAKE_AGENT),
        env=env,
        use_unstable_protocol=unstable,
    ) as (conn, proc):
        await conn.initialize(
            protocol_version=PROTOCOL_VERSION,
            client_capabilities=ClientCapabilities(
                fs=FileSystemCapabilities(readTextFile=True, writeTextFile=True),
                terminal=True,
            ),
            client_info=Implementation(name="avante", version="0.1.0"),
        )
        session = await conn.new_session(cwd=str(Path.cwd()), mcp_servers=[])
        try:
            yield Harness(editor, conn, session.session_id)
        finally:
            await terminals.release_all()
            await lua_peer.close()
            await bridge_peer.close()
            for task in pump:
                task.cancel()
            await asyncio.gather(*pump, return_exceptions=True)
            with contextlib.suppress(ProcessLookupError):
                proc.kill()


@pytest.fixture
async def harness():
    async with build_harness() as h:
        yield h


# -- session updates -----------------------------------------------------


async def test_agent_message_reaches_the_editor(harness):
    assert await harness.run("say:hello world") == "hello world"


async def test_thought_chunk_is_forwarded(harness):
    await harness.run("think:pondering")

    kinds = [event["kind"] for event in harness.editor.events]
    assert "agent_thought_chunk" in kinds


async def test_plan_update_is_forwarded_with_entries(harness):
    await harness.run("plan")

    plan = next(e for e in harness.editor.events if e["kind"] == "plan")
    assert [entry["content"] for entry in plan["update"]["entries"]] == ["first", "second"]


async def test_events_carry_agent_and_session_ids(harness):
    await harness.run("say:hi")

    event = harness.editor.events[-1]
    assert event["agentId"] == "agent-1"
    assert event["sessionId"] == harness.session_id


# -- permissions ---------------------------------------------------------


async def test_permission_grant_is_relayed(harness):
    harness.editor.permission_answer = {"optionId": "yes"}

    assert await harness.run("permission") == "permission=yes"


async def test_permission_rejection_is_relayed(harness):
    harness.editor.permission_answer = {"optionId": "no"}

    assert await harness.run("permission") == "permission=no"


async def test_permission_with_no_answer_cancels(harness):
    harness.editor.permission_answer = {}

    assert await harness.run("permission") == "permission=cancelled"


async def test_editor_failure_cancels_instead_of_hanging(harness):
    """The old client returned without replying here, blocking the agent."""
    harness.editor.permission_error = RuntimeError("sidebar is gone")

    result = await asyncio.wait_for(harness.run("permission"), timeout=15)

    assert result == "permission=cancelled"


async def test_auto_approve_answers_without_asking_the_editor():
    """auto_approve must not reach the editor at all."""
    async with build_harness(auto_approve=True) as h:
        h.editor.permission_error = RuntimeError("editor must not be consulted")

        assert await h.run("permission") == "permission=yes"


# -- filesystem ----------------------------------------------------------


async def test_read_routes_to_the_editor(harness):
    # Routed to Neovim so unsaved buffer contents win over what is on disk.
    harness.editor.files["/tmp/buffer.txt"] = "unsaved contents"

    assert await harness.run("read:/tmp/buffer.txt") == "read=unsaved contents"


async def test_read_error_surfaces_to_the_agent(harness):
    assert await harness.run("read:/nope.txt") == "read-error=No such file: /nope.txt"


async def test_write_routes_to_the_editor(harness):
    assert await harness.run("write:/tmp/out.txt:payload") == "wrote"
    assert harness.editor.written["/tmp/out.txt"] == "payload"


# -- terminals -----------------------------------------------------------


async def test_terminal_runs_and_reports_output(harness):
    """Previously this hung forever: terminal/* got no reply at all."""
    result = await asyncio.wait_for(harness.run("shell:echo hi"), timeout=20)

    assert result == "exit=0 out=hi"


async def test_terminal_reports_nonzero_exit(harness):
    assert await harness.run("shell:exit 7") == "exit=7 out="


async def test_terminal_kill_reports_signal(harness):
    assert await harness.run("shell-kill:sleep 30") == "killed=SIGKILL"


async def test_terminal_creation_emits_an_event(harness):
    await harness.run("shell:echo hi")

    assert any(e["kind"] == "terminal_created" for e in harness.editor.events)


# -- elicitation ---------------------------------------------------------


# NOTE: elicitation/create is gated behind use_unstable_protocol in
# agent-client-protocol 0.12.1, even though the v1 docs list it as a client
# method. Until it stabilises it cannot replace the AskUserQuestion shim on a
# stable connection, so these run against an explicitly unstable pair.


async def test_elicitation_accept():
    async with build_harness(unstable=True) as h:
        h.editor.elicitation_answer = {"action": "accept", "content": {"a": 1}}

        assert await h.run("elicit:pick one") == "elicit=accept"


async def test_elicitation_decline():
    async with build_harness(unstable=True) as h:
        h.editor.elicitation_answer = {"action": "decline"}

        assert await h.run("elicit:pick one") == "elicit=decline"


async def test_elicitation_is_unavailable_on_a_stable_connection(harness):
    """Documents the gate: on stable v1 the agent gets Method not found."""
    from acp import RequestError

    with pytest.raises(RequestError):
        await harness.conn.prompt(
            session_id=harness.session_id, prompt=[text_block("elicit:pick one")]
        )


# -- extensions ----------------------------------------------------------


async def test_ext_method_round_trips(harness):
    # A generic extension. cursor/* names are no longer suitable here: they have
    # dedicated translation (see test_vendor.py) and never reach ui/ext.
    harness.editor.ext_answer = {"answer": 42}

    assert await harness.run("ext:_vendor/echo") == "ext={'answer': 42}"


# -- lifecycle -----------------------------------------------------------


async def test_cancel_stops_a_running_turn(harness):
    turn = asyncio.create_task(
        harness.conn.prompt(
            session_id=harness.session_id, prompt=[text_block("hang")]
        )
    )
    await asyncio.sleep(0.3)
    await harness.conn.cancel(session_id=harness.session_id)

    response = await asyncio.wait_for(turn, timeout=15)

    assert response.stop_reason == "cancelled"


async def test_agent_crash_surfaces_as_an_error_not_a_hang(harness):
    """A dead agent must fail the pending prompt rather than stall the UI."""
    with pytest.raises(Exception):
        await asyncio.wait_for(
            harness.conn.prompt(
                session_id=harness.session_id, prompt=[text_block("crash")]
            ),
            timeout=15,
        )


async def test_set_session_mode(harness):
    await harness.conn.set_session_mode(session_id=harness.session_id, mode_id="plan")


async def test_load_session_replays(harness):
    await harness.conn.load_session(
        session_id=harness.session_id, cwd=str(Path.cwd()), mcp_servers=[]
    )

    assert "replayed" in harness.editor.messages()


async def test_extension_method_without_a_handler_errors_rather_than_hangs():
    """avante registers no ui/ext handler by default, so vendor extensions
    (cursor/ask_question, cursor/create_plan) must come back as an error the
    agent can act on -- never silence."""
    import asyncio as _asyncio

    async with build_harness() as h:
        # Remove the editor's ext handler to model the default configuration.
        h.editor.peer._request_handlers.pop("ui/ext", None)

        result = await _asyncio.wait_for(h.run("ext:_vendor/echo"), timeout=20)

        assert result.startswith("ext-error=")
