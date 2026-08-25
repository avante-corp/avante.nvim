"""Entrypoint: speak the bridge protocol on stdio, ACP to agents.

Neovim spawns exactly one of these per instance.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

from acp.stdio import stdio_streams

from .bridge import Bridge
from .jsonrpc import Peer


def _configure_logging() -> None:
    # stdout is the protocol channel, so logs must go to stderr only.
    level = os.environ.get("AVANTE_ACP_LOG_LEVEL", "WARNING").upper()
    logging.basicConfig(
        level=getattr(logging, level, logging.WARNING),
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


async def run() -> None:
    # stdio_streams returns (stdin reader, stdout writer).
    reader, writer = await stdio_streams()
    peer = Peer(reader, writer)
    bridge = Bridge(peer)
    try:
        await peer.run()
    finally:
        await bridge.shutdown()


def main() -> int:
    _configure_logging()
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        # Neovim exited without closing cleanly.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
