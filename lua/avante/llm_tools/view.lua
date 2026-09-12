local Path = require("plenary.path")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "view"

M.description = [[Reads the content of the given file in the project.

  - Never attempt to read a path that hasn't been previously mentioned.

IMPORTANT NOTE: If the file content exceeds a certain size, the returned content will be truncated, and `is_truncated` will be set to true. If `is_truncated` is true, please use the `start_line` parameter and `end_line` parameter to call this `view` tool again.
]]

M.enabled = function(opts)
  if opts.user_input:match("@read_global_file") then return false end
  for _, message in ipairs(opts.history_messages) do
    if message.role == "user" then
      local content = message.content
      if type(content) == "string" and content:match("@read_global_file") then return false end
      if type(content) == "table" then
        for _, item in ipairs(content) do
          if type(item) == "string" and item:match("@read_global_file") then return false end
        end
      end
    end
  end
  return true
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = [[The relative path of the file to read.

This path should never be absolute, and the first component of the path should always be a root directory in a project.

<example>
If the project has the following root directories:

- directory1
- directory2

If you want to access `file.txt` in `directory1`, you should use the path `directory1/file.txt`. If you want to access `file.txt` in `directory2`, you should use the path `directory2/file.txt`.
</example>]],
      type = "string",
    },
    {
      name = "start_line",
      description = "Optional line number to start reading on (1-based index)",
      type = "integer",
      optional = true,
    },
    {
      name = "end_line",
      description = "Optional line number to end reading on (1-based index, inclusive)",
      type = "integer",
      optional = true,
    },
  },
  usage = {
    path = "The path to the file in the current project scope",
    start_line = "The start line of the view range, 1-indexed",
    end_line = "The end line of the view range, 1-indexed, and -1 for the end line means read to the end of the file",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "content",
    description = "Contents of the file",
    type = "string",
  },
  {
    name = "error",
    description = "Error message if the file was not read successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, start_line?: integer, end_line?: integer }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  if not input.path then return false, "path is required" end
  if on_log then on_log("path: " .. input.path) end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Path:new(abs_path):exists() then return false, "Path not found: " .. abs_path end
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if vim.fn.isdirectory(abs_path) == 1 then return false, "Path is a directory: " .. abs_path end
  local lines = Utils.read_file_from_buf_or_disk(abs_path)
  local start_line = input.start_line
  local end_line = input.end_line
  if start_line and end_line and lines then lines = vim.list_slice(lines, start_line, end_line) end
  local truncated_lines = {}
  local is_truncated = false
  local size = 0
  for _, line in ipairs(lines or {}) do
    size = size + #line
    if size > 2048 * 100 then
      is_truncated = true
      break
    end
    table.insert(truncated_lines, line)
  end
  local total_line_count = lines and #lines or 0
  local content = truncated_lines and table.concat(truncated_lines, "\n") or ""
  local result = vim.json.encode({
    content = content,
    total_line_count = total_line_count,
    is_truncated = is_truncated,
  })
  if not on_complete then return result, nil end
  on_complete(result, nil)
end

return M
