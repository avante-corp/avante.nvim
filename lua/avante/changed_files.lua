local Utils = require("avante.utils")

local M = {}

--- Parse a unified diff hunk header
---@param line string
---@return integer old_start, integer old_count, integer new_start, integer new_count
local function parse_hunk_header(line)
  local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  os = tonumber(os) or 0
  oc = tonumber(oc) or 1
  ns = tonumber(ns) or 0
  nc = tonumber(nc) or 1
  return os, oc, ns, nc
end

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

    local rel_path = vim.fn.fnamemodify(abs_path, ":~:.")

    if old_content ~= new_content then
      local diff_text = vim.diff(old_content .. "\n", new_content .. "\n", { algorithm = "histogram" })
      if diff_text then
        local hunk_additions, hunk_deletions = 0, 0
        local hunk_new_start = nil

        for line in diff_text:gmatch("[^\n]+") do
          if line:match("^@@") then
            -- Flush previous hunk if any
            if hunk_new_start then
              table.insert(items, {
                filename = abs_path,
                lnum = hunk_new_start,
                col = 1,
                text = string.format("%s +%d -%d", rel_path, hunk_additions, hunk_deletions),
                type = "",
              })
            end
            -- Start new hunk
            local _, _, ns, _ = parse_hunk_header(line)
            hunk_new_start = ns
            hunk_additions = 0
            hunk_deletions = 0
          elseif line:match("^%+") and not line:match("^%+%+%+") then
            hunk_additions = hunk_additions + 1
          elseif line:match("^%-") and not line:match("^%-%-%-") then
            hunk_deletions = hunk_deletions + 1
          end
        end

        -- Flush last hunk
        if hunk_new_start then
          table.insert(items, {
            filename = abs_path,
            lnum = hunk_new_start,
            col = 1,
            text = string.format("%s +%d -%d", rel_path, hunk_additions, hunk_deletions),
            type = "",
          })
        end
      end
    end
  end

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", {
    title = "Avante: Changed Files (" .. #items .. " hunks)",
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
