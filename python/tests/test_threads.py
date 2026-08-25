"""Thread index.

The point of this module is that repeated listings do not re-read the history
tree, so the tests care as much about *what was parsed* as about the output.
"""

from __future__ import annotations

import json
import os

import pytest

from avante_acp import threads


def write_history(storage, project, name, **fields):
    directory = storage / "projects" / project / "history"
    directory.mkdir(parents=True, exist_ok=True)
    payload = {"filename": name, "title": fields.pop("title", "Untitled"), **fields}
    path = directory / name
    path.write_text(json.dumps(payload))
    return path


@pytest.fixture
def storage(tmp_path):
    threads._indexes.clear()
    return tmp_path


def test_lists_threads_with_summary_fields(storage):
    write_history(
        storage,
        "__Users__me__proj",
        "1.json",
        title="A thread",
        timestamp="2026-08-01T00:00:00Z",
        tags=["claude", "proj"],
        pinned=True,
        acp_session_id="sess-abc",
        messages=[{"timestamp": "2026-08-02T00:00:00Z"}],
    )

    result = threads.list_threads(str(storage))

    assert len(result["threads"]) == 1
    row = result["threads"][0]
    assert row["title"] == "A thread"
    assert row["tags"] == ["claude", "proj"]
    assert row["pinned"] is True
    assert row["acp_session_id"] == "sess-abc"
    assert row["message_count"] == 1
    assert row["last_message_timestamp"] == "2026-08-02T00:00:00Z"


def test_second_listing_parses_nothing(storage):
    for i in range(3):
        write_history(storage, "__Users__me__proj", f"{i}.json")

    first = threads.list_threads(str(storage))
    second = threads.list_threads(str(storage))

    assert first["stats"]["parsed"] == 3
    # The whole point: unchanged files are never re-read.
    assert second["stats"]["parsed"] == 0
    assert second["stats"]["cached"] == 3
    assert len(second["threads"]) == 3


def test_changed_file_is_reparsed(storage):
    path = write_history(storage, "__Users__me__proj", "1.json", title="Before")
    threads.list_threads(str(storage))

    path.write_text(json.dumps({"filename": "1.json", "title": "After"}))
    # Force a different mtime; filesystems can be coarse-grained.
    os.utime(path, (0, 0))

    result = threads.list_threads(str(storage))

    assert result["stats"]["parsed"] == 1
    assert result["threads"][0]["title"] == "After"


def test_deleted_file_drops_out(storage):
    write_history(storage, "__Users__me__proj", "1.json", title="Keep")
    path = write_history(storage, "__Users__me__proj", "2.json", title="Remove")
    threads.list_threads(str(storage))

    path.unlink()
    result = threads.list_threads(str(storage))

    assert [t["title"] for t in result["threads"]] == ["Keep"]


def test_force_reparses_everything(storage):
    write_history(storage, "__Users__me__proj", "1.json")
    threads.list_threads(str(storage))

    result = threads.list_threads(str(storage), force=True)

    assert result["stats"]["parsed"] == 1


def test_index_survives_a_new_process(storage):
    write_history(storage, "__Users__me__proj", "1.json")
    threads.list_threads(str(storage))

    # Simulate a bridge restart: drop the in-memory index, keep the file.
    threads._indexes.clear()
    result = threads.list_threads(str(storage))

    assert result["stats"]["parsed"] == 0
    assert result["stats"]["cached"] == 1


def test_corrupt_index_is_rebuilt_not_fatal(storage):
    write_history(storage, "__Users__me__proj", "1.json", title="Fine")
    threads.list_threads(str(storage))
    (storage / threads.INDEX_FILENAME).write_text("{ not json")
    threads._indexes.clear()

    result = threads.list_threads(str(storage))

    assert [t["title"] for t in result["threads"]] == ["Fine"]


