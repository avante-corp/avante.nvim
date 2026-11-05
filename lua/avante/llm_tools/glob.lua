local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "glob"

M.description = 'Fast file pattern matching using glob patterns like "**/*.js", in current project scope'

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "pattern",
      description = "Glob pattern",
      type = "string",
    },
    {
      name = "path",
      description = "Relative path to the project directory, as cwd",
      type = "string",
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "matches",
    description = "List of matched files",
    type = "string",
  },
  {
    name = "err",
    description = "Error message",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, pattern: string }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  if on_log then on_log("pattern: " .. input.pattern) end
  local files = vim.fn.glob(abs_path .. "/" .. input.pattern, true, true)
  local truncated_files = {}
  local is_truncated = false
  local size = 0
  for _, file in ipairs(files) do
    size = size + #file
    if size > 1024 * 10 then
      is_truncated = true
      break
    end
    table.insert(truncated_files, file)
  end
  local result = vim.json.encode({
    matches = truncated_files,
    is_truncated = is_truncated,
  })
  if not on_complete then return result, nil end
  on_complete(result, nil)
end

return M
