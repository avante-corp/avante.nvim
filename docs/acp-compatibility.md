# ACP compatibility matrix

Where avante's ACP client stands against the Agent Client Protocol.

- **Target protocol version:** `1` (current stable).
- **Schema source of truth:** `agentclientprotocol/agent-client-protocol`, `schema/v1/meta.json`
  (method tables) and `schema/v1/schema.json` (type definitions, 170 `$defs`).
- **Implementation:** `lua/avante/libs/acp_client.lua`.

Protocol **v2** is a draft, not a target. It renames `authenticate` → `auth/login`, replaces
`session/load` with `session/resume`, drops `session/set_mode` in favour of session config options,
and moves `fs/*` and `terminal/*` out of the client method set entirely (terminals become
`terminal_update` / `terminal_output_chunk` session updates). Design decisions should not paint us
into a corner on those, but nothing here implements v2.

Legend: ✅ implemented · ⚠️ partial · ❌ not implemented

---

## Client → Agent

| Method | Status | Notes |
|---|---|---|
| `initialize` | ⚠️ | `acp_client.lua:795`. Advertises only `fs.readTextFile` / `fs.writeTextFile`. Missing `terminal`, `elicitation.{form,url}`, `session.configOptions`, `auth.terminal`, and `clientInfo`. |
| `authenticate` | ⚠️ | Only fires when `config.auth_method` is preset. `authMethods` from the initialize response is ignored, so there is no interactive login flow. |
| `logout` | ❌ | |
| `session/new` | ⚠️ | `mcpServers` is hardcoded to `{}` at `sidebar.lua:715` — **MCP servers are never forwarded to any agent**. No `additionalDirectories`. |
| `session/load` | ✅ | |
| `session/resume` | ❌ | Mis-modelled: `acp_client.lua:825` rewrites `sessionCapabilities.resume` into `loadSession`, so resume-capable agents get a full history replay instead of a resume. |
| `session/list` | ⚠️ | Implemented but not gated on `sessionCapabilities.list`; callers fall back to scraping `~/.cache/claude-code-acp` (`thread_viewer.lua:120`). |
| `session/delete` | ❌ | |
| `session/close` | ❌ | Sessions are only released by killing the agent process. |
| `session/set_mode` | ✅ | |
| `session/set_config_option` | ✅ | |
| `session/prompt` | ✅ | Deliberately has no wall-clock deadline; bounded by `session/cancel`. |
| `session/cancel` | ✅ | Notification. |

## Agent → Client

| Method | Status | Notes |
|---|---|---|
| `session/update` | ✅ | |
| `session/request_permission` | ✅ | Every path now terminates in exactly one reply. |
| `fs/read_text_file` | ✅ | Correctly reads unsaved buffers via `Utils.read_file_from_buf_or_disk`. |
| `fs/write_text_file` | ✅ | |
| `terminal/create` | ❌ | Replies `-32601`. Not advertised in client capabilities. |
| `terminal/output` | ❌ | Replies `-32601`. |
| `terminal/wait_for_exit` | ❌ | Replies `-32601`. |
| `terminal/kill` | ❌ | Replies `-32601`. |
| `terminal/release` | ❌ | Replies `-32601`. |
| `elicitation/create` | ❌ | Replies `-32601`. The correct replacement for the `scripts/acp-wrapper.mjs` `AskUserQuestion` patch. |
| `elicitation/complete` | ❌ | Notification, ignored. |
| `$/cancel_request` | ⚠️ | Accepted and ignored — we have no long-running inbound work to abort. Never sent outbound. |
| `_`-prefixed extensions | ⚠️ | No extension is implemented, but unknown requests now get the spec-required `-32601` and unknown notifications are silently ignored. |

## SessionUpdate variants

| Variant | Status | Notes |
|---|---|---|
| `agent_message_chunk` | ✅ | `llm.lua:1161` |
| `agent_thought_chunk` | ✅ | `llm.lua:1193` |
| `tool_call` | ✅ | `llm.lua:1219` |
| `tool_call_update` | ✅ | `llm.lua:1336` |
| `plan` | ✅ | `llm.lua:1128` |
| `available_commands_update` | ✅ | `llm.lua:1390` |
| `current_mode_update` | ✅ | Handled inside the client. |
| `config_option_update` | ✅ | Both the spec name and the pluralised `config_options_update` some agents emit are accepted. |
| `user_message_chunk` | ❌ | Typed but unhandled — this is why loaded sessions replay with the user's turns missing. |
| `session_info_update` | ❌ | Would give thread titles for free. |
| `usage_update` | ❌ | Token counts and cost. |

