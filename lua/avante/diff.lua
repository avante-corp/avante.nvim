local api = vim.api

local Config = require("avante.config")
local Utils = require("avante.utils")
local Highlights = require("avante.highlights")

local H = {}
local M = {}

-----------------------------------------------------------------------------//
-- REFERENCES:
-----------------------------------------------------------------------------//
-- Detecting the state of a git repository based on files in the .git directory.
-- https://stackoverflow.com/questions/49774200/how-to-tell-if-my-git-repo-is-in-a-conflict
-- git diff commands to git a list of conflicted files
-- https://stackoverflow.com/questions/3065650/whats-the-simplest-way-to-list-conflicted-files-in-git
-- how to show a full path for files in a git diff command
-- https://stackoverflow.com/questions/10459374/making-git-diff-stat-show-full-file-path
-- Advanced merging
-- https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging

-----------------------------------------------------------------------------//
-- Types
-----------------------------------------------------------------------------//

---@alias ConflictSide "ours"|"theirs"|"all_theirs"|"both"|"cursor"|"base"|"none"

---@class AvanteConflictHighlights
---@field current string
---@field incoming string

---@class RangeMark
---@field label integer?
---@field content integer?

---@class PositionMarks
---@field current RangeMark
---@field incoming RangeMark

---@class avante.ConflictRange
---@field range_start integer
---@field range_end integer
---@field content_start integer
---@field content_end integer

---@class ConflictPosition
---@field incoming avante.ConflictRange
---@field middle {range_start?: integer, range_end?: integer}
---@field current avante.ConflictRange
---@field marks? PositionMarks

---@class ConflictBufferCache
---@field lines table<integer, boolean> map of conflicted line numbers
---@field positions ConflictPosition[]
---@field tick integer
---@field bufnr integer

-----------------------------------------------------------------------------//
-- Constants
-----------------------------------------------------------------------------//
---@enum AvanteConflictSides
local SIDES = {
  OURS = "ours",
  THEIRS = "theirs",
  ALL_THEIRS = "all_theirs",
  BOTH = "both",
  NONE = "none",
  CURSOR = "cursor",
}

-- A mapping between the internal names and the display names
local name_map = {
  ours = "current",
  theirs = "incoming",
  both = "both",
  none = "none",
  cursor = "cursor",
}

local CURRENT_HL = Highlights.CURRENT
local INCOMING_HL = Highlights.INCOMING
local CURRENT_LABEL_HL = Highlights.CURRENT_LABEL
local INCOMING_LABEL_HL = Highlights.INCOMING_LABEL
local PRIORITY = (vim.hl or vim.highlight).priorities.user
local NAMESPACE = api.nvim_create_namespace("avante-conflict")
local KEYBINDING_NAMESPACE = api.nvim_create_namespace("avante-conflict-keybinding")
local AUGROUP_NAME = "avante_conflicts"

local conflict_start = "^<<<<<<<"
local conflict_middle = "^======="
local conflict_end = "^>>>>>>>"

-----------------------------------------------------------------------------//

---@return table<string, ConflictBufferCache>
local function create_visited_buffers()
  return setmetatable({}, {
    __index = function(t, k)
      if type(k) == "number" then return t[api.nvim_buf_get_name(k)] end
    end,
  })
end

--- A list of buffers that have conflicts in them. This is derived from
--- git using the diff command, and updated at intervals
local visited_buffers = create_visited_buffers()

-----------------------------------------------------------------------------//

---Add the positions to the buffer in our in memory buffer list
---positions are keyed by a list of range start and end for each mark
---@param buf integer
---@param positions ConflictPosition[]
local function update_visited_buffers(buf, positions)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  local name = api.nvim_buf_get_name(buf)
  -- If this buffer is not in the list
  if not visited_buffers[name] then return end
  visited_buffers[name].bufnr = buf
  visited_buffers[name].tick = vim.b[buf].changedtick
  visited_buffers[name].positions = positions
end

