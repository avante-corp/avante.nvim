local api = vim.api
local fn = vim.fn
local Config = require("avante.config")
local Utils = require("avante.utils")

---@class avante.ui.PromptInput
---@field bufnr integer | nil
---@field winid integer | nil
---@field win_opts table
---@field shortcuts_hints_winid integer | nil
---@field augroup integer | nil
---@field start_insert boolean
---@field submit_callback function | nil
---@field cancel_callback function | nil
---@field close_on_submit boolean
---@field spinner_chars string[]
---@field spinner_index integer
---@field spinner_timer uv.uv_timer_t | nil
---@field spinner_active boolean
---@field default_value string | nil
---@field popup_hint_id integer | nil
local PromptInput = {}
PromptInput.__index = PromptInput

---@class avante.ui.PromptInputOptions
---@field start_insert? boolean
---@field submit_callback? fun(input: string):nil
---@field cancel_callback? fun():nil
---@field close_on_submit? boolean
---@field win_opts? table
---@field default_value? string

---@param opts? avante.ui.PromptInputOptions
---@return avante.ui.PromptInput
function PromptInput:new(opts)
  opts = opts or {}
  local obj = setmetatable({}, PromptInput)
  obj.bufnr = nil
  obj.winid = nil
  obj.shortcuts_hints_winid = nil
  obj.augroup = api.nvim_create_augroup("PromptInput", { clear = true })
  obj.start_insert = opts.start_insert or false
  obj.submit_callback = opts.submit_callback
  obj.cancel_callback = opts.cancel_callback
  obj.close_on_submit = opts.close_on_submit or false
  obj.win_opts = opts.win_opts
  obj.default_value = opts.default_value
  obj.spinner_chars = Config.windows.spinner.editing
  obj.spinner_index = 1
  obj.spinner_timer = nil
  obj.spinner_active = false
  obj.popup_hint_id = vim.api.nvim_create_namespace("avante_prompt_input_hint")
  return obj
end

