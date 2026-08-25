"""Drive the bridge the way Lua will: over the wire, by method name.

The agent spawned is the scriptable fake, so these exercise the real dispatch
table, the real supervisor and a real ACP connection.
"""

from __future__ import annotations

import asyncio
import contextlib
import sys
from pathlib import Path
from typing import Any

import pytest

from avante_acp.bridge import Bridge
from avante_acp.jsonrpc import Peer, RpcError

from .conftest import LoopbackWriter
from .test_client_e2e import FakeEditor

FAKE_AGENT = Path(__file__).parent / "fakes" / "agent.py"


class Nvim:
    """The Lua side: calls bridge methods, collects events."""

    def __init__(self, peer: Peer, editor: FakeEditor) -> None:
        self.peer = peer
        self.editor = editor

    async def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        return await self.peer.request(method, params or {}, timeout=30)

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self.peer.notify(method, params)

    def messages(self) -> list[str]:
        return self.editor.messages()


@pytest.fixture
async def nvim():
    nvim_reader = asyncio.StreamReader()
    bridge_reader = asyncio.StreamReader()

    nvim_peer = Peer(nvim_reader, LoopbackWriter(bridge_reader), default_timeout=30.0)
    bridge_peer = Peer(bridge_reader, LoopbackWriter(nvim_reader), default_timeout=30.0)

    editor = FakeEditor(nvim_peer)
    bridge = Bridge(bridge_peer)
    pump = [asyncio.create_task(nvim_peer.run()), asyncio.create_task(bridge_peer.run())]

    try:
        yield Nvim(nvim_peer, editor)
    finally:
        await bridge.shutdown()
        await nvim_peer.close()
        await bridge_peer.close()
        for task in pump:
            task.cancel()
        await asyncio.gather(*pump, return_exceptions=True)


async def spawn(nvim: Nvim, **overrides: Any) -> str:
    params = {
        "provider": "fake",
        "command": sys.executable,
        "args": [str(FAKE_AGENT)],
        "cwd": str(Path.cwd()),
    }
    params.update(overrides)
    result = await nvim.call("agent/spawn", params)
    return result["agentId"]


async def new_session(nvim: Nvim, agent_id: str) -> str:
    result = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )
    return result["sessionId"]


# -- handshake -----------------------------------------------------------


async def test_hello_reports_version_and_providers(nvim):
    result = await nvim.call("bridge/hello")

    assert result["bridgeProtocolVersion"] == 1
    assert "cursor" in result["providers"]
    assert "claude" in result["providers"]


async def test_spawn_returns_agent_id_and_capabilities(nvim):
    result = await nvim.call(
        "agent/spawn",
        {
            "provider": "fake",
            "command": sys.executable,
            "args": [str(FAKE_AGENT)],
            "cwd": str(Path.cwd()),
        },
    )

    assert result["agentId"].startswith("agent-")
    assert result["capabilities"]["loadSession"] is True
    assert result["pid"]


async def test_spawn_without_provider_is_rejected(nvim):
    with pytest.raises(RpcError) as excinfo:
        await nvim.call("agent/spawn", {"command": sys.executable})

    assert excinfo.value.code == -32602


async def test_spawn_of_a_missing_binary_reports_clearly(nvim):
    with pytest.raises(RpcError) as excinfo:
        await nvim.call(
            "agent/spawn", {"provider": "fake", "command": "/definitely/not/here"}
        )

    assert "not found" in excinfo.value.message.lower()


async def test_unknown_agent_id_is_rejected(nvim):
    with pytest.raises(RpcError) as excinfo:
        await nvim.call("session/new", {"agentId": "agent-999", "cwd": "/tmp"})

    assert excinfo.value.code == -32602


# -- sessions ------------------------------------------------------------


async def test_new_session_returns_modes(nvim):
    agent_id = await spawn(nvim)

    result = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )

    assert result["sessionId"]
    assert result["modes"]["currentModeId"] == "agent"