## ContentBlock / ToolCallContent

| Type | Status | Notes |
|---|---|---|
| `text` | ✅ | |
| `resource_link` | ⚠️ | Accepted, not rendered. Every agent MUST support it. |
| `image` | ❌ | Not advertised in `promptCapabilities`, so agents cannot send it either. |
| `audio` | ❌ | Not advertised. |
| `resource` (embedded) | ❌ | Not advertised. |
| ToolCallContent `content` | ✅ | |
| ToolCallContent `diff` | ⚠️ | Reconstructed from `rawInput.oldString`/`newString` (`history/render.lua:672`) instead of reading the spec `diff` variant. |
| ToolCallContent `terminal` | ❌ | Depends on `terminal/*`. |

## Providers

Configured in `config.lua:251-301`.

| Provider | Command | Status |
|---|---|---|
| `claude-code` | `npx -y --package @zed-industries/claude-code-acp …` | ⚠️ Pinned to the **legacy** package. The successor is `@agentclientprotocol/claude-agent-acp`. `scripts/acp-wrapper.mjs` only patches v0.12.6 but installs unpinned, so the shim is already stale. |
| `gemini-cli` | `gemini --experimental-acp` | ✅ |
| `goose` | `goose acp` | ✅ |
| `codex` | `codex-acp` | ✅ |
| `opencode` | `opencode acp` | ✅ |
| `kimi-cli` | `kimi --acp` | ✅ |
| `cursor` | `agent acp` | ❌ **Not configured at all.** |

### Cursor specifics

Auth via `methodId: "cursor_login"` or `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN`. Modes: `agent`,
`plan`, `ask`. MCP is read from project- or user-level `.cursor/mcp.json`; team-level MCP servers
configured in the Cursor dashboard are not available in ACP mode. Extension methods:

- Blocking (require a response): `cursor/ask_question`, `cursor/create_plan`
- Notifications: `cursor/update_todos`, `cursor/task`, `cursor/generate_image`

---

## Hardening status

Fixed:

- **Request deadlines.** Every outbound request carries one (default 30s, `session/load` and
  `session/resume` 120s, `authenticate` 300s). `session/prompt` is explicitly exempt — it is
  bounded by `session/cancel` and streamed updates, so a wall-clock timeout would be wrong.
- **Unimplemented methods reply `-32601`** instead of silence. Silence blocks the agent forever,
  which is what `terminal/*` used to do.
- **Requests vs. notifications are distinguished** by the presence of an `id`, so we reply to
  exactly the messages that expect a reply.
- **Permission requests always get exactly one answer** — including missing params, no configured
  handler, a raising handler, no sidebar, and plan-mode auto-reject with no reject option offered.
  Duplicate responses are dropped.
- **Pending requests are failed** when the agent exits or the transport is torn down, instead of
  leaving the UI spinning.
- **Agent stderr is captured** (last 50 chunks) and attached to timeout and exit diagnostics. It
  was previously read into a fully commented-out handler and discarded.
- **The stderr pipe is closed** on teardown; it used to leak.

Still outstanding:

- `acp_connection.lua` / `acp_connection_lua.lua` are dead code with zero callers, and the
  `acp_backend = "rust"` branch loads `lua/avante/acp_connection_rust.lua`, which does not exist.
- `AcpThread:handle_session_update` (`acp_thread.lua:305-655`) is an unreachable duplicate of the
  `llm.lua` dispatch.
- `AcpThread:initialize_modes` (`acp_thread.lua:165`) takes no arguments but `sidebar.lua:441`
  passes two, and `self.connection` is never assigned — it is a silent no-op.
- `acp_plan_mode_validator.lua:50` matches tool names with an unanchored Lua pattern, so `"Read"`
  matches `"ReadAndWrite"`.
- `thread_viewer.lua:104-109` blocks the editor in a `vim.wait` poll for up to 5s and can spawn a
  second agent process.
