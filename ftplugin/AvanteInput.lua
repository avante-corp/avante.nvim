-- create your own ftplugin/Avante.lua or after/ftplugin/Avante.lua to alter behavior
local api = vim.api
local Utils = require("avante.utils")
local Config = require("avante.config")

local sidebar = require("avante").get()

vim.wo.signcolumn = "yes"
vim.wo.foldcolumn = "0"
vim.wo.number = false
vim.wo.relativenumber = false

-- Setup completion
api.nvim_create_autocmd("InsertEnter", {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  once = true,
  desc = "Setup the completion of helpers in the input buffer",
  callback = function() end,
})

local debounced_show_input_hint = Utils.debounce(function()
  if vim.api.nvim_win_is_valid(sidebar.containers.input.winid) then sidebar:show_input_hint() end
end, 200)
api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  callback = function()
    debounced_show_input_hint()
    sidebar.place_sign_at_first_line(sidebar.containers.input.bufnr)
  end,
})

api.nvim_create_autocmd("QuitPre", {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  callback = function() sidebar:close_input_hint() end,
})

api.nvim_create_autocmd("WinClosed", {
  group = sidebar.augroup,
  pattern = tostring(sidebar.containers.input.winid),
  callback = function() sidebar:close_input_hint() end,
})

api.nvim_create_autocmd("BufEnter", {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  callback = function()
    if Config.windows.ask.start_insert then vim.cmd("noautocmd startinsert!") end
  end,
})

api.nvim_create_autocmd("BufLeave", {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  callback = function()
    vim.cmd("noautocmd stopinsert")
    sidebar:close_input_hint()
  end,
})

-- Update hint on mode change as submit key sequence may be different
api.nvim_create_autocmd("ModeChanged", {
  group = sidebar.augroup,
  buffer = sidebar.containers.input.bufnr,
  callback = function() sidebar:show_input_hint() end,
})

api.nvim_create_autocmd("WinEnter", {
  group = sidebar.augroup,
  callback = function()
    local cur_win = api.nvim_get_current_win()
    if sidebar.containers.input and cur_win == sidebar.containers.input.winid then
      sidebar:show_input_hint()
    else
      sidebar:close_input_hint()
    end
  end,
})
