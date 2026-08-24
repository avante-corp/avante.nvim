"""Smoke-test the real entrypoint over real pipes.

Everything else uses in-process loopback streams; this is the only test that
proves `python -m avante_acp` actually frames correctly on stdio, which is how
Neovim will talk to it.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import sys
from pathlib import Path

import pytest

FAKE_AGENT = Path(__file__).parent / "fakes" / "agent.py"
REPO = Path(__file__).resolve().parents[1]


class BridgeProcess:
    def __init__(self, process: asyncio.subprocess.Process) -> None:
        self.process = process
        self._id = 0

    async def call(self, method: str, params: dict) -> dict:
        self._id += 1
        request = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        await self.process.stdin.drain()

        while True:
            line = await asyncio.wait_for(self.process.stdout.readline(), timeout=30)
            if not line:
                raise AssertionError("bridge closed stdout")
            message = json.loads(line)
            # Skip event notifications; we want our response.
            if message.get("id") == self._id:
                if "error" in message:
                    raise AssertionError(message["error"])
                return message["result"]


@pytest.fixture
async def bridge():
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-m",
        "avante_acp",
        cwd=str(REPO),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        yield BridgeProcess(process)
    finally:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        with contextlib.suppress(Exception):
            await process.wait()


async def test_entrypoint_answers_hello_over_stdio(bridge):
    result = await bridge.call("bridge/hello", {})

    assert result["bridgeProtocolVersion"] == 1
    assert "cursor" in result["providers"]


async def test_entrypoint_runs_a_full_prompt_turn(bridge):
    spawned = await bridge.call(
        "agent/spawn",
        {
            "provider": "fake",
            "command": sys.executable,
            "args": [str(FAKE_AGENT)],
            "cwd": str(REPO),
        },
    )
    session = await bridge.call(
        "session/new",
        {"agentId": spawned["agentId"], "cwd": str(REPO), "mcpServers": []},
    )
    result = await bridge.call(
        "session/prompt",
        {"sessionId": session["sessionId"], "prompt": "say:over stdio"},
    )

    assert result["stopReason"] == "end_turn"


async def test_entrypoint_keeps_stdout_clean_for_protocol_only(bridge):
    """Logs must go to stderr; anything on stdout corrupts the framing."""
    await bridge.call("bridge/hello", {})

    # If logging leaked to stdout, the JSON parse in call() would already have
    # blown up. Assert explicitly that a second call still round-trips.
    assert (await bridge.call("agent/status", {}))["agents"] == []
