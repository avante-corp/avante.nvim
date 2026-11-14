local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")

---@class avante.tools.create: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "create"

M.description = "The create tool allows you to create a new file with specified content."

function M.enabled()
  return require("avante.config").mode == "agentic" and not require("avante.config").behaviour.enable_fastapply
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The path where the new file should be created",
      type = "string",
    },
    {
      name = "file_text",
      description = "The content to write to the new file",
      type = "string",
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the file was created successfully",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the file was not created successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, file_text?: string }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx
  if not on_complete then return false, "on_complete not provided" end
  if on_log then on_log("path: " .. input.path) end
  if Helpers.already_in_context(input.path) then
    on_complete(nil, "Ooooops! This file is already in the context! Why you are trying to create it again?")
    return
  end
  local abs_path = Utils.to_absolute_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  local file_text = input.file_text
  if file_text == nil then return false, "file_text not provided" end
  if Utils.filesystem.exists(abs_path) then return false, "File already exists: " .. abs_path end
  local lines = vim.split(file_text, "\n")
  if #lines == 1 and file_text:match("\\n") then
    local text = Utils.trim_escapes(file_text)
    lines = vim.split(text, "\n")
  end
  local bufnr, err = Helpers.get_bufnr(abs_path)
  if err then return false, err end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  Helpers.confirm("Are you sure you want to create this file?", function(ok, reason)
    if not ok then
      -- close the buffer
      vim.api.nvim_buf_delete(bufnr, { force = true })
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    -- save the file
    vim.fn.mkdir(vim.fs.dirname(abs_path), "p")
    local current_winid = vim.api.nvim_get_current_win()
    local winid = Utils.get_winid(bufnr)
    vim.api.nvim_set_current_win(winid)
    vim.cmd("noautocmd write")
    vim.api.nvim_set_current_win(current_winid)
    on_complete(true, nil)
  end, { focus = true }, session_ctx, M.name)
end

return M
