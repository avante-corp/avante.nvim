# ACP compatibility matrix

Where avante's ACP client stands against the Agent Client Protocol.

- **Target protocol version:** `1` (current stable).
- **Schema source of truth:** `agentclientprotocol/agent-client-protocol`, `schema/v1/meta.json`
  (method tables) and `schema/v1/schema.json` (type definitions, 170 `$defs`).
- **Implementation:** the Python bridge in `python/` (`acp_backend = "python"`, the default),
  with the legacy `lua/avante/libs/acp_client.lua` retained as a fallback (`acp_backend = "lua"`).

Where the two differ, cells read ✅ (bridge) / ❌ (Lua).

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
| `initialize` | ✅ (bridge) / ⚠️ (Lua) | The bridge advertises `fs`, `terminal` and `clientInfo`, plus `elicitation.form` on an unstable connection. The Lua client advertises only `fs.*`. |
| `authenticate` | ⚠️ | Only fires when `config.auth_method` is preset. `authMethods` from the initialize response is ignored, so there is no interactive login flow. |
| `logout` | ❌ | |
| `session/new` | ✅ (bridge) / ⚠️ (Lua) | The bridge forwards MCP servers, discovering them from `.cursor/mcp.json` / `.mcp.json` when the caller passes none. The Lua client hardcoded `{}`, so servers never reached any agent. |
| `session/load` | ✅ | |
| `session/resume` | ✅ (bridge) / ❌ (Lua) | The bridge prefers resume when the agent advertises it, so reconnecting no longer replays the whole history. `acp_client.lua:825` rewrites `sessionCapabilities.resume` into `loadSession` and always replays. |
| `session/list` | ✅ (bridge) / ⚠️ (Lua) | The bridge gates on `sessionCapabilities.list` and refuses with `-32601` otherwise. `thread_viewer.lua:120` still scrapes `~/.cache/claude-code-acp` as a fallback. |
| `session/delete` | ✅ (bridge) / ❌ (Lua) | Capability-gated. |
| `session/close` | ✅ (bridge) / ❌ (Lua) | Also releases that session's terminals. Under the Lua client, sessions were freed only by killing the agent. |
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
| `terminal/create` | ✅ (bridge) / ❌ (Lua) | Implemented natively in the Python bridge via `asyncio.subprocess`; Neovim is not involved. The Lua client replies `-32601`. |
| `terminal/output` | ✅ (bridge) / ❌ (Lua) | Output is pumped continuously, so a child filling the pipe buffer cannot deadlock. Tail-truncated at `outputByteLimit`. |
| `terminal/wait_for_exit` | ✅ (bridge) / ❌ (Lua) | |
| `terminal/kill` | ✅ (bridge) / ❌ (Lua) | Reports the signal name. |
| `terminal/release` | ✅ (bridge) / ❌ (Lua) | Kills the process if still running. |
| `elicitation/create` | ✅ (unstable) | Implemented in the Python bridge and rendered by `lua/avante/acp/elicitation.lua`. Still **gated behind `use_unstable_protocol` in `agent-client-protocol` 0.12.1** despite the v1 docs listing it as a client method, so on a stable connection the agent gets `-32601`; `acp_unstable = true` (the default) is what turns it on. claude-agent-acp maps its `AskUserQuestion` tool onto this and disables the tool outright unless the client advertises `elicitation.form`. |
| `elicitation/complete` | ⚠️ | Same gate. Forwarded as an event when enabled. |
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
| `claude-code` | `npx -y @agentclientprotocol/claude-agent-acp` | ✅ Migrated off the legacy `@zed-industries/claude-code-acp`; `scripts/acp-wrapper.mjs` and `scripts/run-acp.sh` deleted. |
| `gemini-cli` | `gemini --experimental-acp` | ✅ |
| `goose` | `goose acp` | ✅ |
| `codex` | `codex-acp` | ✅ |
| `opencode` | `opencode acp` | ✅ |
| `kimi-cli` | `kimi --acp` | ✅ |
| `cursor` | `cursor-agent acp` | ⚠️ Configured, **not verified live** — `cursor-agent` on this machine is unauthenticated (`cursor-agent login` required). Note the docs render the binary as `agent`; the CLI installs it as `cursor-agent`. |