function M.add_visited_buffer(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  visited_buffers[name] = visited_buffers[name] or {}
end

---Set an extmark for each section of the git conflict
---@param bufnr integer
---@param hl string
---@param range_start integer
---@param range_end integer
---@return integer? extmark_id
local function hl_range(bufnr, hl, range_start, range_end)
  if not range_start or not range_end then return end
  return api.nvim_buf_set_extmark(bufnr, NAMESPACE, range_start, 0, {
    hl_group = hl,
    hl_eol = true,
    hl_mode = "combine",
    end_row = range_end,
    priority = PRIORITY,
  })
end

---Add highlights and additional data to each section heading of the conflict marker
---These works by covering the underlying text with an extmark that contains the same information
---with some extra detail appended.
---TODO: ideally this could be done by using virtual text at the EOL and highlighting the
---background but this doesn't work and currently this is done by filling the rest of the line with
---empty space and overlaying the line content
---@param bufnr integer
---@param hl_group string
---@param label string
---@param lnum integer
---@return integer extmark id
local function draw_section_label(bufnr, hl_group, label, lnum)
  local remaining_space = api.nvim_win_get_width(0) - api.nvim_strwidth(label)
  return api.nvim_buf_set_extmark(bufnr, NAMESPACE, lnum, 0, {
    hl_group = hl_group,
    virt_text = { { label .. string.rep(" ", remaining_space), hl_group } },
    virt_text_pos = "overlay",
    priority = PRIORITY,
  })
end

---Highlight each part of a git conflict i.e. the incoming changes vs the current/HEAD changes
---TODO: should extmarks be ephemeral? or is it less expensive to save them and only re-apply
---them when a buffer changes since otherwise we have to reparse the whole buffer constantly
---@param bufnr integer
---@param positions ConflictPosition[]
---@param lines string[]
local function highlight_conflicts(bufnr, positions, lines)
  M.clear(bufnr)

  for _, position in ipairs(positions) do
    local current_start = position.current.range_start
    local current_end = position.current.range_end
    local incoming_start = position.incoming.range_start
    local incoming_end = position.incoming.range_end
    -- Add one since the index access in lines is 1 based
    local current_label = lines[current_start + 1] .. " (Current changes)"
    local incoming_label = lines[incoming_end + 1] .. " (Incoming changes)"

    local curr_label_id = draw_section_label(bufnr, CURRENT_LABEL_HL, current_label, current_start)
    local curr_id = hl_range(bufnr, CURRENT_HL, current_start, current_end + 1)
    local inc_id = hl_range(bufnr, INCOMING_HL, incoming_start, incoming_end + 1)
    local inc_label_id = draw_section_label(bufnr, INCOMING_LABEL_HL, incoming_label, incoming_end)

    position.marks = {
      current = { label = curr_label_id, content = curr_id },
      incoming = { label = inc_label_id, content = inc_id },
    }
  end
end

---Iterate through the buffer line by line checking there is a matching conflict marker
---when we find a starting mark we collect the position details and add it to a list of positions
---@param lines string[]
---@return boolean
---@return ConflictPosition[]
local function detect_conflicts(lines)
  ---@type ConflictPosition[]
  local positions = {}
  ---@type {current: {range_start: integer, content_start: integer, range_end?: integer, content_end?: integer}, incoming: {range_start?: integer, content_start?: integer, range_end?: integer, content_end?: integer}, middle: {range_start?: integer, range_end?: integer}}?, boolean
  local position, has_middle = nil, false
  for index, line in ipairs(lines) do
    local lnum = index - 1
    if line:match(conflict_start) then
      position = {
        current = { range_start = lnum, content_start = lnum + 1 },
        middle = {},
        incoming = {},
      }
    end
    if position ~= nil and line:match(conflict_middle) then
      has_middle = true
      position.current.range_end = lnum - 1
      position.current.content_end = lnum - 1
      position.middle.range_start = lnum
      position.middle.range_end = lnum + 1
      position.incoming.range_start = lnum + 1
      position.incoming.content_start = lnum + 1
    end
    if position ~= nil and has_middle and line:match(conflict_end) then
      position.incoming.range_end = lnum
      position.incoming.content_end = lnum - 1
      ---@cast position ConflictPosition
      positions[#positions + 1] = position

      position, has_middle = nil, false
    end
  end
  return #positions > 0, positions
end

---Helper function to find a conflict position based on a comparator function
---@param bufnr integer
---@param comparator fun(string, integer): boolean
---@param opts table?
---@return ConflictPosition?
local function find_position(bufnr, comparator, opts)
  ---@type ConflictBufferCache?
  local match = visited_buffers[bufnr]
  if not match then return end
  local line = Utils.get_cursor_pos()
  line = line - 1 -- Convert to 0-based for position comparison

  if opts and opts.reverse then
    for i = #match.positions, 1, -1 do
      local position = match.positions[i]
      if comparator(line, position) then return position end
    end
    return nil
  end

  for _, position in ipairs(match.positions) do
    if comparator(line, position) then return position end
  end
  return nil
end

---Retrieves a conflict marker position by checking the visited buffers for a supported range
---@param bufnr integer
---@return ConflictPosition?
local function get_current_position(bufnr)
  return find_position(
    bufnr,
    function(line, position) return position.current.range_start <= line and position.incoming.range_end >= line end
  )
end

---@param position ConflictPosition?
---@param side ConflictSide
local function set_cursor(position, side)
  if not position then return end
  local target = side == SIDES.OURS and position.current or position.incoming
  api.nvim_win_set_cursor(0, { target.range_start + 1, 0 })
  vim.cmd("normal! zz")
end

local show_keybinding_hint_extmark_id = nil
local function register_cursor_move_events(bufnr)
  local function show_keybinding_hint(lnum)
    if show_keybinding_hint_extmark_id then
      api.nvim_buf_del_extmark(bufnr, KEYBINDING_NAMESPACE, show_keybinding_hint_extmark_id)
    end

    local hint = string.format(
      "[<%s>: OURS, <%s>: THEIRS, <%s>: CURSOR, <%s>: ALL THEIRS, <%s>: PREV, <%s>: NEXT]",
      Config.mappings.diff.ours,
      Config.mappings.diff.theirs,
      Config.mappings.diff.cursor,
      Config.mappings.diff.all_theirs,
      Config.mappings.diff.prev,
      Config.mappings.diff.next
    )

    show_keybinding_hint_extmark_id = api.nvim_buf_set_extmark(bufnr, KEYBINDING_NAMESPACE, lnum - 1, -1, {
      hl_group = "AvanteInlineHint",
      virt_text = { { hint, "AvanteInlineHint" } },
      virt_text_pos = "right_align",
      priority = PRIORITY,
    })
  end

  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinLeave" }, {
    buffer = bufnr,
    callback = function(event)
      local position = get_current_position(bufnr)
      if (event.event == "CursorMoved" or event.event == "CursorMovedI") and position then
        show_keybinding_hint(position.current.range_start + 1)

        M.override_timeoutlen(bufnr)
      else
        api.nvim_buf_clear_namespace(bufnr, KEYBINDING_NAMESPACE, 0, -1)
        M.restore_timeoutlen(bufnr)
      end
    end,
  })