def test_unparseable_history_is_skipped_and_not_retried(storage):
    directory = storage / "projects" / "__Users__me__proj" / "history"
    directory.mkdir(parents=True)
    (directory / "broken.json").write_text("{ truncated")
    write_history(storage, "__Users__me__proj", "1.json", title="Good")

    first = threads.list_threads(str(storage))
    second = threads.list_threads(str(storage))

    assert [t["title"] for t in first["threads"]] == ["Good"]
    # The broken file is remembered as broken rather than re-read every time.
    assert second["stats"]["parsed"] == 0


def test_metadata_json_is_ignored(storage):
    directory = storage / "projects" / "__Users__me__proj" / "history"
    directory.mkdir(parents=True)
    (directory / "metadata.json").write_text(json.dumps({"latest_filename": "1.json"}))
    write_history(storage, "__Users__me__proj", "1.json", title="Real")

    result = threads.list_threads(str(storage))

    assert [t["title"] for t in result["threads"]] == ["Real"]


def test_working_directory_recovered_from_project_dir(storage):
    write_history(storage, "__Users__me__myproj", "1.json")

    result = threads.list_threads(str(storage))

    assert result["threads"][0]["working_directory"] == "/Users/me/myproj"


def test_explicit_working_directory_wins(storage):
    write_history(
        storage, "__Users__me__myproj", "1.json", working_directory="/elsewhere"
    )

    result = threads.list_threads(str(storage))

    assert result["threads"][0]["working_directory"] == "/elsewhere"


def test_pinned_sort_first_then_most_recent(storage):
    write_history(storage, "__p", "1.json", title="old", timestamp="2026-01-01")
    write_history(storage, "__p", "2.json", title="new", timestamp="2026-09-01")
    write_history(storage, "__p", "3.json", title="pin", timestamp="2020-01-01", pinned=True)

    result = threads.list_threads(str(storage))

    assert [t["title"] for t in result["threads"]] == ["pin", "new", "old"]


def test_limit_truncates(storage):
    for i in range(5):
        write_history(storage, "__p", f"{i}.json", timestamp=f"2026-01-0{i}")

    result = threads.list_threads(str(storage), limit=2)

    assert len(result["threads"]) == 2
    assert result["stats"]["returned"] == 2


def test_missing_storage_is_empty_not_an_error(storage):
    result = threads.list_threads(str(storage / "nope"))

    assert result["threads"] == []
    assert result["stats"]["scanned"] == 0


def test_legacy_entries_format_is_counted(storage):
    write_history(
        storage,
        "__p",
        "1.json",
        entries=[{"timestamp": "2026-01-01"}, {"timestamp": "2026-01-02"}],
    )

    result = threads.list_threads(str(storage))

    assert result["threads"][0]["message_count"] == 2
    assert result["threads"][0]["last_message_timestamp"] == "2026-01-02"


def test_parallel_path_produces_the_same_result(storage, monkeypatch):
    # Cross the threshold so the process pool is used.
    monkeypatch.setattr(threads, "PARALLEL_THRESHOLD", 2)
    for i in range(6):
        write_history(storage, "__p", f"{i}.json", title=f"t{i}", timestamp=f"2026-01-0{i}")

    result = threads.list_threads(str(storage))

    assert sorted(t["title"] for t in result["threads"]) == [f"t{i}" for i in range(6)]


def test_absent_fields_are_omitted_not_null(storage):
    # Lua decodes JSON null as vim.NIL, which is truthy, so a null
    # acp_session_id passes `if session_id then` and then fails to concatenate.
    write_history(storage, "__p", "1.json", title="No session")

    row = threads.list_threads(str(storage))["threads"][0]

    assert "acp_session_id" not in row
    assert "parent_thread_id" not in row
    assert "last_seen_message_count" not in row


def test_present_fields_are_kept(storage):
    write_history(storage, "__p", "1.json", title="T", acp_session_id="s-1")

    row = threads.list_threads(str(storage))["threads"][0]

    assert row["acp_session_id"] == "s-1"


def test_falsey_values_are_not_dropped(storage):
    write_history(storage, "__p", "1.json", title="T", pinned=False)

    row = threads.list_threads(str(storage))["threads"][0]

    # pinned=False and message_count=0 must survive the None filter.
    assert row["pinned"] is False
    assert row["message_count"] == 0
