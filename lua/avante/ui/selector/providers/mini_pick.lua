local Utils = require("avante.utils")
local M = {}

---@param selector avante.ui.Selector
function M.show(selector)
  -- luacheck: globals MiniPick
  ---@diagnostic disable-next-line: undefined-field
  if not _G.MiniPick then
    Utils.error("mini.pick is not set up. Please install and set up mini.pick to use it as a file selector.")
    return
  end
  local items = {}
  local query = selector.default_query and selector.default_query:lower()
  for _, item in ipairs(selector.items) do
    if
      not vim.list_contains(selector.selected_item_ids, item.id)
      and (not query or item.title:lower():find(query, 1, true))
    then
      table.insert(items, item)
    end
  end
  ---@param item avante.ui.SelectorItem?
  local function choose(item)
    if not item then
      selector.on_select(nil)
      return
    end
    selector.on_select({ item.id })
  end
  ---@type {ui_select: fun(items: avante.ui.SelectorItem[], opts: table, callback: fun(item: avante.ui.SelectorItem?))}
  local mini_pick = _G.MiniPick
  mini_pick.ui_select(items, {
    prompt = selector.title,
    format_item = function(item) return item.title end,
  }, choose)
end

return M
