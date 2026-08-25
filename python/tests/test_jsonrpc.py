"""The bridge hop must never leave either side waiting forever.

Each test here corresponds to a way the previous Lua-only client could stall.
"""

from __future__ import annotations

import asyncio

import pytest

from avante_acp.jsonrpc import (
    CONNECTION_CLOSED,
    INTERNAL_ERROR,
    METHOD_NOT_FOUND,
    TIMEOUT_ERROR,
    Peer,
    RpcError,
)


async def test_request_response_roundtrip(peer_pair):
    async def echo(params):
        return {"echoed": params["value"]}

    peer_pair.right.on_request("echo", echo)

    assert await peer_pair.left.request("echo", {"value": 7}) == {"echoed": 7}


async def test_unknown_request_gets_method_not_found(peer_pair):
    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("nope/does_not_exist", {})

    assert excinfo.value.code == METHOD_NOT_FOUND


async def test_unknown_notification_is_ignored(peer_pair):
    # Must not raise, and must not produce a reply the other side would choke on.
    await peer_pair.left.notify("nope/unknown", {})
    await asyncio.sleep(0.05)


async def test_handler_exception_becomes_error_reply(peer_pair):
    async def boom(params):
        raise ValueError("kaboom")

    peer_pair.right.on_request("boom", boom)

    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("boom", {})

    assert excinfo.value.code == INTERNAL_ERROR
    assert "kaboom" in excinfo.value.message


async def test_handler_rpc_error_preserves_code(peer_pair):
    async def denied(params):
        raise RpcError.invalid_params("bad path")

    peer_pair.right.on_request("denied", denied)

    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("denied", {})

    assert excinfo.value.code == -32602
    assert excinfo.value.message == "bad path"


async def test_request_times_out(peer_pair):
    async def never(params):
        await asyncio.sleep(60)

    peer_pair.right.on_request("never", never)

    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("never", {}, timeout=0.1)

    assert excinfo.value.code == TIMEOUT_ERROR


async def test_zero_timeout_means_no_deadline(peer_pair):
    async def slow(params):
        await asyncio.sleep(0.2)
        return "done"

    peer_pair.right.on_request("slow", slow)

    # Would fail if 0 were treated as "expire immediately".
    assert await peer_pair.left.request("slow", {}, timeout=0) == "done"


async def test_close_fails_inflight_requests(peer_pair):
    async def never(params):
        await asyncio.sleep(60)

    peer_pair.right.on_request("never", never)

    pending = asyncio.create_task(peer_pair.left.request("never", {}, timeout=0))
    await asyncio.sleep(0.05)
    await peer_pair.left.close("agent died")

    with pytest.raises(RpcError) as excinfo:
        await pending

    assert excinfo.value.code == CONNECTION_CLOSED
    assert excinfo.value.message == "agent died"


async def test_request_on_closed_peer_raises(peer_pair):
    await peer_pair.left.close()

    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("anything", {})

    assert excinfo.value.code == CONNECTION_CLOSED


async def test_slow_handler_does_not_block_other_requests(peer_pair):
    """A blocked permission prompt must not stall unrelated traffic."""

    async def slow(params):
        await asyncio.sleep(0.3)
        return "slow"

    async def fast(params):
        return "fast"

    peer_pair.right.on_request("slow", slow)
    peer_pair.right.on_request("fast", fast)

    slow_task = asyncio.create_task(peer_pair.left.request("slow", {}, timeout=0))
    await asyncio.sleep(0.02)
    assert await peer_pair.left.request("fast", {}, timeout=1) == "fast"
    assert await slow_task == "slow"


async def test_concurrent_requests_get_matched_to_their_own_replies(peer_pair):
    async def identity(params):
        await asyncio.sleep(params["delay"])
        return params["n"]

    peer_pair.right.on_request("identity", identity)

    results = await asyncio.gather(
        *[
            peer_pair.left.request("identity", {"n": n, "delay": (5 - n) * 0.02}, timeout=0)
            for n in range(5)
        ]
    )

    assert results == [0, 1, 2, 3, 4]


async def test_malformed_json_does_not_kill_the_read_loop():
    reader = asyncio.StreamReader()
    peer = Peer(reader, _NullWriter())
    task = asyncio.create_task(peer.run())

    reader.feed_data(b"{ this is not json\n")
    reader.feed_data(b'{"jsonrpc":"2.0","method":"ping","params":{}}\n')

    seen = asyncio.Event()

    async def ping(params):
        seen.set()

    peer.on_notification("ping", ping)
    reader.feed_data(b'{"jsonrpc":"2.0","method":"ping","params":{}}\n')

    await asyncio.wait_for(seen.wait(), timeout=2)

    reader.feed_eof()
    await asyncio.wait_for(task, timeout=2)


async def test_notification_handler_is_not_used_for_requests(peer_pair):
    """A method registered only as a notification still owes a reply if called
    as a request, rather than silently doing nothing."""

    async def note(params):
        return None

    peer_pair.right.on_notification("note", note)

    with pytest.raises(RpcError) as excinfo:
        await peer_pair.left.request("note", {})

    assert excinfo.value.code == METHOD_NOT_FOUND


class _NullWriter:
    def write(self, data: bytes) -> None:
        return None

    async def drain(self) -> None:
        return None