async def test_new_session_hands_the_agent_an_ask_tool(nvim):
    # The fake provider is unknown, so it counts as unable to ask a question
    # on its own and gets avante's own MCP server appended.
    agent_id = await spawn(nvim)

    result = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )

    injected = [server for server in result["mcpServers"] if server["name"] == "avante"]
    assert len(injected) == 1
    assert injected[0]["url"].startswith("http://127.0.0.1:")
    assert injected[0]["headers"][0]["name"] == "Authorization"


async def test_the_ask_tool_can_be_turned_off(nvim):
    agent_id = await spawn(nvim, askTool="never")

    result = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )

    assert result["mcpServers"] == []


async def test_the_ask_tool_is_reused_across_sessions(nvim):
    # One server per agent, not per session: a second listener per chat would
    # leak ports for the life of the agent.
    agent_id = await spawn(nvim)

    first = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )
    second = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": []}
    )

    assert first["mcpServers"][0]["url"] == second["mcpServers"][0]["url"]


async def test_a_project_server_named_avante_is_not_displaced(nvim):
    agent_id = await spawn(nvim)
    mine = {"name": "avante", "command": "echo", "args": [], "env": []}

    result = await nvim.call(
        "session/new", {"agentId": agent_id, "cwd": str(Path.cwd()), "mcpServers": [mine]}
    )

    assert result["mcpServers"] == [mine]