function PromptInput:open()
  self:close()

  local bufnr = api.nvim_create_buf(false, true)
  self.bufnr = bufnr
  Utils.mark_as_sidebar_buffer(bufnr)

  local win_opts = vim.tbl_extend("force", {
    relative = "cursor",
    width = 40,
    height = 2,
    row = 1,
    col = 0,
    style = "minimal",
    border = Config.windows.edit.border,
    title = { { "Input", "FloatTitle" } },
    title_pos = "center",
  }, self.win_opts)

  local winid = api.nvim_open_win(bufnr, true, win_opts)
  self.winid = winid

  vim.bo[bufnr].filetype = "AvantePromptInput"

  local default_value_lines = {}
  if self.default_value then default_value_lines = vim.split(self.default_value, "\n") end
  if #default_value_lines > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, default_value_lines)
    api.nvim_win_set_cursor(winid, { #default_value_lines, #default_value_lines[#default_value_lines] })
  end

  self:show_shortcuts_hints()

  self:setup_keymaps()
  self:setup_autocmds()

  if self.start_insert then vim.cmd("noautocmd startinsert!") end
end

function PromptInput:close()
  if not self.bufnr then return end
  self:stop_spinner()
  self:close_shortcuts_hints()
  if api.nvim_get_mode().mode == "i" then vim.cmd("noautocmd stopinsert") end
  if self.winid and api.nvim_win_is_valid(self.winid) then
    api.nvim_win_close(self.winid, true)
    self.winid = nil
  end
  if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
    api.nvim_buf_delete(self.bufnr, { force = true })
    self.bufnr = nil
  end
  if self.augroup then
    api.nvim_del_augroup_by_id(self.augroup)
    self.augroup = nil
  end
end

function PromptInput:cancel()
  self:close()
  if self.cancel_callback then self.cancel_callback() end
end

function PromptInput:submit(input)
  if self.close_on_submit then self:close() end
  if self.submit_callback then self.submit_callback(input) end
end

function PromptInput:show_shortcuts_hints()
  self:close_shortcuts_hints()

  if not self.winid or not api.nvim_win_is_valid(self.winid) then return end

  local win_width = api.nvim_win_get_width(self.winid)
  local win_height = api.nvim_win_get_height(self.winid)

  ---@type string
  local hint_text = (vim.fn.mode() ~= "i" and Config.mappings.submit.normal or Config.mappings.submit.insert)
    .. ": submit"

  local display_text = hint_text

  if self.spinner_active then
    local spinner = self.spinner_chars[self.spinner_index]
    display_text = spinner .. " " .. hint_text
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { display_text })
  api.nvim_buf_set_extmark(buf, self.popup_hint_id, 0, 0, {
    end_row = 0,
    end_col = #display_text,
    hl_group = "AvantePopupHint",
    priority = 100,
  })

  local width = fn.strdisplaywidth(display_text)

  local opts = {
    relative = "win",
    win = self.winid,
    width = width,
    height = 1,
    row = win_height,
    col = math.max(win_width - width, 0),
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 100,
  }

  self.shortcuts_hints_winid = api.nvim_open_win(buf, false, opts)
  api.nvim_set_option_value("winblend", 10, { win = self.shortcuts_hints_winid })
end

function PromptInput:close_shortcuts_hints()
  if self.shortcuts_hints_winid and api.nvim_win_is_valid(self.shortcuts_hints_winid) then
    local buf = api.nvim_win_get_buf(self.shortcuts_hints_winid)
    if self.popup_hint_id then api.nvim_buf_clear_namespace(buf, self.popup_hint_id, 0, -1) end
    api.nvim_win_close(self.shortcuts_hints_winid, true)
    api.nvim_buf_delete(buf, { force = true })
    self.shortcuts_hints_winid = nil
  end
end

function PromptInput:start_spinner()
  self.spinner_active = true
  self.spinner_index = 1

  if self.spinner_timer then
    self.spinner_timer:stop()
    self.spinner_timer:close()
    self.spinner_timer = nil
  end

  self.spinner_timer = vim.uv.new_timer()
  local spinner_timer = self.spinner_timer

  if self.spinner_timer then
    self.spinner_timer:start(0, 100, function()
      vim.schedule(function()
        if not self.spinner_active or spinner_timer ~= self.spinner_timer then return end
        self.spinner_index = (self.spinner_index % #self.spinner_chars) + 1
        self:show_shortcuts_hints()
      end)
    end)
  end
end

function PromptInput:stop_spinner()
  self.spinner_active = false
  if self.spinner_timer then
    self.spinner_timer:stop()
    self.spinner_timer:close()
    self.spinner_timer = nil
  end
  self:show_shortcuts_hints()
end

function PromptInput:setup_keymaps()
  local bufnr = self.bufnr

  local function get_input()
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then return "" end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return lines[1] or ""
  end

  vim.keymap.set(
    "i",
    Config.mappings.submit.insert,
    function() self:submit(get_input()) end,
    { buffer = bufnr, noremap = true, silent = true }
  )

  vim.keymap.set(
    "n",
    Config.mappings.submit.normal,
    function() self:submit(get_input()) end,
    { buffer = bufnr, noremap = true, silent = true }
  )

  ---@type string[]
  local normal_cancel = Config.mappings.cancel.normal
  for _, key in ipairs(normal_cancel) do
    vim.keymap.set("n", key, function() self:cancel() end, { buffer = bufnr })
  end
  ---@type string[]
  local insert_cancel = Config.mappings.cancel.insert
  for _, key in ipairs(insert_cancel) do
    vim.keymap.set("i", key, function() self:cancel() end, { buffer = bufnr })
  end
end

function PromptInput:setup_autocmds()
  local bufnr = self.bufnr
  local group = self.augroup

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function() self:show_shortcuts_hints() end,
  })

  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = { "i:*", "*:i" },
    callback = function()
      local cur_buf = api.nvim_get_current_buf()
      if cur_buf == bufnr then self:show_shortcuts_hints() end
    end,
  })

  api.nvim_create_autocmd("QuitPre", {
    group = group,
    buffer = bufnr,
    once = true,
    nested = true,
    callback = function() self:cancel() end,
  })

  api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = bufnr,
    callback = function() self:cancel() end,
  })
end

return PromptInput
