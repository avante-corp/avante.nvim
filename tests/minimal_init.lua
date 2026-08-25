-- Runtime for the test suite.
--
-- plenary's test_harness spawns a child Neovim per spec file with only
-- `rtp+=.,<plenary>`. That is enough to find `avante.*` (cwd is the repo root)
-- but not its dependencies, so specs that require lua/avante/sidebar.lua would
-- silently `pending()` instead of running. Anything the plugin needs at
-- require-time belongs here.

local repo = vim.fn.getcwd()
local deps = repo .. "/target/tests/deps"

for _, path in ipairs({
  repo,
  deps .. "/plenary.nvim",
  deps .. "/nui.nvim",
}) do
  if vim.fn.isdirectory(path) == 1 then vim.opt.runtimepath:append(path) end
end

vim.opt.swapfile = false