end

---Get the conflict marker positions for a buffer if any and update the buffers state
---@param bufnr integer
---@param range_start? integer
---@param range_end? integer
local function parse_buffer(bufnr, range_start, range_end)
  local lines = Utils.get_buf_lines(range_start or 0, range_end or -1, bufnr)
  local prev_conflicts = visited_buffers[bufnr].positions ~= nil and #visited_buffers[bufnr].positions > 0
  local has_conflict, positions = detect_conflicts(lines)

  update_visited_buffers(bufnr, positions)
  if has_conflict then
    register_cursor_move_events(bufnr)
    highlight_conflicts(bufnr, positions, lines)
  else
    M.clear(bufnr)
  end
  if prev_conflicts ~= has_conflict or not vim.b[bufnr].avante_conflict_mappings_set then
    local pattern = has_conflict and "AvanteConflictDetected" or "AvanteConflictResolved"
    api.nvim_exec_autocmds("User", { pattern = pattern })
  end
end

---Process a buffer if the changed tick has changed
---@param bufnr integer
---@param range_start integer?
---@param range_end integer?
function M.process(bufnr, range_start, range_end)
  bufnr = bufnr
  if visited_buffers[bufnr] and visited_buffers[bufnr].tick == vim.b[bufnr].changedtick then return end
  parse_buffer(bufnr, range_start, range_end)
end

-----------------------------------------------------------------------------//
-- Mappings
-----------------------------------------------------------------------------//

---@param bufnr integer given buffer id
function H.setup_buffer_mappings(bufnr)
  ---@param desc string
  ---@return vim.keymap.set.Opts
  local function opts(desc) return { silent = true, buffer = bufnr, desc = "avante(conflict): " .. desc } end

  vim.keymap.set({ "n", "v" }, Config.mappings.diff.ours, function() M.choose("ours") end, opts("choose ours"))
  vim.keymap.set({ "n", "v" }, Config.mappings.diff.both, function() M.choose("both") end, opts("choose both"))
  vim.keymap.set({ "n", "v" }, Config.mappings.diff.theirs, function() M.choose("theirs") end, opts("choose theirs"))
  vim.keymap.set(
    { "n", "v" },
    Config.mappings.diff.all_theirs,
    function() M.choose("all_theirs") end,
    opts("choose all theirs")
  )
  vim.keymap.set("n", Config.mappings.diff.cursor, function() M.choose("cursor") end, opts("choose under cursor"))
  vim.keymap.set("n", Config.mappings.diff.prev, function() M.find_prev("ours") end, opts("previous conflict"))
  vim.keymap.set("n", Config.mappings.diff.next, function() M.find_next("ours") end, opts("next conflict"))

  vim.b[bufnr].avante_conflict_mappings_set = true
