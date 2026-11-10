local Highlights = require("avante.highlights")
local Line = require("avante.ui.line")
local Utils = require("avante.utils")

---@class avante.ui.ButtonGroupLine
---@field _line avante.ui.Line
---@field _button_options { id: string, icon?: string, name: string, hl?: string }[]
---@field _focus_index integer
---@field _group_label string|nil
---@field _start_col integer
---@field _button_pos integer[][]
---@field _ns_id integer|nil
---@field _bufnr integer|nil
---@field _line_1b integer|nil
---@field on_click? fun(id: string)
local ButtonGroupLine = {}
ButtonGroupLine.__index = ButtonGroupLine

-- per-buffer registry for dispatching shared keymaps/autocmds
---@type table<integer, { lines: table<integer, avante.ui.ButtonGroupLine>, mapped: boolean, autocmd: integer|nil }>
local registry
registry = {}

local function ensure_dispatch(bufnr)
  local entry = registry[bufnr]
  if not entry then
    entry = { lines = {}, mapped = false, autocmd = nil }
    registry[bufnr] = entry
  end
  if not entry.mapped then
    -- Tab: next button if on a group line; otherwise fall back to sidebar switch_windows
    vim.keymap.set("n", "<Tab>", function()
      local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
      local group = entry.lines[row]
      if not group then
        local ok, sidebar = pcall(require, "avante")
        if ok and sidebar and sidebar.get then
          local sb = sidebar.get()
          if sb and sb.switch_window_focus then
            sb:switch_window_focus("next")
            return
          end
        end
        -- Fallback to raw <Tab> if sidebar is unavailable
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", true)
        return
      end
      group._focus_index = group._focus_index + 1
      if group._focus_index > #group._button_options then group._focus_index = 1 end
      group:_refresh_highlights()
      group:_move_cursor_to_focus()
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", "<S-Tab>", function()
      local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
      local group = entry.lines[row]
      if not group then
        local ok, sidebar = pcall(require, "avante")
        if ok and sidebar and sidebar.get then
          local sb = sidebar.get()
          if sb and sb.switch_window_focus then
            sb:switch_window_focus("previous")
            return
          end
        end
        -- Fallback to raw <S-Tab> if sidebar is unavailable
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "n", true)
        return
      end
      group._focus_index = group._focus_index - 1
      if group._focus_index < 1 then group._focus_index = #group._button_options end
      group:_refresh_highlights()
      group:_move_cursor_to_focus()
    end, { buffer = bufnr, nowait = true })

    vim.keymap.set("n", "<CR>", function()
      local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
      local group = entry.lines[row]
      if not group then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", true)
        return
      end
      group:_click_focused()
    end, { buffer = bufnr, nowait = true })

    -- Mouse click to activate
    vim.api.nvim_buf_set_keymap(bufnr, "n", "<LeftMouse>", "", {
      callback = function()
        local pos = vim.fn.getmousepos()
        local row, col = pos.winrow, pos.wincol
        local group = entry.lines[row]
        if not group then return end
        group:_update_focus_by_col(col)
        group:_click_focused()
      end,
      noremap = true,
      silent = true,
    })

    -- CursorMoved hover highlight
    entry.autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      callback = function()
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local group = entry.lines[row]
        if not group then return end
        group:_update_focus_by_col(col)
      end,
    })

    entry.mapped = true
  end
end

local function cleanup_dispatch_if_empty(bufnr)
  local entry = registry[bufnr]
  if not entry then return end
  -- Do not delete keymaps when no button lines remain.
  -- Deleting buffer-local mappings would not restore any previous mapping,
  -- which breaks the original Tab behavior in the sidebar.
  -- We intentionally keep the keymaps and autocmds; they safely no-op or
  -- fall back when not on a button group line.
end

