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
  local seen = {}

  for _, raw_path in ipairs(file_order) do
    -- One entry per file, keyed on the resolved path: the same file can be
    -- recorded under different spellings (symlinks, /tmp vs /private/tmp) and
    -- would otherwise be listed twice.
    local abs_path = vim.fn.fnamemodify(vim.fn.resolve(raw_path), ":p")

    if not seen[abs_path] then
      seen[abs_path] = true

      local old_content = file_snapshots[raw_path] or file_snapshots[abs_path] or ""
      local ok, new_lines = pcall(vim.fn.readfile, abs_path)
      local new_content = (ok and new_lines) and table.concat(new_lines, "\n") or ""

      if old_content ~= new_content then
        -- vim.diff wants a trailing newline, but only one. Empty content must
        -- stay empty (otherwise a new file diffs as replacing a blank line),
        -- and content that already ends in a newline -- which is how agents
        -- hand back a file's previous text -- must not gain a second one, or
        -- every comparison reports a phantom deleted line.
        local function terminated(text)
          if text == "" then return "" end
          if text:sub(-1) == "\n" then return text end
          return text .. "\n"
        end
        local diff_text =
          vim.diff(terminated(old_content), terminated(new_content), { algorithm = "histogram" })
        if diff_text then
          -- Totals across every hunk, and the line of the first edit. The list
          -- used to hold one entry per hunk, all labelled with the same path,
          -- so a file edited in five places appeared five times.
          local additions, deletions = 0, 0
          local first_line = nil

          for line in diff_text:gmatch("[^\n]+") do
            if line:match("^@@") then
              local _, _, new_start, _ = parse_hunk_header(line)
              if first_line == nil then first_line = new_start end
            elseif line:match("^%+") and not line:match("^%+%+%+") then
              additions = additions + 1
            elseif line:match("^%-") and not line:match("^%-%-%-") then
              deletions = deletions + 1
            end
          end

          if first_line ~= nil then
            table.insert(items, {
              filename = abs_path,
              lnum = first_line,
              col = 1,
              text = string.format("%s +%d -%d", vim.fn.fnamemodify(abs_path, ":~:."), additions, deletions),
              type = "",
            })
          end
        end
      end
    end
  end

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", {
    title = string.format("Avante: Changed Files (%d file%s)", #items, #items == 1 and "" or "s"),
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