end

---@param bufnr integer
function H.clear_buffer_mappings(bufnr)
  if not bufnr or not vim.b[bufnr].avante_conflict_mappings_set then return end

  ---@type table<string, string>
  local mappings = Config.mappings.diff
  for _, diff_mapping in pairs(mappings) do
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", diff_mapping)
  end

  vim.b[bufnr].avante_conflict_mappings_set = false
  M.restore_timeoutlen(bufnr)
end

---@param bufnr integer
function M.override_timeoutlen(bufnr)
  if vim.b[bufnr].avante_original_timeoutlen then return end
  if Config.diff.override_timeoutlen > 0 then
    vim.b[bufnr].avante_original_timeoutlen = vim.o.timeoutlen
    vim.o.timeoutlen = Config.diff.override_timeoutlen
  end
end

---@param bufnr integer
function M.restore_timeoutlen(bufnr)
  if vim.b[bufnr].avante_original_timeoutlen then
    vim.o.timeoutlen = vim.b[bufnr].avante_original_timeoutlen
    vim.b[bufnr].avante_original_timeoutlen = nil
  end
end

M.augroup = api.nvim_create_augroup(AUGROUP_NAME, { clear = true })

function M.setup()
  local previous_inlay_enabled = nil

  api.nvim_create_autocmd("User", {
    group = M.augroup,
    pattern = "AvanteConflictDetected",
    callback = function(ev)
      vim.diagnostic.enable(false, { bufnr = ev.buf })
      if vim.lsp.inlay_hint then
        previous_inlay_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = ev.buf })
        vim.lsp.inlay_hint.enable(false, { bufnr = ev.buf })
      end
      H.setup_buffer_mappings(ev.buf)
    end,
  })

  api.nvim_create_autocmd("User", {
    group = M.augroup,
    pattern = "AvanteConflictResolved",
    callback = function(ev)
      vim.diagnostic.enable(true, { bufnr = ev.buf })
      if vim.lsp.inlay_hint and previous_inlay_enabled ~= nil then
        vim.lsp.inlay_hint.enable(previous_inlay_enabled, { bufnr = ev.buf })
        previous_inlay_enabled = nil
      end
      H.clear_buffer_mappings(ev.buf)
    end,
  })

  api.nvim_set_decoration_provider(NAMESPACE, {
    on_win = function(_, _, bufnr, _, _)
      if visited_buffers[bufnr] then M.process(bufnr) end
    end,
  })
end

--- Add additional metadata to a quickfix entry if we have already visited the buffer and have that
--- information
---@param item table<string, integer|string>
---@param items table<string, integer|string>[]
---@param visited_buf ConflictBufferCache
local function quickfix_items_from_positions(item, items, visited_buf)
  if vim.tbl_isempty(visited_buf.positions) then return end
  for _, pos in ipairs(visited_buf.positions) do
    for key, value in pairs({ current = pos.current, incoming = pos.incoming, middle = pos.middle }) do
      if vim.tbl_contains({ name_map.ours, name_map.theirs, name_map.base }, key) and not vim.tbl_isempty(value) then
        ---@cast value {range_start: integer}
        local lnum = value.range_start + 1
        local next_item = vim.deepcopy(item)
        next_item.text = string.format("%s change", key, lnum)
        next_item.lnum = lnum
        next_item.col = 0
        table.insert(items, next_item)
      end
    end
  end
end

--- Convert the conflicts detected via get conflicted files into a list of quickfix entries.
---@param callback fun(files: table<string, integer[]>)
function M.conflicts_to_qf_items(callback)
  local items = {}
  for filename, visited_buf in pairs(visited_buffers) do
    local item = {
      filename = filename,
      pattern = conflict_start,
      text = "git conflict",
      type = "E",
      valid = 1,
    }

    if visited_buf and next(visited_buf) then
      quickfix_items_from_positions(item, items, visited_buf)
    else
      table.insert(items, item)
    end
  end

  callback(items)
end