---@param button_options { id: string, icon: string|nil, name: string, hl?: string }[]
---@param opts? { on_click?: fun(id: string), start_col?: integer, group_label?: string }
---@return avante.ui.ButtonGroupLine
function ButtonGroupLine:new(button_options, opts)
  opts = opts or {}
  local o = setmetatable({}, ButtonGroupLine)
  o._button_options = vim.deepcopy(button_options)
  o._focus_index = 1
  o._start_col = opts.start_col or 0
  o._group_label = opts.group_label

  local BUTTON_NORMAL = Highlights.BUTTON_DEFAULT
  local BUTTON_FOCUS = Highlights.BUTTON_DEFAULT_HOVER

  local sections = {}
  if o._group_label and #o._group_label > 0 then table.insert(sections, { o._group_label .. " " }) end
  local btn_sep = "   "
  for i, opt in ipairs(o._button_options) do
    ---@type string
    local label
    if opt.icon and #opt.icon > 0 then
      label = string.format(" %s %s ", opt.icon, opt.name)
    else
      label = string.format(" %s ", opt.name)
    end
    local focus_hl = opt.hl or BUTTON_FOCUS
    table.insert(sections, { label, function() return (o._focus_index == i) and focus_hl or BUTTON_NORMAL end })
    if i < #o._button_options then table.insert(sections, { btn_sep }) end
  end
  o._line = Line:new(sections)

  -- precalc positions for quick hover/click checks
  o._button_pos = {}
  local sec_idx = (o._group_label and #o._group_label > 0) and 2 or 1
  for i = 1, #o._button_options do
    local start_end = o._line:get_section_pos(sec_idx, o._start_col)
    o._button_pos[i] = { start_end[1], start_end[2] }
    if i < #o._button_options then
      sec_idx = sec_idx + 2
    else
      sec_idx = sec_idx + 1
    end
  end

  if opts.on_click then o.on_click = opts.on_click end

  return o
end

function ButtonGroupLine:__tostring() return string.rep(" ", self._start_col) .. tostring(self._line) end

---@param ns_id integer
---@param bufnr integer
---@param line_0b integer
---@param _offset integer|nil -- ignored; offset handled in __tostring and pos precalc
function ButtonGroupLine:set_highlights(ns_id, bufnr, line_0b, _offset)
  _offset = _offset or 0
  self._ns_id = ns_id
  self._bufnr = bufnr
  self._line_1b = line_0b + 1
  self._line:set_highlights(ns_id, bufnr, line_0b, self._start_col + _offset)
end

-- called by utils.update_buffer_lines after content is written
---@param _ns_id integer
---@param bufnr integer
---@param line_1b integer
function ButtonGroupLine:bind_events(_ns_id, bufnr, line_1b)
  self._bufnr = bufnr
  self._line_1b = line_1b
  ensure_dispatch(bufnr)
  local entry = registry[bufnr]
  entry.lines[line_1b] = self
end

---@param bufnr integer
---@param line_1b integer
function ButtonGroupLine:unbind_events(bufnr, line_1b)
  local entry = registry[bufnr]
  if not entry then return end
  entry.lines[line_1b] = nil
  cleanup_dispatch_if_empty(bufnr)
end

function ButtonGroupLine:_refresh_highlights()
  if not (self._ns_id and self._bufnr and self._line_1b) then return end
  --- refresh content
  Utils.unlock_buf(self._bufnr)
  vim.api.nvim_buf_set_lines(self._bufnr, self._line_1b - 1, self._line_1b, false, { tostring(self) })
  Utils.lock_buf(self._bufnr)
  self._line:set_highlights(self._ns_id, self._bufnr, self._line_1b - 1, self._start_col)
end

function ButtonGroupLine:_move_cursor_to_focus()
  local pos = self._button_pos[self._focus_index]
  if not pos then return end
  local winid = require("avante.utils").get_winid(self._bufnr)
  if winid and vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_set_cursor(winid, { self._line_1b, pos[1] }) end
end

---@param col integer 0-based column
function ButtonGroupLine:_update_focus_by_col(col)
  for i, rng in ipairs(self._button_pos) do
    if col >= rng[1] and col <= rng[2] then
      if self._focus_index ~= i then
        self._focus_index = i
        self:_refresh_highlights()
      end
      return
    end
  end
end

function ButtonGroupLine:_click_focused()
  local opt = self._button_options[self._focus_index]
  if not opt then return end
  if self.on_click then pcall(self.on_click, opt.id) end
end

return ButtonGroupLine
