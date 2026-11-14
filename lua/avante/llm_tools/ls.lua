local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")

---@class avante.tools.ls: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "ls"

M.description = "List files and directories in a given path in current project scope"

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "Relative path to the project directory",
      type = "string",
    },
    {
      name = "max_depth",
      description = "Maximum depth of the directory",
      type = "integer",
    },
  },
  usage = {
    path = "Relative path to the project directory",
    max_depth = "Maximum depth of the directory",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "entries",
    description = "List of file paths and directorie paths in the given directory",
    type = "string[]",
  },
  {
    name = "error",
    description = "Error message if the directory was not listed successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, max_depth?: integer }>
function M.func(input, opts)
  local on_log = opts.on_log
  local abs_path = Utils.to_absolute_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  if on_log then on_log("max depth: " .. tostring(input.max_depth)) end
  local files = Utils.scan_directory({
    directory = abs_path,
    add_dirs = true,
    max_depth = input.max_depth,
  })
  local filepaths = {}
  for _, file in ipairs(files) do
    local uniform_path = Utils.uniform_path(file)
    table.insert(filepaths, uniform_path)
  end
  return vim.json.encode(filepaths), nil
end

return M