### Live-verified: `@agentclientprotocol/claude-agent-acp`

Captured by driving the Python bridge against the real agent (2026-08-24). This is the
authoritative answer to what claude supports, and it contradicts several assumptions in the Lua
client:

```
loadSession: true
promptCapabilities:  image: true, embeddedContext: true, audio: false
mcpCapabilities:     http: true, sse: true, acp: false
sessionCapabilities: list, delete, additionalDirectories, fork, resume, close   (all present)
auth:                logout
_meta.claudeCode:    promptQueueing: true
authMethods:         []          (already authenticated via the claude CLI)
```

Modes: `auto`, `default` (Manual), `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`.

Consequences:

- **`session/resume` is supported.** The Lua client's rewrite of `sessionCapabilities.resume` into
  `loadSession` (`acp_client.lua:825`) is therefore actively wrong for this agent: it replays the
  entire history on every reconnect instead of resuming.
- **`session/list` is supported.** The `~/.cache/claude-code-acp` directory scraping in
  `thread_viewer.lua:120` is unnecessary against this package.
- **`usage_update` is emitted on every turn** (with `cachedReadTokens` / `cachedWriteTokens`), and
  is currently dropped on the floor — as are token counts and cost.
- Image and embedded-context prompt content are accepted; avante advertises neither.

A full tool-call turn was exercised end to end: `tool_call` → four `tool_call_update`s →
`agent_message_chunk` → `stopReason: end_turn`, with permissions auto-approved by the bridge.
Note that claude executed its Bash tool internally and did **not** call `terminal/create`, so that
run does not exercise the client terminal path; that is covered by the fake-agent suite instead.

### Cursor specifics

Auth via `methodId: "cursor_login"` or `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN`. Modes: `agent`,
`plan`, `ask`. MCP is read from project- or user-level `.cursor/mcp.json`; team-level MCP servers
configured in the Cursor dashboard are not available in ACP mode. Extension methods:

- Blocking (require a response): `cursor/ask_question`, `cursor/create_plan`
- Notifications: `cursor/update_todos`, `cursor/task`, `cursor/generate_image`

Routes for all five are registered in `vendor.py`, because the SDK's router only forwards
`_`-prefixed methods to `Client.ext_method` and would otherwise reject these with `-32601`.

**`cursor/ask_question` never arrives in practice.** In a real session cursor sends
`cursor/create_plan` but decides its own AskQuestion tool is unavailable, thinks so out loud, and
asks its question as prose in the chat instead. Cursor's docs name no client capability that
enables it, so there is nothing to advertise. The route stays registered in case that changes.

## Asking the user a question

Three mechanisms, in the order they are preferred:

| Agent | Mechanism |
|---|---|
| claude | `elicitation/create`, native |
| cursor | `cursor/ask_question` — registered but never sent (above) |
| everything else | avante's own `ask_user_question` MCP tool |

The fallback lives in `python/avante_acp/ask_server.py`: a loopback MCP Streamable-HTTP server
with one tool, injected into `session/new`'s `mcpServers` and authenticated with a per-agent
bearer token. Its handler routes to the same `ui/elicitation` request the native path uses, so
every agent renders through one float. `acp_ask_tool` controls it — `"auto"` (default) gives it to
any provider whose `native_questions` is false, `"always"` and `"never"` override.

Both the vendor path and the MCP tool build their form through `python/avante_acp/forms.py`, since
`elicitation.lua` depends on the exact `question_<n>` / `oneOf` / `items.anyOf` shape.

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
