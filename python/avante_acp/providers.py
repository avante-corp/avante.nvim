"""Built-in agent launch definitions.

Neovim may override any of these when calling ``agent/spawn`` -- ``config.lua``
stays the source of truth for user configuration. These are the defaults the
bridge falls back to when only a provider name is given, and they are where the
knowledge of "how do you start Cursor in ACP mode" lives.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Provider:
    name: str
    command: str
    args: tuple[str, ...] = ()
    env: dict[str, str] = field(default_factory=dict)
    auth_method: str | None = None
    # Where to look for MCP server definitions, relative to the project root.
    mcp_config_paths: tuple[str, ...] = ()
    notes: str = ""


PROVIDERS: dict[str, Provider] = {
    # The successor to @zed-industries/claude-code-acp, which is what avante
    # used to shell out to via scripts/acp-wrapper.mjs. The wrapper existed to
    # monkey-patch AskUserQuestion into the old package and is not needed here.
    "claude": Provider(
        name="claude",
        command="npx",
        args=("-y", "@agentclientprotocol/claude-agent-acp"),
        env={},
        mcp_config_paths=(".mcp.json",),
    ),
    # Cursor's docs render the invocation as `agent acp`, but the binary the
    # Cursor CLI installs is `cursor-agent`. Requires `cursor-agent login`, or
    # CURSOR_API_KEY / CURSOR_AUTH_TOKEN in the environment.
    "cursor": Provider(
        name="cursor",
        command="cursor-agent",
        args=("acp",),
        auth_method="cursor_login",
        mcp_config_paths=(".cursor/mcp.json",),
        notes="Team-level MCP servers from the Cursor dashboard are unavailable in ACP mode.",
    ),
    "gemini": Provider(
        name="gemini",
        command="gemini",
        args=("--experimental-acp",),
        auth_method="gemini-api-key",
    ),
    "goose": Provider(name="goose", command="goose", args=("acp",)),
    "codex": Provider(name="codex", command="codex-acp"),
    "opencode": Provider(name="opencode", command="opencode", args=("acp",)),
    "kimi": Provider(name="kimi", command="kimi", args=("--acp",)),
}

# Names avante's config.lua uses today, mapped onto the definitions above.
ALIASES = {
    "claude-code": "claude",
    "gemini-cli": "gemini",
    "kimi-cli": "kimi",
    "cursor-agent": "cursor",
}


def resolve(name: str) -> Provider | None:
    return PROVIDERS.get(ALIASES.get(name, name))


def build_command(
    name: str,
    *,
    command: str | None = None,
    args: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> tuple[str, list[str], dict[str, str]]:
    """Merge a provider default with explicit overrides from Neovim."""
    provider = resolve(name)

    resolved_command = command or (provider.command if provider else None)
    if not resolved_command:
        raise ValueError(f"Unknown provider {name!r} and no command supplied")

    if args is not None:
        resolved_args = list(args)
    else:
        resolved_args = list(provider.args) if provider else []

    resolved_env = dict(os.environ)
    if provider:
        resolved_env.update(provider.env)
    if env:
        resolved_env.update({k: str(v) for k, v in env.items()})

    return resolved_command, resolved_args, resolved_env


def discover_mcp_servers(name: str, cwd: str) -> list[dict[str, Any]]:
    """Read MCP server definitions a provider expects to find on disk.

    avante previously passed ``mcpServers = {}`` to every ``session/new``, so
    configured MCP servers never reached any agent.
    """
    provider = resolve(name)
    if provider is None:
        return []

    servers: list[dict[str, Any]] = []
    seen: set[str] = set()

    for relative in provider.mcp_config_paths:
        path = Path(cwd) / relative
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        for server_name, spec in (data.get("mcpServers") or {}).items():
            if server_name in seen or not isinstance(spec, dict):
                continue
            seen.add(server_name)
            converted = _to_acp_server(server_name, spec)
            if converted is not None:
                servers.append(converted)

    return servers


def _to_acp_server(name: str, spec: dict[str, Any]) -> dict[str, Any] | None:
    """Convert one entry of an mcp.json into an ACP McpServer."""
    url = spec.get("url")
    if url:
        transport = spec.get("type") or "http"
        headers = [
            {"name": key, "value": str(value)}
            for key, value in (spec.get("headers") or {}).items()
        ]
        return {"type": transport, "name": name, "url": url, "headers": headers}

    command = spec.get("command")
    if not command:
        return None
    return {
        "name": name,
        "command": command,
        "args": list(spec.get("args") or []),
        "env": [
            {"name": key, "value": str(value)}
            for key, value in (spec.get("env") or {}).items()
        ],
    }
