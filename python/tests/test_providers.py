from __future__ import annotations

import json

import pytest

from avante_acp import providers


def test_known_providers_are_present():
    assert set(providers.PROVIDERS) >= {
        "claude",
        "cursor",
        "gemini",
        "goose",
        "codex",
        "opencode",
        "kimi",
    }


def test_cursor_launches_the_real_binary():
    # Cursor's docs render this as `agent acp`, but the installed binary is
    # cursor-agent; `agent` does not exist.
    cursor = providers.resolve("cursor")

    assert cursor.command == "cursor-agent"
    assert cursor.args == ("acp",)
    assert cursor.auth_method == "cursor_login"


def test_claude_uses_the_maintained_package():
    # Not @zed-industries/claude-code-acp, which is the legacy package the
    # acp-wrapper.mjs shim was built against.
    claude = providers.resolve("claude")

    assert "@agentclientprotocol/claude-agent-acp" in claude.args


@pytest.mark.parametrize(
    ("alias", "expected"),
    [
        ("claude-code", "claude"),
        ("gemini-cli", "gemini"),
        ("kimi-cli", "kimi"),
        ("cursor-agent", "cursor"),
    ],
)
def test_config_lua_names_resolve(alias, expected):
    assert providers.resolve(alias).name == expected


def test_unknown_provider_resolves_to_none():
    assert providers.resolve("not-a-real-agent") is None


def test_build_command_uses_provider_defaults():
    command, args, _ = providers.build_command("cursor")

    assert command == "cursor-agent"
    assert args == ["acp"]


def test_build_command_overrides_win():
    command, args, env = providers.build_command(
        "cursor", command="/custom/bin", args=["--flag"], env={"X": "1"}
    )

    assert command == "/custom/bin"
    assert args == ["--flag"]
    assert env["X"] == "1"


def test_build_command_inherits_the_environment():
    _, _, env = providers.build_command("cursor")

    assert "PATH" in env


def test_build_command_requires_a_command_for_unknown_providers():
    with pytest.raises(ValueError):
        providers.build_command("not-a-real-agent")


def test_unknown_provider_with_explicit_command_is_allowed():
    command, args, _ = providers.build_command(
        "homegrown", command="/opt/agent", args=["acp"]
    )

    assert (command, args) == ("/opt/agent", ["acp"])


# -- MCP discovery -------------------------------------------------------
# avante passed mcpServers = {} to every session/new, so configured MCP
# servers never reached any agent.


def test_discovers_stdio_mcp_servers_from_cursor_config(tmp_path):
    config = tmp_path / ".cursor" / "mcp.json"
    config.parent.mkdir(parents=True)
    config.write_text(
        json.dumps(
            {
                "mcpServers": {
                    "db": {
                        "command": "mcp-db",
                        "args": ["--port", "5432"],
                        "env": {"TOKEN": "abc"},
                    }
                }
            }
        )
    )

    servers = providers.discover_mcp_servers("cursor", str(tmp_path))

    assert servers == [
        {
            "name": "db",
            "command": "mcp-db",
            "args": ["--port", "5432"],
            "env": [{"name": "TOKEN", "value": "abc"}],
        }
    ]


def test_discovers_http_mcp_servers(tmp_path):
    config = tmp_path / ".cursor" / "mcp.json"
    config.parent.mkdir(parents=True)
    config.write_text(
        json.dumps(
            {
                "mcpServers": {
                    "remote": {
                        "url": "https://example.com/mcp",
                        "headers": {"Authorization": "Bearer x"},
                    }
                }
            }
        )
    )

    servers = providers.discover_mcp_servers("cursor", str(tmp_path))

    assert servers[0]["type"] == "http"
    assert servers[0]["url"] == "https://example.com/mcp"
    assert servers[0]["headers"] == [{"name": "Authorization", "value": "Bearer x"}]


def test_claude_reads_dot_mcp_json(tmp_path):
    (tmp_path / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"local": {"command": "mcp-local"}}})
    )

    servers = providers.discover_mcp_servers("claude", str(tmp_path))

    assert [s["name"] for s in servers] == ["local"]


def test_missing_config_yields_nothing(tmp_path):
    assert providers.discover_mcp_servers("cursor", str(tmp_path)) == []


def test_malformed_config_is_ignored_rather_than_fatal(tmp_path):
    config = tmp_path / ".cursor" / "mcp.json"
    config.parent.mkdir(parents=True)
    config.write_text("{ not json")

    assert providers.discover_mcp_servers("cursor", str(tmp_path)) == []


def test_entry_without_command_or_url_is_skipped(tmp_path):
    (tmp_path / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"broken": {"description": "no transport"}}})
    )

    assert providers.discover_mcp_servers("claude", str(tmp_path)) == []


def test_provider_without_mcp_paths_yields_nothing(tmp_path):
    (tmp_path / ".mcp.json").write_text(
        json.dumps({"mcpServers": {"x": {"command": "y"}}})
    )

    assert providers.discover_mcp_servers("goose", str(tmp_path)) == []
