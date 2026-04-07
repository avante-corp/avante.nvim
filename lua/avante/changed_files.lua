local Utils = require("avante.utils")

local M = {}

--- Tool titles from ACP agents that indicate file writes
M.ACP_WRITE_TOOL_TITLES = {
  "Write",
  "Edit",
  "Create",
  "write_to_file",
  "str_replace",
  "replace_in_file",
  "insert",
  "create",
  "edit_file",
}

--- Called from track_edited_file; schedules a quickfix refresh
---@param abs_path string
---@param session_ctx table
---@param tool_name? string
function M.on_file_edited(abs_path, session_ctx, tool_name)
  vim.schedule(function() M._refresh_qflist(session_ctx) end)
end

--- Rebuild the quickfix list from session_ctx
---@param session_ctx table
function M._refresh_qflist(session_ctx)
  local file_snapshots = session_ctx.file_snapshots or {}
  local file_order = session_ctx.edited_files_order or {}

  local items = {}
  for _, abs_path in ipairs(file_order) do
    local old_content = file_snapshots[abs_path] or ""
    local ok, new_lines = pcall(vim.fn.readfile, abs_path)
    local new_content = (ok and new_lines) and table.concat(new_lines, "\n") or ""

    local additions, deletions = 0, 0
    if old_content ~= new_content then
      local diff_text = vim.diff(old_content .. "\n", new_content .. "\n", { algorithm = "histogram" })
      if diff_text then
        for line in diff_text:gmatch("[^\n]+") do
          if line:match("^%+") and not line:match("^%+%+%+") then
            additions = additions + 1
          elseif line:match("^%-") and not line:match("^%-%-%-") then
            deletions = deletions + 1
          end
        end
      end
    end

    local text = string.format("+%d -%d", additions, deletions)
    table.insert(items, {
      filename = abs_path,
      lnum = 1,
      col = 1,
      text = text,
      type = "",
    })
  end

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", {
    title = "Avante: Changed Files (" .. #items .. ")",
  })
end

--- Open the quickfix list window
function M.open()
  local items = vim.fn.getqflist()
  if #items == 0 then
    Utils.info("No files changed in this session")
    return
  end
  vim.cmd("copen")
end

--- Clear the quickfix list
function M.clear()
  pcall(vim.fn.setqflist, {}, "r")
end

return M
