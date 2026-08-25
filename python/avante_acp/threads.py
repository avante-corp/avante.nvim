"""Thread (chat history) listing.

`:AvanteThreads` used to call Path.history.list_all(), which read and decoded
every history file on every open -- 4.3 GB across ~2000 files on a working
machine, about 12 s, on Neovim's main loop.

Almost none of that work is needed twice: history files are append-only and
their mtime changes when they do. So this keeps an on-disk index keyed by
(mtime, size) and only re-parses what actually changed. A warm listing is a
stat() per file (~5 ms for 2000 files); a cold build is parallelised across
cores and, crucially, happens in this process rather than in the editor.

Summaries use avante's own snake_case ChatHistory field names, not ACP
camelCase, so the Lua side can use them directly.
"""

from __future__ import annotations

import json
import logging
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

INDEX_FILENAME = "thread-index.json"
INDEX_VERSION = 1

# Below this many files to (re)parse, process startup costs more than it saves.
PARALLEL_THRESHOLD = 24


def summarize_file(path: str) -> dict[str, Any] | None:
    """Read one history file down to the fields the picker displays.

    Module-level and self-contained so it can be used as a ProcessPoolExecutor
    worker.
    """
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
        data = json.loads(raw)
    except (OSError, ValueError):
        return None

    if not isinstance(data, dict):
        return None

    messages = data.get("messages") or []
    entries = data.get("entries") or []

    last_timestamp = None
    if messages:
        last = messages[-1]
        if isinstance(last, dict):
            last_timestamp = last.get("timestamp")
    elif entries:
        last = entries[-1]
        if isinstance(last, dict):
            last_timestamp = last.get("timestamp")

    message_count = len(messages) if messages else len(entries)

    summary = {
        "filename": data.get("filename") or os.path.basename(path),
        "path": path,
        "title": data.get("title"),
        "timestamp": data.get("timestamp"),
        "tags": data.get("tags") or [],
        "pinned": bool(data.get("pinned")),
        "acp_session_id": data.get("acp_session_id"),
        "working_directory": data.get("working_directory")
        or _project_dir_to_path(path),
        "parent_thread_id": data.get("parent_thread_id"),
        "last_seen_message_count": data.get("last_seen_message_count"),
        "message_count": message_count,
        "last_message_timestamp": last_timestamp,
        "avante_mode": data.get("avante_mode"),
    }

    # Drop absent fields rather than sending JSON null. Lua decodes null as
    # vim.NIL, which is *truthy*, so `if history.acp_session_id then` would pass
    # and then fail on concatenation.
    return {key: value for key, value in summary.items() if value is not None}


def _project_dir_to_path(history_file: str) -> str | None:
    """Recover the working directory from the project directory name.

    avante encodes it by replacing "/" with "__", e.g.
    __Users__me__proj -> /Users/me/proj. Used only when the history file itself
    does not record working_directory.
    """
    try:
        project_dir = Path(history_file).parent.parent.name
    except (IndexError, ValueError):
        return None
    if not project_dir.startswith("__"):
        return None
    return "/" + project_dir[2:].replace("__", "/")


