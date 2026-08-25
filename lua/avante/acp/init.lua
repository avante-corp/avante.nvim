---Chooses the ACP client implementation.
---
---Both backends expose the same interface, so callers construct through here
---and never branch on the backend themselves:
---
---  "python" -- the bridge in `python/`, built on the official ACP SDK.
---             Full protocol: terminals, session/resume, MCP forwarding,
---             elicitation, capability gating.
---  "lua"    -- the built-in client in `avante.libs.acp_client`. No terminals,
---             no resume, no MCP forwarding.
---
---This replaces `avante.acp_connection`, whose factory had no callers and whose
---"rust" branch pointed at a module that never existed.

local Config = require("avante.config")
local Utils = require("avante.utils")

local M = {}

---@return "python"|"lua"
function M.backend()
  local configured = Config.acp_backend or "lua"
  if configured == "python" then
    local ok, Bridge = pcall(require, "avante.acp.bridge")
    if ok and Bridge.resolve_interpreter() then return "python" end
    Utils.warn(
      "acp_backend is 'python' but no Python environment was found; falling back to the Lua backend. "
        .. "Run `cd " .. (ok and Bridge.plugin_root() or ".") .. "/python && uv sync`, "
        .. "or see :checkhealth avante."
    )
    return "lua"
  end
  return "lua"
end

---Construct a client for the configured backend.
---@param config table
function M.new(config)
  if M.backend() == "python" then return require("avante.acp.client").new(config) end
  return require("avante.libs.acp_client"):new(config)
end

---Module exposing ERROR_CODES for the active backend.
---Both define the same JSON-RPC codes, so call sites need not care which.
function M.error_codes_module()
  if M.backend() == "python" then return require("avante.acp.client") end
  return require("avante.libs.acp_client")
end

return M
