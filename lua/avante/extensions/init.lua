---@mod avante-integrations avante integrations
---@brief [[
---
--- NvimTree~
---
--- Avante can integrate with nvim-tree through its extension module:
--->
---   {
---     "avante-corp/avante.nvim",
---     keys = {
---       {
---         "<leader>a+",
---         function()
---           require("avante.extensions.nvim_tree").add_file()
---         end,
---         desc = "Select file in NvimTree",
---         ft = "NvimTree",
---       },
---       {
---         "<leader>a-",
---         function()
---           require("avante.extensions.nvim_tree").remove_file()
---         end,
---         desc = "Deselect file in NvimTree",
---         ft = "NvimTree",
---       },
---     },
---     opts = {
---       selector = {
---         exclude_auto_select = { "NvimTree" },
---       },
---     },
---   }
---<
---
--- Neo-tree~
---
--- The README includes an example `neo-tree.nvim` command that adds files or
--- folders to Avante Selected Files from the Neo-tree sidebar.
---
--- MCP~
---
--- Avante can integrate MCP functionality through `mcphub.nvim`.
---
---@brief ]]

---@class avante.extensions
local M = {}

setmetatable(M, {
  __index = function(t, k)
    ---@diagnostic disable-next-line: no-unknown
    t[k] = require("avante.extensions." .. k)
    return t[k]
  end,
})