class ThreadIndex:
    def __init__(self, storage_path: str) -> None:
        self.storage_path = Path(storage_path)
        self.projects_dir = self.storage_path / "projects"
        self.index_path = self.storage_path / INDEX_FILENAME
        self._entries: dict[str, dict[str, Any]] = {}
        self._loaded = False

    # -- persistence -----------------------------------------------------

    def load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            with open(self.index_path, "rb") as handle:
                payload = json.loads(handle.read())
        except (OSError, ValueError):
            return
        if not isinstance(payload, dict) or payload.get("version") != INDEX_VERSION:
            return
        entries = payload.get("entries")
        if isinstance(entries, dict):
            self._entries = entries

    def save(self) -> None:
        payload = {"version": INDEX_VERSION, "entries": self._entries}
        tmp = self.index_path.with_suffix(".tmp")
        try:
            self.storage_path.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w") as handle:
                json.dump(payload, handle)
            # Atomic, so a crash mid-write cannot leave a corrupt index.
            os.replace(tmp, self.index_path)
        except OSError:
            log.warning("Could not write thread index at %s", self.index_path)

    # -- scanning --------------------------------------------------------

    def _history_files(self) -> list[tuple[str, float, int]]:
        found: list[tuple[str, float, int]] = []
        if not self.projects_dir.is_dir():
            return found

        for project in os.scandir(self.projects_dir):
            if not project.is_dir():
                continue
            history_dir = os.path.join(project.path, "history")
            try:
                children = os.scandir(history_dir)
            except OSError:
                continue
            with children:
                for item in children:
                    if not item.name.endswith(".json"):
                        continue
                    if item.name == "metadata.json" or item.name.endswith(".tmp"):
                        continue
                    try:
                        stat = item.stat()
                    except OSError:
                        continue
                    found.append((item.path, stat.st_mtime, stat.st_size))
        return found

    def refresh(self, *, force: bool = False) -> dict[str, Any]:
        """Bring the index up to date, returning scan statistics."""
        self.load()
        if force:
            self._entries = {}

        files = self._history_files()
        live_paths = set()
        stale: list[str] = []

        for path, mtime, size in files:
            live_paths.add(path)
            cached = self._entries.get(path)
            if (
                not force
                and cached is not None
                and cached.get("mtime") == mtime
                and cached.get("size") == size
            ):
                continue
            stale.append(path)

        # Forget files that no longer exist.
        for path in list(self._entries):
            if path not in live_paths:
                del self._entries[path]

        stat_by_path = {path: (mtime, size) for path, mtime, size in files}
        parsed = self._parse(stale)

        for path, summary in parsed.items():
            mtime, size = stat_by_path.get(path, (0, 0))
            self._entries[path] = {
                "mtime": mtime,
                "size": size,
                # None marks a file we failed to parse, so it is not retried
                # until it changes.
                "summary": summary,
            }

        if stale:
            self.save()

        return {
            "scanned": len(files),
            "parsed": len(stale),
            "cached": len(files) - len(stale),
        }

    def _parse(self, paths: list[str]) -> dict[str, dict[str, Any] | None]:
        if not paths:
            return {}

        if len(paths) < PARALLEL_THRESHOLD:
            return {path: summarize_file(path) for path in paths}

        try:
            workers = min(os.cpu_count() or 2, 8)
            with ProcessPoolExecutor(max_workers=workers) as pool:
                results = list(pool.map(summarize_file, paths, chunksize=4))
            return dict(zip(paths, results))
        except Exception:
            # Process pools can be unavailable (sandboxes, restricted spawn).
            # Correctness matters more than speed here.
            log.warning("Parallel history parse unavailable; falling back to serial")
            return {path: summarize_file(path) for path in paths}

    # -- output ----------------------------------------------------------

    def summaries(self, limit: int | None = None) -> list[dict[str, Any]]:
        rows = [
            entry["summary"]
            for entry in self._entries.values()
            if entry.get("summary")
        ]
        # Pinned first, then most recent activity, matching the picker's order.
        rows.sort(key=_sort_key, reverse=True)
        if limit is not None and limit > 0:
            return rows[:limit]
        return rows


def _sort_key(summary: dict[str, Any]) -> tuple[int, str]:
    timestamp = summary.get("last_message_timestamp") or summary.get("timestamp") or ""
    return (1 if summary.get("pinned") else 0, str(timestamp))


_indexes: dict[str, ThreadIndex] = {}


def list_threads(
    storage_path: str, *, limit: int | None = None, force: bool = False
) -> dict[str, Any]:
    """List every thread, refreshing only what changed on disk."""
    index = _indexes.get(storage_path)
    if index is None:
        index = ThreadIndex(storage_path)
        _indexes[storage_path] = index

    stats = index.refresh(force=force)
    threads = index.summaries(limit=limit)
    stats["returned"] = len(threads)
    return {"threads": threads, "stats": stats}
