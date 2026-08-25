"""Owns the agent subprocesses.

One bridge holds many agents, and each agent holds many sessions. That is what
makes several chats -- and several worktrees -- work in one Neovim instance,
instead of the previous one-client-per-sidebar model that spawned a second
agent process just to open the thread viewer.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import logging
from typing import Any

from acp import PROTOCOL_VERSION, spawn_agent_process
from acp.schema import (
    ClientCapabilities,
    ElicitationCapabilities,
    ElicitationFormCapabilities,
    FileSystemCapabilities,
    Implementation,
)

from . import providers
from .client import BridgeClient
from .jsonrpc import Peer, RpcError
from .terminal import TerminalManager

log = logging.getLogger(__name__)

CLIENT_INFO = Implementation(name="avante.nvim", title="avante.nvim", version="0.1.0")

#: How long an agent gets to answer `initialize`.
#:
#: Spawning may legitimately take minutes (`npx -y` on a cold cache), but the
#: handshake starts only once the process is up, so it can be bounded tightly.
#: Without a bound, a command that is not an ACP server at all hangs here
#: forever -- `cursor-agent acp` on a build with no `acp` subcommand swallows
#: the request as a chat prompt and never replies.
INITIALIZE_TIMEOUT = 20.0


def client_capabilities(*, unstable: bool = False) -> ClientCapabilities:
    """What we can do for an agent.

    Terminals are advertised because the bridge implements them natively.
    Elicitation is only advertised on an unstable connection, since the SDK
    gates elicitation/create behind use_unstable_protocol.
    """
    caps = ClientCapabilities(
        fs=FileSystemCapabilities(readTextFile=True, writeTextFile=True),
        terminal=True,
    )
    if unstable:
        caps.elicitation = ElicitationCapabilities(form=ElicitationFormCapabilities())
    return caps


class AgentHandle:
    """A running agent process plus its ACP connection."""

    def __init__(self, agent_id: str, provider: str, terminals: TerminalManager) -> None:
        self.agent_id = agent_id
        self.provider = provider
        self.terminals = terminals
        self.conn: Any = None
        self.process: Any = None
        self.capabilities: dict[str, Any] = {}
        self.auth_methods: list[dict[str, Any]] = []
        self.sessions: set[str] = set()
        self._stack = contextlib.AsyncExitStack()
        self._stderr_tail: list[str] = []
        self._stderr_task: asyncio.Task[None] | None = None

    async def start(
        self,
        peer: Peer,
        *,
        command: str,
        args: list[str],
        env: dict[str, str],
        cwd: str | None,
        auto_approve: bool,
        unstable: bool,
    ) -> None:
        client = BridgeClient(self.agent_id, peer, self.terminals, auto_approve=auto_approve)

        self.conn, self.process = await self._stack.enter_async_context(
            spawn_agent_process(
                client,
                command,
                *args,
                env=env,
                cwd=cwd,
                use_unstable_protocol=unstable,
            )
        )

        if self.process.stderr is not None:
            self._stderr_task = asyncio.create_task(self._drain_stderr(peer))

        try:
            result = await asyncio.wait_for(
                self.conn.initialize(
                    protocol_version=PROTOCOL_VERSION,
                    client_capabilities=client_capabilities(unstable=unstable),
                    client_info=CLIENT_INFO,
                ),
                timeout=INITIALIZE_TIMEOUT,
            )
        except asyncio.TimeoutError as exc:
            raise RpcError(
                -32003,
                f"{command!r} did not answer ACP initialize within "
                f"{INITIALIZE_TIMEOUT:.0f}s -- it may not be an ACP server. "
                f"Check that `{' '.join([command, *args])}` starts one.",
                {
                    "command": command,
                    "args": list(args),
                    "stderr": self.recent_stderr(),
                },
            ) from exc
        self.capabilities = _dump(result.agent_capabilities) or {}
        self.auth_methods = [_dump(method) for method in (result.auth_methods or [])]

    async def _drain_stderr(self, peer: Peer) -> None:
        """Agent stderr is where auth failures and crashes are explained. The
        Lua client discarded it entirely, which made those invisible."""
        try:
            while True:
                line = await self.process.stderr.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                self._stderr_tail.append(text)
                del self._stderr_tail[:-50]
                await peer.notify(
                    "event",
                    {"agentId": self.agent_id, "kind": "agent_stderr", "update": {"line": text}},
                )
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("stderr pump for %s failed", self.agent_id)

    def recent_stderr(self) -> str:
        return "\n".join(self._stderr_tail)

    def supports(self, *path: str) -> bool:
        """Whether a capability is advertised.

        ACP marks a sub-capability as available by sending an object, which is
        usually empty -- `sessionCapabilities.list = {}` means "supported".
        Truthiness is therefore the wrong test: `bool({})` is False, which would
        refuse every capability every agent actually offers. Presence is what
        matters, with False reserved for the plain-boolean flags like
        `loadSession`.
        """
        node: Any = self.capabilities
        for key in path:
            if not isinstance(node, dict):
                return False
            node = node.get(key)
        return node is not None and node is not False

    async def stop(self) -> None:
        if self._stderr_task is not None:
            self._stderr_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._stderr_task

        await self.terminals.release_session_many(self.sessions)

        with contextlib.suppress(Exception):
            await self._stack.aclose()

        if self.process is not None and self.process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                self.process.kill()
            with contextlib.suppress(Exception):
                await self.process.wait()


class Supervisor:
    """Registry of agents and the sessions that belong to them."""

    def __init__(self, peer: Peer) -> None:
        self._peer = peer
        self._agents: dict[str, AgentHandle] = {}
        self._ids = itertools.count(1)
        self.terminals = TerminalManager()

    async def spawn(
        self,
        provider: str,
        *,
        command: str | None = None,
        args: list[str] | None = None,
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        auto_approve: bool = False,
        unstable: bool = False,
    ) -> AgentHandle:
        resolved_command, resolved_args, resolved_env = providers.build_command(
            provider, command=command, args=args, env=env
        )

        agent_id = f"agent-{next(self._ids)}"
        handle = AgentHandle(agent_id, provider, self.terminals)

        try:
            await handle.start(
                self._peer,
                command=resolved_command,
                args=resolved_args,
                env=resolved_env,
                cwd=cwd,
                auto_approve=auto_approve,
                unstable=unstable,
            )
        except FileNotFoundError as exc:
            raise RpcError(
                -32603,
                f"Agent command not found: {resolved_command}",
                {"provider": provider, "command": resolved_command},
            ) from exc
        except RpcError:
            # Already diagnosed (e.g. the initialize timeout), and its code and
            # message are what Neovim shows. Re-wrapping would bury both under a
            # generic -32603, so only reap the process.
            await handle.stop()
            raise
        except Exception as exc:
            stderr = handle.recent_stderr()
            await handle.stop()
            raise RpcError(
                -32603,
                f"Failed to start agent {provider!r}: {exc}",
                {"provider": provider, "stderr": stderr},
            ) from exc

        self._agents[agent_id] = handle
        return handle

    def get(self, agent_id: str) -> AgentHandle:
        try:
            return self._agents[agent_id]
        except KeyError:
            raise RpcError(-32602, f"Unknown agentId: {agent_id}") from None

    def for_session(self, session_id: str, agent_id: str | None = None) -> AgentHandle:
        """Resolve the agent owning a session.

        Session ids are chosen by the agent and are only unique *within* that
        agent -- two agents (two worktrees, or two runs of the same CLI) will
        happily both call their first session "sess-1". So an explicit agentId
        always wins, and an ambiguous lookup is an error rather than a guess.
        """
        if agent_id:
            handle = self.get(agent_id)
            if session_id not in handle.sessions:
                # Reject here rather than forwarding a session the agent never
                # had. The bridge owns the agent, so this map cannot be stale in
                # the direction that would cause a false negative, and a clear
                # error is what drives avante's session-recovery path.
                raise RpcError(
                    -32602, f"Unknown sessionId: {session_id} (agent {agent_id})"
                )
            return handle

        owners = [
            handle for handle in self._agents.values() if session_id in handle.sessions
        ]
        if not owners:
            raise RpcError(-32602, f"Unknown sessionId: {session_id}")
        if len(owners) > 1:
            raise RpcError(
                -32602,
                f"Ambiguous sessionId {session_id!r}: owned by "
                f"{', '.join(h.agent_id for h in owners)}. Pass agentId.",
            )
        return owners[0]

    def bind_session(self, agent_id: str, session_id: str) -> None:
        self._agents[agent_id].sessions.add(session_id)

    def release_session(self, session_id: str, agent_id: str | None = None) -> None:
        handles = (
            [self._agents[agent_id]]
            if agent_id and agent_id in self._agents
            else list(self._agents.values())
        )
        for handle in handles:
            handle.sessions.discard(session_id)

    async def kill(self, agent_id: str) -> None:
        handle = self._agents.pop(agent_id, None)
        if handle is None:
            return
        await handle.stop()

    def status(self) -> list[dict[str, Any]]:
        return [
            {
                "agentId": handle.agent_id,
                "provider": handle.provider,
                "pid": getattr(handle.process, "pid", None),
                "running": handle.process is not None and handle.process.returncode is None,
                "sessions": sorted(handle.sessions),
                "capabilities": handle.capabilities,
            }
            for handle in self._agents.values()
        ]

    async def shutdown(self) -> None:
        for agent_id in list(self._agents):
            await self.kill(agent_id)
        await self.terminals.release_all()


def _dump(model: Any) -> Any:
    if hasattr(model, "model_dump"):
        return model.model_dump(by_alias=True, exclude_none=True, mode="json")
    return model
