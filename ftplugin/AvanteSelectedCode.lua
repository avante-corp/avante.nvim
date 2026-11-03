local Highlights = require("avante.highlights")

vim.opt_local.winfixbuf = true
vim.opt_local.spell = false
vim.opt_local.signcolumn = "no"
vim.opt_local.foldcolumn = "0"
vim.opt_local.number = false
vim.opt_local.relativenumber = false
vim.opt_local.winfixwidth = true
vim.opt_local.list = false
vim.opt_local.linebreak = true
vim.opt_local.breakindent = true
vim.opt_local.wrap = false
vim.opt_local.fillchars = "eob: "
vim.opt_local.winhighlight = "CursorLine:Normal,CursorColumn:Normal,WinSeparator:"
  .. Highlights.AVANTE_SIDEBAR_WIN_SEPARATOR
  .. ",Normal:"
  .. Highlights.AVANTE_SIDEBAR_NORMAL
vim.opt_local.winbar = ""
vim.opt_local.statusline = vim.o.laststatus == 0 and " " or ""
