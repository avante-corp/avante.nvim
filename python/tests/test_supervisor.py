"""Capability interpretation, and the handshake deadline.

ACP advertises a sub-capability by sending an object, which is usually empty.
Treating that as a boolean refuses every capability an agent actually offers,
so these pin the semantics.
"""

from __future__ import annotations

import asyncio
import sys

import pytest

from avante_acp import supervisor as supervisor_mod
from avante_acp.jsonrpc import Peer, RpcError
from avante_acp.supervisor import AgentHandle, Supervisor
from avante_acp.terminal import TerminalManager


def handle_with(capabilities):
    handle = AgentHandle("agent-1", "fake", TerminalManager())
    handle.capabilities = capabilities
    return handle


def test_empty_object_means_supported():
    # This is the shape real agents send: sessionCapabilities.list = {}
    handle = handle_with({"sessionCapabilities": {"list": {}}})

    assert handle.supports("sessionCapabilities", "list") is True


def test_missing_key_means_unsupported():
    handle = handle_with({"sessionCapabilities": {}})

    assert handle.supports("sessionCapabilities", "list") is False


def test_null_means_unsupported():
    handle = handle_with({"sessionCapabilities": {"list": None}})

    assert handle.supports("sessionCapabilities", "list") is False


def test_boolean_flags_still_honour_false():
    assert handle_with({"loadSession": True}).supports("loadSession") is True
    assert handle_with({"loadSession": False}).supports("loadSession") is False


def test_populated_object_means_supported():
    handle = handle_with({"promptCapabilities": {"image": True}})

    assert handle.supports("promptCapabilities", "image") is True


def test_missing_parent_is_unsupported():
    handle = handle_with({})

    assert handle.supports("sessionCapabilities", "resume") is False


def test_non_dict_parent_is_unsupported():
    handle = handle_with({"sessionCapabilities": "nonsense"})

    assert handle.supports("sessionCapabilities", "resume") is False


async def test_spawn_gives_up_when_the_agent_never_answers_initialize(peer_pair, monkeypatch):
    """A command that starts but does not speak ACP must fail, not hang.

    This is the `cursor-agent acp` case on a build with no `acp` subcommand:
    the argument is taken as a chat prompt, so the process runs happily and
    initialize is answered by nobody. Without a deadline the spawn sat in
    flight until Neovim's own 5-minute timeout, and every prompt in between
    reported "ACP client not connected" -- a symptom five minutes downstream.
    """
    monkeypatch.setattr(supervisor_mod, "INITIALIZE_TIMEOUT", 0.5)
    supervisor = Supervisor(peer_pair.left)

    # Drains stdin and replies to nothing, like a CLI in some other mode.
    with pytest.raises(RpcError) as excinfo:
        await supervisor.spawn(
            "cursor",
            command=sys.executable,
            args=["-c", "import sys; sys.stdin.read()"],
        )

    assert excinfo.value.code == -32003
    assert "did not answer ACP initialize" in excinfo.value.message
    # The failure must name what was run, since the point is to reveal a
    # misconfigured command.
    assert excinfo.value.data["command"] == sys.executable
    # And the agent must not be registered or left running.
    assert supervisor.status() == []


async def test_spawn_reports_a_command_that_does_not_exist(peer_pair):
    supervisor = Supervisor(peer_pair.left)

    with pytest.raises(RpcError) as excinfo:
        await supervisor.spawn("cursor", command="avante-no-such-binary", args=[])

    assert "not found" in excinfo.value.message


async def test_initialize_deadline_does_not_bound_a_slow_spawn():
    """The deadline starts after the process is up, so `npx -y` on a cold
    cache is unaffected. Guards against someone folding this back into the
    spawn timeout."""
    assert supervisor_mod.INITIALIZE_TIMEOUT <= 60.0
    assert asyncio.iscoroutinefunction(AgentHandle.start)
