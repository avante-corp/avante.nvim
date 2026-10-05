---@mod avante-tools-bash Avante bash
---@brief
---Runs a shell command in a new shell process.
local Base = require("avante.llm_tools.base")

---@class AvanteLLMTool
---Gives access to bash
local M = setmetatable({}, Base)

M.name = "bash"

local banned_commands = {
  "alias",
  "curl",
  "curlie",
  "wget",
  "axel",
  "aria2c",
  "nc",
  "telnet",
  "lynx",
  "w3m",
  "links",
  "httpie",
  "xh",
  "http-prompt",
  "chrome",
  "firefox",
  "safari",
}

M.get_description = function()
  local description = ([[Executes a shell command in the requested project directory. Each call starts a new shell process; shell state does not persist between calls.

Use this tool for builds, tests, version-control operations, and other commands that dedicated tools do not cover. Prefer dedicated tools for reading, searching, and editing files. Do not use this tool for network downloads or browser commands, including: ${BANNED_COMMANDS}.

The optional timeout is measured in milliseconds, defaults to 120000, and is capped at 600000. Run only commands needed for the user's request, and do not commit or push unless the user explicitly asks.]]):gsub(
    "${BANNED_COMMANDS}",
    table.concat(banned_commands, ", ")
  )
  return description
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "Relative path to the project directory, as cwd",
      type = "string",
    },
    {
      name = "command",
      description = "Command to run",
      type = "string",
    },
    {
      name = "timeout",
      description = "Timeout in milliseconds (default 120000, maximum 600000)",
      type = "integer",
      optional = true,
      default = 120000,
    },
  },
  usage = {
    path = "Relative path to the project directory, as cwd",
    command = "Command to run",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "stdout",
    description = "Output of the command",
    type = "string",
  },
  {
    name = "error",
    description = "Error message if the command was not run successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, command: string, timeout?: integer }>
function M.func(input, opts)
  local is_streaming = opts.streaming or false
  local Helpers = require("avante.llm_tools.helpers")
  local Path = require("plenary.path")
  local Utils = require("avante.utils")

  if is_streaming then
    -- wait for stream completion as command may not be complete yet
    return
  end

  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Path not found: " .. abs_path end
  if not input.command then return false, "Command is required" end
  if opts.on_log then opts.on_log("command: " .. input.command) end
  local timeout = math.max(1, math.min(tonumber(input.timeout) or 120000, 600000))

  ---change cwd to abs_path
  ---@param output string
  ---@param exit_code integer
  ---@return string | boolean | nil result
  ---@return string | nil error
  local function handle_result(output, exit_code)
    if exit_code ~= 0 then
      if output then return false, "Error: " .. output .. "; Error code: " .. tostring(exit_code) end
      return false, "Error code: " .. tostring(exit_code)
    end
    return output, nil
  end
  if not opts.on_complete then return false, "on_complete not provided" end
  Helpers.confirm(
    "Are you sure you want to run the command: `" .. input.command .. "` in the directory: " .. abs_path,
    function(ok, reason)
      if not ok then
        opts.on_complete(false, "User declined, reason: " .. (reason and reason or "unknown"))
        return
      end
      Utils.shell_run_async(input.command, "bash -c", function(output, exit_code)
        local result, err = handle_result(output, exit_code)
        opts.on_complete(result, err)
      end, abs_path, timeout)
    end,
    { focus = true },
    opts.session_ctx,
    M.name -- Pass the tool name for permission checking
  )
end

return M
