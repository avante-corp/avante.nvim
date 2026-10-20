local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "get_diagnostics"

M.description = "Get diagnostics from a specific file"

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The path to the file in the current project scope",
      type = "string",
    },
  },
  usage = {
    path = "The path to the file in the current project scope",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "diagnostics",
    description = "The diagnostics for the file",
    type = "string",
  },
  {
    name = "error",
    description = "Error message if the replacement failed",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, diff: string }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  if not input.path then return false, "path is required" end
  if on_log then on_log("path: " .. input.path) end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not on_complete then return false, "on_complete is required" end
  local diagnostics = Utils.lsp.get_diagnostics_from_filepath(abs_path)
  local jsn_str = vim.json.encode(diagnostics)
  on_complete(jsn_str, nil)
end

return M
