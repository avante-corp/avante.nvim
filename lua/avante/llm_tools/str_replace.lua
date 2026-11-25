local Base = require("avante.llm_tools.base")

---@class avante.tools.str_replace: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "str_replace"

M.description =
  "The str_replace tool allows you to replace a specific string in a file with a new string. This is used for making precise edits."

function M.enabled()
  return require("avante.config").mode == "agentic" and not require("avante.config").behaviour.enable_fastapply
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The path to the file in the current project scope",
      type = "string",
    },
    {
      name = "old_str",
      description = "The text to replace (must match exactly, including whitespace and indentation)",
      type = "string",
    },
    {
      name = "new_str",
      description = "The new text to insert in place of the old text",
      type = "string",
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "True if the replacement was successful, false otherwise",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the replacement failed",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, old_str?: string, new_str?: string }>
function M.func(input, opts)
  local replace_in_file = require("avante.llm_tools.replace_in_file")
  local Utils = require("avante.utils")

  if input.new_str == nil then input.new_str = "" end

  if input.old_str == nil then input.old_str = "" end

  -- Remove trailing spaces from the new string
  input.new_str = Utils.remove_trailing_spaces(input.new_str)

  local diff = "------- SEARCH\n" .. input.old_str .. "\n=======\n" .. input.new_str
  if not opts.streaming then diff = diff .. "\n+++++++ REPLACE" end
  local new_input = {
    path = input.path,
    the_diff = diff,
  }
  return replace_in_file.func(new_input, opts)
end

return M
