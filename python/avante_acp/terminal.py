"""Native ``terminal/*`` support.

Agents use terminals to run builds, tests and git commands. The Lua client never
implemented these, and worse, answered them with silence -- so any agent that
shelled out blocked forever. Handling them here means Neovim is not involved at
all: no main-loop blocking, no editor freeze.
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import os
import signal
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger(__name__)

DEFAULT_OUTPUT_BYTE_LIMIT = 1_048_576  # 1 MiB


@dataclass
class _Terminal:
    terminal_id: str
    session_id: str
    process: asyncio.subprocess.Process
    output_byte_limit: int
    buffer: bytearray = field(default_factory=bytearray)
    truncated: bool = False
    exit_code: int | None = None
    exit_signal: str | None = None
    _pumps: list[asyncio.Task[None]] = field(default_factory=list)

    def append(self, data: bytes) -> None:
        self.buffer.extend(data)
        if len(self.buffer) > self.output_byte_limit:
            # Keep the tail: the end of a build log is what diagnoses a failure.
            overflow = len(self.buffer) - self.output_byte_limit
            del self.buffer[:overflow]
            self.truncated = True

    def text(self) -> str:
        return self.buffer.decode("utf-8", errors="replace")


class TerminalNotFound(KeyError):
    pass


class TerminalManager:
    """Owns every terminal the agent has asked us to run."""

    def __init__(self) -> None:
        self._terminals: dict[str, _Terminal] = {}
        self._ids = itertools.count(1)

    async def create(
        self,
        session_id: str,
        command: str,
        args: list[str] | None = None,
        env: list[Any] | None = None,
        cwd: str | None = None,
        output_byte_limit: int | None = None,
    ) -> str:
        child_env = dict(os.environ)
        for item in env or []:
            # The SDK hands us EnvVariable models; tests may pass plain pairs.
            name = getattr(item, "name", None)
            value = getattr(item, "value", None)
            if name is None and isinstance(item, dict):
                name, value = item.get("name"), item.get("value")
            if name is not None:
                child_env[str(name)] = str(value if value is not None else "")

        process = await asyncio.create_subprocess_exec(
            command,
            *(args or []),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
            env=child_env,
        )

        terminal_id = f"term-{next(self._ids)}"
        terminal = _Terminal(
            terminal_id=terminal_id,
            session_id=session_id,
            process=process,
            output_byte_limit=output_byte_limit or DEFAULT_OUTPUT_BYTE_LIMIT,
        )
        self._terminals[terminal_id] = terminal

        # Drain both pipes eagerly. If we only read on terminal/output, a child
        # that fills the pipe buffer deadlocks waiting for someone to consume it.
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                terminal._pumps.append(asyncio.create_task(self._pump(terminal, stream)))

        log.debug("Created %s: %s %s (cwd=%s)", terminal_id, command, args or [], cwd)
        return terminal_id

    async def _pump(self, terminal: _Terminal, stream: asyncio.StreamReader) -> None:
        try:
            while True:
                chunk = await stream.read(8192)
                if not chunk:
                    break
                terminal.append(chunk)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Terminal %s output pump failed", terminal.terminal_id)

    def _get(self, terminal_id: str) -> _Terminal:
        try:
            return self._terminals[terminal_id]
        except KeyError:
            raise TerminalNotFound(terminal_id) from None

    def output(self, terminal_id: str) -> dict[str, Any]:
        terminal = self._get(terminal_id)
        result: dict[str, Any] = {
            "output": terminal.text(),
            "truncated": terminal.truncated,
        }
        status = self._exit_status(terminal)
        if status is not None:
            result["exitStatus"] = status
        return result

    def _exit_status(self, terminal: _Terminal) -> dict[str, Any] | None:
        if terminal.process.returncode is None:
            return None
        return {"exitCode": terminal.exit_code, "signal": terminal.exit_signal}

    async def wait_for_exit(self, terminal_id: str) -> dict[str, Any]:
        terminal = self._get(terminal_id)
        await terminal.process.wait()
        # Let the pumps finish so terminal/output right after this is complete.
        if terminal._pumps:
            await asyncio.gather(*terminal._pumps, return_exceptions=True)
        self._record_exit(terminal)
        return {"exitCode": terminal.exit_code, "signal": terminal.exit_signal}

    def _record_exit(self, terminal: _Terminal) -> None:
        code = terminal.process.returncode
        if code is None:
            return
        if code < 0:
            terminal.exit_code = None
            terminal.exit_signal = _signal_name(-code)
        else:
            terminal.exit_code = code
            terminal.exit_signal = None

    async def kill(self, terminal_id: str) -> None:
        terminal = self._get(terminal_id)
        if terminal.process.returncode is None:
            try:
                terminal.process.kill()
            except ProcessLookupError:
                pass
            await terminal.process.wait()
        self._record_exit(terminal)

    async def release(self, terminal_id: str) -> None:
        terminal = self._terminals.pop(terminal_id, None)
        if terminal is None:
            return
        if terminal.process.returncode is None:
            try:
                terminal.process.kill()
            except ProcessLookupError:
                pass
            await terminal.process.wait()
        for pump in terminal._pumps:
            pump.cancel()
        await asyncio.gather(*terminal._pumps, return_exceptions=True)

    async def release_session(self, session_id: str) -> None:
        for terminal_id in [
            tid for tid, t in self._terminals.items() if t.session_id == session_id
        ]:
            await self.release(terminal_id)

    async def release_session_many(self, session_ids: set[str]) -> None:
        for session_id in list(session_ids):
            await self.release_session(session_id)

    async def release_all(self) -> None:
        for terminal_id in list(self._terminals):
            await self.release(terminal_id)


def _signal_name(number: int) -> str:
    try:
        return signal.Signals(number).name
    except ValueError:
        return f"SIG{number}"
