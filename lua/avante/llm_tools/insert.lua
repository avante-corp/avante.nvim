local Path = require("plenary.path")
local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")
local Highlights = require("avante.highlights")

---@class avante.tools.insert: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "insert"

M.description = "The insert tool allows you to insert text at a specific location in a file."

function M.enabled()
  return require("avante.config").mode == "agentic" and not require("avante.config").behaviour.enable_fastapply
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The path to the file to modify",
      type = "string",
    },
    {
      name = "insert_line",
      description = "The line number after which to insert the text (0 for beginning of file)",
      type = "integer",
    },
    {
      name = "new_str",
      description = "The text to insert",
      type = "string",
    },
  },
  usage = {
    path = "The path to the file to modify",
    insert_line = "The line number after which to insert the text (0 for beginning of file)",
    new_str = "The text to insert",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "True if the text was inserted successfully, false otherwise",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the text was not inserted successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<avante.tools.InsertInput>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx
  if not on_complete then return false, "on_complete not provided" end

  if on_log then on_log("path: " .. input.path) end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "File not found: " .. abs_path end
  if not Path:new(abs_path):is_file() then return false, "Path is not a file: " .. abs_path end
  if input.insert_line == nil then return false, "insert_line not provided" end
  if input.new_str == nil then return false, "new_str not provided" end
  local ns_id = vim.api.nvim_create_namespace("avante_insert_diff")
  local bufnr, err = Helpers.get_bufnr(abs_path)
  if err then return false, err end
  local function clear_highlights() vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1) end
  local new_lines = vim.split(input.new_str, "\n")
  local max_col = vim.o.columns
  local virt_lines = vim
    .iter(new_lines)
    :map(
      ---@param line string
      ---@return [string, string][]
      function(line)
        --- append spaces to the end of the line
        local line_ = line .. string.rep(" ", max_col - #line)
        return { { line_, Highlights.INCOMING } }
      end
    )
    :totable()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if input.insert_line > line_count - 1 then input.insert_line = line_count - 1 end
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, input.insert_line, 0, {
    virt_lines = virt_lines,
    hl_eol = true,
    hl_mode = "combine",
  })
  Helpers.confirm("Are you sure you want to insert these lines?", function(ok, reason)
    clear_highlights()
    if not ok then
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    vim.api.nvim_buf_set_lines(bufnr, input.insert_line, input.insert_line, false, new_lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("noautocmd write") end)
    if session_ctx then Helpers.mark_as_not_viewed(input.path, session_ctx) end
    on_complete(true, nil)
  end, { focus = true }, session_ctx, M.name)
end

return M
