"""Raw JSON-RPC transcripts of an agent session.

Every message between the bridge and an agent is appended verbatim, so a bug in
a real session can be replayed and turned into a test rather than reproduced by
guesswork.

Layout::

    ~/.avante/logs/2026-08-25/claude-code-<sessionId>.log

One JSON object per line (NDJSON)::

    {"ts": "...", "dir": "meta",     "event": "connected", "provider": "...", "command": [...]}
    {"ts": "...", "dir": "outgoing", "msg": {"jsonrpc": "2.0", "id": 1, "method": "initialize", ...}}
    {"ts": "...", "dir": "incoming", "msg": {"jsonrpc": "2.0", "id": 1, "result": {...}}}

`msg` is the untouched JSON-RPC frame: replaying a transcript means feeding
those objects back in order.

The spawn environment is deliberately never recorded -- it carries API keys.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

DEFAULT_LOG_DIR = "~/.avante/logs"

#: Characters that would break out of the log directory or confuse a shell.
_UNSAFE = set('/\\:*?"<>| \t\n')


def _safe(name: str, fallback: str = "unknown") -> str:
    cleaned = "".join("-" if ch in _UNSAFE else ch for ch in str(name or "")).strip("-")
    return cleaned or fallback


def _now() -> datetime:
    return datetime.now(timezone.utc).astimezone()


class Transcript:
    """Appends every frame of one agent connection to a file."""

    def __init__(
        self,
        provider: str,
        agent_id: str,
        *,
        log_dir: str | None = None,
        clock: Any = _now,
    ) -> None:
        self.provider = provider
        self.agent_id = agent_id
        self._clock = clock
        self._session_id: str | None = None
        self._handle: Any = None
        self._closed = False

        root = Path(os.path.expanduser(log_dir or DEFAULT_LOG_DIR))
        started = self._clock()
        self.directory = root / started.strftime("%Y-%m-%d")
        # Named by agent until the session id is known, then renamed. Sessions
        # are created after the connection opens, so the handshake would
        # otherwise have nowhere to go.
        self.path = self.directory / f"{_safe(provider)}-{_safe(agent_id)}.log"

        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            self._handle = open(self.path, "a", encoding="utf-8")
        except OSError:
            log.warning("Could not open transcript at %s; continuing without one", self.path)
            self._handle = None

    # -- writing ---------------------------------------------------------

    def _write(self, record: dict[str, Any]) -> None:
        if self._handle is None or self._closed:
            return
        record["ts"] = self._clock().isoformat()
        try:
            self._handle.write(json.dumps(record, default=str) + "\n")
            self._handle.flush()
        except (OSError, ValueError, TypeError):
            # A transcript is a diagnostic. Never let it break the session.
            log.exception("Failed to write transcript record")

    def note(self, event: str, **fields: Any) -> None:
        """Record a non-protocol event (connected, exited, ...)."""
        self._write({"dir": "meta", "event": event, **fields})

    def record(self, direction: str, message: dict[str, Any]) -> None:
        """Record one raw JSON-RPC frame."""
        self._adopt_session(message)
        self._write({"dir": direction, "msg": message})

    # -- session naming --------------------------------------------------

    def _adopt_session(self, message: dict[str, Any]) -> None:
        """Rename the file once the session id appears.

        The id shows up either in the session/new result or in the params of
        any session-scoped call.
        """
        if self._session_id is not None or not isinstance(message, dict):
            return

        session_id = None
        for holder in (message.get("result"), message.get("params")):
            if isinstance(holder, dict) and isinstance(holder.get("sessionId"), str):
                session_id = holder["sessionId"]
                break
        if not session_id:
            return

        self._session_id = session_id
        target = self.directory / f"{_safe(self.provider)}-{_safe(session_id)}.log"
        if target == self.path:
            return
        try:
            # Renaming an open file is fine on POSIX; the handle follows it.
            os.replace(self.path, target)
            self.path = target
        except OSError:
            log.debug("Could not rename transcript to %s", target)

    # -- observer --------------------------------------------------------

    def observer(self):
        """A StreamObserver for acp.Connection.

        Receives a deepcopy of every frame in both directions.
        """

        def observe(event: Any) -> None:
            direction = getattr(getattr(event, "direction", None), "value", None) or "unknown"
            message = getattr(event, "message", None)
            if isinstance(message, dict):
                self.record(direction, message)

        return observe

    # -- lifecycle -------------------------------------------------------

    def close(self, reason: str | None = None) -> None:
        if self._closed:
            return
        # Always record the end: a transcript that just stops is ambiguous
        # between a clean finish and a crash mid-write.
        self.note("closed", reason=reason or "closed")
        self._closed = True
        if self._handle is not None:
            try:
                self._handle.close()
            except OSError:
                pass
            self._handle = None


def open_transcript(
    provider: str,
    agent_id: str,
    *,
    command: str,
    args: list[str],
    cwd: str | None,
    log_dir: str | None = None,
) -> Transcript:
    """Start a transcript and write its header.

    `env` is intentionally not a parameter: it holds API keys.
    """
    transcript = Transcript(provider, agent_id, log_dir=log_dir)
    transcript.note(
        "connected",
        provider=provider,
        agentId=agent_id,
        command=[command, *args],
        cwd=cwd,
    )
    return transcript


# -- replay -------------------------------------------------------------
# A transcript is only useful if a test can consume it, so reading one back is
# part of this module rather than left to each caller.


def load(path: str | Path) -> list[dict[str, Any]]:
    """Every record in a transcript, in order.

    Malformed lines are skipped: a transcript truncated by a crash is exactly
    when you most want to read the rest of it.
    """
    records: list[dict[str, Any]] = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if isinstance(record, dict):
                    records.append(record)
    except OSError:
        return []
    return records


def frames(
    path: str | Path, *, direction: str | None = None, method: str | None = None
) -> list[dict[str, Any]]:
    """The raw JSON-RPC frames, without the meta records.

    Filter by ``direction`` ("incoming"/"outgoing") and/or ``method`` to pull
    out just the calls a test cares about.
    """
    result = []
    for record in load(path):
        if record.get("dir") == "meta":
            continue
        message = record.get("msg")
        if not isinstance(message, dict):
            continue
        if direction is not None and record.get("dir") != direction:
            continue
        if method is not None and message.get("method") != method:
            continue
        result.append(message)
    return result


def session_updates(path: str | Path, *, kind: str | None = None) -> list[dict[str, Any]]:
    """The `update` payloads from session/update notifications.

    ``kind`` filters on `sessionUpdate` (agent_message_chunk, tool_call, ...).
    """
    updates = []
    for message in frames(path, method="session/update"):
        update = (message.get("params") or {}).get("update")
        if not isinstance(update, dict):
            continue
        if kind is not None and update.get("sessionUpdate") != kind:
            continue
        updates.append(update)
    return updates
