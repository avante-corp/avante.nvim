from __future__ import annotations

import asyncio
from typing import Any

import pytest

from avante_acp.jsonrpc import Peer


class LoopbackWriter:
    """Writer half that feeds bytes straight into a paired StreamReader."""

    def __init__(self, target: asyncio.StreamReader) -> None:
        self._target = target
        self.closed = False

    def write(self, data: bytes) -> None:
        if not self.closed:
            self._target.feed_data(data)

    async def drain(self) -> None:
        return None

    def close(self) -> None:
        if not self.closed:
            self.closed = True
            self._target.feed_eof()


class PeerPair:
    """Two Peers wired to each other in-process, each with its own read loop."""

    def __init__(self, left: Peer, right: Peer, tasks: list[asyncio.Task[Any]]) -> None:
        self.left = left
        self.right = right
        self._tasks = tasks

    async def aclose(self) -> None:
        await self.left.close()
        await self.right.close()
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)


@pytest.fixture
async def peer_pair() -> Any:
    left_reader = asyncio.StreamReader()
    right_reader = asyncio.StreamReader()

    left = Peer(left_reader, LoopbackWriter(right_reader), default_timeout=5.0)
    right = Peer(right_reader, LoopbackWriter(left_reader), default_timeout=5.0)

    tasks = [asyncio.create_task(left.run()), asyncio.create_task(right.run())]
    pair = PeerPair(left, right, tasks)
    try:
        yield pair
    finally:
        await pair.aclose()
