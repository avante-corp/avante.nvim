"""Raw session transcripts.

The point is replayability: `msg` must be the untouched JSON-RPC frame, in
order, so a real session can be turned into a test.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from avante_acp import transcript as transcript_mod


@pytest.fixture
def log_dir(tmp_path):
    return str(tmp_path / "logs")


def read(path):
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]


def frames(path):
    """Only the protocol frames, skipping meta records (connected/closed/stderr)."""
    return [r for r in read(path) if r.get("dir") != "meta"]


class FakeEvent:
    def __init__(self, direction, message):
        self.direction = type("D", (), {"value": direction})()
        self.message = message


def test_writes_into_a_dated_directory(log_dir):
    t = transcript_mod.Transcript("claude-code", "agent-1", log_dir=log_dir)
    t.note("connected")
    t.close()

    today = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d")
    assert t.path.parent.name == today
    assert t.path.exists()


def test_records_frames_verbatim(log_dir):
    t = transcript_mod.Transcript("claude-code", "agent-1", log_dir=log_dir)
    frame = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}}

    t.record("outgoing", frame)
    t.close()

    records = read(t.path)
    # Untouched: replaying means feeding `msg` back in.
    assert records[0]["msg"] == frame
    assert records[0]["dir"] == "outgoing"
    assert "ts" in records[0]


def test_preserves_order_and_direction(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)

    t.record("outgoing", {"id": 1, "method": "initialize"})
    t.record("incoming", {"id": 1, "result": {}})
    t.record("incoming", {"method": "session/update", "params": {"sessionId": "s"}})
    t.close()

    records = frames(t.path)
    assert [r["dir"] for r in records] == ["outgoing", "incoming", "incoming"]
    assert [r["msg"].get("method") for r in records] == ["initialize", None, "session/update"]


def test_renames_to_the_session_once_known(log_dir):
    # Sessions are created after the connection opens, so the handshake has to
    # land somewhere first.
    t = transcript_mod.Transcript("claude-code", "agent-1", log_dir=log_dir)
    assert "agent-1" in t.path.name

    t.record("incoming", {"id": 1, "result": {"sessionId": "sess-abc"}})

    assert t.path.name == "claude-code-sess-abc.log"
    assert t.path.exists()


def test_handshake_survives_the_rename(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.note("connected", command=["claude-agent-acp"])
    t.record("outgoing", {"id": 1, "method": "initialize"})
    t.record("incoming", {"id": 1, "result": {"sessionId": "s1"}})
    t.record("outgoing", {"id": 2, "method": "session/prompt"})
    t.close()

    records = read(t.path)
    assert [r.get("event") or r["msg"].get("method") for r in records] == [
        "connected",
        "initialize",
        None,
        "session/prompt",
        "closed",
    ]


def test_finds_the_session_id_in_params_too(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)

    t.record("outgoing", {"method": "session/prompt", "params": {"sessionId": "sess-xyz"}})

    assert t.path.name == "p-sess-xyz.log"


def test_renames_only_once(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.record("incoming", {"result": {"sessionId": "first"}})
    t.record("outgoing", {"params": {"sessionId": "second"}})

    assert t.path.name == "p-first.log"


def test_unsafe_names_cannot_escape_the_directory(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)

    t.record("incoming", {"result": {"sessionId": "../../etc/passwd"}})

    assert "/" not in t.path.name
    assert t.path.parent.name == datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d")


def test_observer_records_both_directions(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    observe = t.observer()

    observe(FakeEvent("outgoing", {"id": 1, "method": "initialize"}))
    observe(FakeEvent("incoming", {"id": 1, "result": {}}))
    t.close()

    assert [r["dir"] for r in frames(t.path)] == ["outgoing", "incoming"]


def test_observer_ignores_non_dict_messages(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    observe = t.observer()

    observe(FakeEvent("incoming", "not a frame"))
    t.close()

    assert frames(t.path) == []


def test_stderr_is_recorded_as_meta(log_dir):
    # Crashes are explained on stderr, not in the protocol.
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)

    t.note("stderr", line="npm warn something")
    t.close()

    records = read(t.path)
    assert records[0]["dir"] == "meta"
    assert records[0]["line"] == "npm warn something"


def test_header_never_records_the_environment(log_dir):
    # env holds API keys.
    t = transcript_mod.open_transcript(
        "claude-code", "agent-1", command="claude-agent-acp", args=["--acp"], cwd="/tmp",
        log_dir=log_dir,
    )
    t.close()

    header = read(t.path)[0]
    assert header["command"] == ["claude-agent-acp", "--acp"]
    assert "env" not in header
    assert not any("KEY" in str(k).upper() for k in header)


def test_writing_after_close_is_ignored(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.close()

    t.record("incoming", {"id": 1})

    assert frames(t.path) == []


def test_close_is_idempotent(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.close("first")
    t.close("second")

    assert sum(1 for r in read(t.path) if r.get("event") == "closed") == 1


def test_unwritable_directory_does_not_raise(tmp_path):
    # A transcript is a diagnostic; it must never break a session.
    blocker = tmp_path / "blocked"
    blocker.write_text("i am a file, not a directory")

    t = transcript_mod.Transcript("p", "agent-1", log_dir=str(blocker))
    t.record("incoming", {"id": 1})
    t.close()


def test_unserialisable_payloads_do_not_raise(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)

    t.record("incoming", {"weird": object()})
    t.close()

    # default=str keeps it writable rather than losing the frame.
    assert len(frames(t.path)) == 1


# -- replay --------------------------------------------------------------
# The stated purpose: turn a real session into a test.


def test_load_returns_every_record_in_order(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.record("outgoing", {"id": 1, "method": "initialize"})
    t.record("incoming", {"id": 1, "result": {}})
    t.close()

    records = transcript_mod.load(t.path)

    assert [r.get("dir") for r in records] == ["outgoing", "incoming", "meta"]


def test_frames_filters_by_direction_and_method(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.record("outgoing", {"id": 1, "method": "initialize"})
    t.record("outgoing", {"id": 2, "method": "session/prompt"})
    t.record("incoming", {"id": 1, "result": {}})
    t.close()

    assert len(transcript_mod.frames(t.path)) == 3
    assert len(transcript_mod.frames(t.path, direction="outgoing")) == 2
    prompts = transcript_mod.frames(t.path, method="session/prompt")
    assert [f["id"] for f in prompts] == [2]


def test_session_updates_extracts_payloads_by_kind(log_dir):
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    for kind, text in (("agent_message_chunk", "hi"), ("tool_call", None)):
        t.record("incoming", {
            "method": "session/update",
            "params": {"sessionId": "s", "update": {"sessionUpdate": kind, "text": text}},
        })
    t.close()

    assert len(transcript_mod.session_updates(t.path)) == 2
    chunks = transcript_mod.session_updates(t.path, kind="agent_message_chunk")
    assert [c["text"] for c in chunks] == ["hi"]


def test_truncated_transcript_still_loads(log_dir):
    # A crash mid-write is exactly when you want to read the rest.
    t = transcript_mod.Transcript("p", "agent-1", log_dir=log_dir)
    t.record("outgoing", {"id": 1, "method": "initialize"})
    t.close()
    with open(t.path, "a", encoding="utf-8") as handle:
        handle.write('{"dir": "incoming", "msg": {"id": 2, "meth')

    assert len(transcript_mod.frames(t.path)) == 1


def test_missing_file_loads_as_empty(tmp_path):
    assert transcript_mod.load(tmp_path / "nope.log") == []