async def test_prompt_streams_events_and_returns_stop_reason(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    result = await nvim.call(
        "session/prompt", {"sessionId": session_id, "prompt": "say:hello"}
    )

    assert result["stopReason"] == "end_turn"
    assert nvim.messages()[-1] == "hello"


async def test_prompt_accepts_content_blocks(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    result = await nvim.call(
        "session/prompt",
        {"sessionId": session_id, "prompt": [{"type": "text", "text": "say:blocks"}]},
    )

    assert result["stopReason"] == "end_turn"
    assert nvim.messages()[-1] == "blocks"


async def test_empty_prompt_is_rejected(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    with pytest.raises(RpcError) as excinfo:
        await nvim.call("session/prompt", {"sessionId": session_id, "prompt": ""})

    assert excinfo.value.code == -32602


async def test_prompt_on_unknown_session_is_rejected(nvim):
    with pytest.raises(RpcError) as excinfo:
        await nvim.call("session/prompt", {"sessionId": "nope", "prompt": "say:hi"})

    assert excinfo.value.code == -32602


async def test_cancel_ends_the_turn(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    turn = asyncio.create_task(
        nvim.call("session/prompt", {"sessionId": session_id, "prompt": "hang"})
    )
    await asyncio.sleep(0.3)
    await nvim.notify("session/cancel", {"sessionId": session_id})

    assert (await asyncio.wait_for(turn, timeout=20))["stopReason"] == "cancelled"


async def test_cancel_of_unknown_session_is_silently_ignored(nvim):
    await nvim.notify("session/cancel", {"sessionId": "nope"})
    await asyncio.sleep(0.05)


async def test_set_mode(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    assert await nvim.call(
        "session/set_mode", {"sessionId": session_id, "modeId": "plan"}
    ) == {}


async def test_load_session_replays(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    await nvim.call(
        "session/load",
        {"agentId": agent_id, "sessionId": session_id, "cwd": str(Path.cwd())},
    )

    assert "replayed" in nvim.messages()


async def test_unsupported_capability_is_refused_not_attempted(nvim):
    """The fake agent advertises no resume support, so the bridge must refuse
    rather than sending a call the agent will reject."""
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    with pytest.raises(RpcError) as excinfo:
        await nvim.call(
            "session/resume",
            {"agentId": agent_id, "sessionId": session_id, "cwd": str(Path.cwd())},
        )

    assert excinfo.value.code == -32601


async def test_session_list_is_refused_when_unsupported(nvim):
    agent_id = await spawn(nvim, env={"AVANTE_FAKE_NO_LIST": "1"})

    with pytest.raises(RpcError) as excinfo:
        await nvim.call("session/list", {"agentId": agent_id})

    assert excinfo.value.code == -32601


# -- terminals through the full stack ------------------------------------


async def test_terminal_works_end_to_end(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    await nvim.call("session/prompt", {"sessionId": session_id, "prompt": "shell:echo bridged"})

    assert nvim.messages()[-1] == "exit=0 out=bridged"


# -- agent lifecycle -----------------------------------------------------


async def test_status_lists_running_agents_and_sessions(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    agents = (await nvim.call("agent/status"))["agents"]

    assert len(agents) == 1
    assert agents[0]["agentId"] == agent_id
    assert agents[0]["running"] is True
    assert agents[0]["sessions"] == [session_id]


async def test_kill_stops_the_agent(nvim):
    agent_id = await spawn(nvim)

    await nvim.call("agent/kill", {"agentId": agent_id})

    assert (await nvim.call("agent/status"))["agents"] == []


async def test_kill_is_idempotent(nvim):
    agent_id = await spawn(nvim)

    await nvim.call("agent/kill", {"agentId": agent_id})
    await nvim.call("agent/kill", {"agentId": agent_id})


async def test_two_agents_are_isolated(nvim):
    """Multiple chats / worktrees in one Neovim: killing one must not disturb
    the other."""
    first = await spawn(nvim)
    second = await spawn(nvim)
    first_session = await new_session(nvim, first)
    second_session = await new_session(nvim, second)

    assert first != second
    # The fake agent numbers sessions per process, so both are "sess-1". That
    # collision is the point: session ids are only unique within an agent.
    assert first_session == second_session

    await nvim.call("agent/kill", {"agentId": first})

    agents = (await nvim.call("agent/status"))["agents"]
    assert [a["agentId"] for a in agents] == [second]

    result = await nvim.call(
        "session/prompt",
        {"agentId": second, "sessionId": second_session, "prompt": "say:still here"},
    )
    assert result["stopReason"] == "end_turn"


async def test_agent_stderr_is_forwarded_as_an_event(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    with contextlib.suppress(Exception):
        await nvim.call("session/prompt", {"sessionId": session_id, "prompt": "crash"})

    await asyncio.sleep(0.3)
    stderr_events = [e for e in nvim.editor.events if e.get("kind") == "agent_stderr"]
    assert any("crashing on purpose" in e["update"]["line"] for e in stderr_events)


async def test_crashed_agent_fails_the_prompt_rather_than_hanging(nvim):
    agent_id = await spawn(nvim)
    session_id = await new_session(nvim, agent_id)

    with pytest.raises(Exception):
        await asyncio.wait_for(
            nvim.call("session/prompt", {"sessionId": session_id, "prompt": "crash"}),
            timeout=20,
        )


# -- session/list --------------------------------------------------------


async def test_session_list_returns_a_page_and_cursor(nvim):
    agent_id = await spawn(nvim)

    page = await nvim.call("session/list", {"agentId": agent_id, "cwd": "/tmp"})

    assert [s["sessionId"] for s in page["sessions"]] == ["listed-0"]
    assert page["nextCursor"] == "1"


async def test_session_list_follows_the_cursor(nvim):
    agent_id = await spawn(nvim)

    second = await nvim.call(
        "session/list", {"agentId": agent_id, "cwd": "/tmp", "cursor": "1"}
    )

    assert [s["sessionId"] for s in second["sessions"]] == ["listed-1"]


async def test_session_list_entries_carry_title_and_updated_at(nvim):
    agent_id = await spawn(nvim)

    page = await nvim.call("session/list", {"agentId": agent_id, "cwd": "/tmp"})
    entry = page["sessions"][0]

    assert entry["title"] == "Thread 0"
    assert entry["updatedAt"].startswith("2026-08-24")