---@param bufnr integer?
function M.clear(bufnr)
  if bufnr and not api.nvim_buf_is_valid(bufnr) then return end
  bufnr = bufnr or 0
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, KEYBINDING_NAMESPACE, 0, -1)
end

---@param side ConflictSide
function M.find_next(side)
  local pos = find_position(
    0,
    function(line, position) return position.current.range_start > line and position.incoming.range_end > line end
  )
  set_cursor(pos, side)
end

---@param side ConflictSide
function M.find_prev(side)
  local pos = find_position(
    0,
    function(line, position) return position.current.range_start <= line and position.incoming.range_end <= line end,
    { reverse = true }
  )
  set_cursor(pos, side)
end

---Select the changes to keep
---@param side ConflictSide
function M.choose(side)
  local bufnr = api.nvim_get_current_buf()
  if vim.fn.mode() == "v" or vim.fn.mode() == "V" or vim.fn.mode() == "" then
    vim.cmd("noautocmd stopinsert")
    -- have to defer so that the < and > marks are set
    vim.defer_fn(function()
      local start = api.nvim_buf_get_mark(0, "<")[1]
      local finish = api.nvim_buf_get_mark(0, ">")[1]
      local position = find_position(bufnr, function(_, pos)
        local left = pos.current.range_start >= start - 1
        local right = pos.incoming.range_end <= finish + 1
        return left and right
      end)
      while position ~= nil do
        M.process_position(bufnr, side, position, false)
        position = find_position(bufnr, function(_, pos)
          local left = pos.current.range_start >= start - 1
          local right = pos.incoming.range_end <= finish + 1
          return left and right
        end)
      end
    end, 50)
    if Config.diff.autojump then
      M.find_next(side)
      vim.cmd([[normal! zz]])
    end
    return
  end
  local position = get_current_position(bufnr)
  if not position then return end
  if side == SIDES.ALL_THEIRS then
    ---@diagnostic disable-next-line: unused-local
    local pos = find_position(bufnr, function(line, pos) return true end)
    while pos ~= nil do
      M.process_position(bufnr, "theirs", pos, false)
      ---@diagnostic disable-next-line: unused-local
      pos = find_position(bufnr, function(line, pos_) return true end)
    end
  else
    M.process_position(bufnr, side, position, true)
  end
end

---@param bufnr integer
---@param side ConflictSide
---@param position ConflictPosition
---@param enable_autojump boolean
function M.process_position(bufnr, side, position, enable_autojump)
  local lines = {}
  if vim.tbl_contains({ SIDES.OURS, SIDES.THEIRS }, side) then
    ---@type avante.ConflictRange
    local data = position[name_map[side]]
    lines = Utils.get_buf_lines(data.content_start, data.content_end + 1)
  elseif side == SIDES.BOTH then
    local first = Utils.get_buf_lines(position.current.content_start, position.current.content_end + 1)
    local second = Utils.get_buf_lines(position.incoming.content_start, position.incoming.content_end + 1)
    lines = vim.list_extend(first, second)
  elseif side == SIDES.NONE then
    lines = {}
  elseif side == SIDES.CURSOR then
    local cursor_line = Utils.get_cursor_pos()
    for _, pos in ipairs({ SIDES.OURS, SIDES.THEIRS }) do
      local data = position[name_map[pos]] or {}
      if data.range_start and data.range_start + 1 <= cursor_line and data.range_end + 1 >= cursor_line then
        side = pos
        lines = Utils.get_buf_lines(data.content_start, data.content_end + 1)
        break
      end
    end
    if side == SIDES.CURSOR then return end
  else
    return
  end

  local pos_start = position.current.range_start < 0 and 0 or position.current.range_start
  local pos_end = position.incoming.range_end + 1

  api.nvim_buf_set_lines(0, pos_start, pos_end, false, lines)
  api.nvim_buf_del_extmark(0, NAMESPACE, position.marks.incoming.label)
  api.nvim_buf_del_extmark(0, NAMESPACE, position.marks.current.label)
  parse_buffer(bufnr)
  if enable_autojump and Config.diff.autojump then
    M.find_next(side)
    vim.cmd([[normal! zz]])
  end
end

function M.conflict_count(bufnr)
  if bufnr and not api.nvim_buf_is_valid(bufnr) then return 0 end
  bufnr = bufnr or 0

  local name = api.nvim_buf_get_name(bufnr)
  if not visited_buffers[name] then return 0 end

  return #visited_buffers[name].positions
end

return M
