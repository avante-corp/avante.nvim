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
  local title_to_id = {}
  local query = selector.default_query and selector.default_query:lower()
  for _, item in ipairs(selector.items) do
    title_to_id[item.title] = item.id
    if
      not vim.list_contains(selector.selected_item_ids, item.id)
      and (not query or item.title:lower():find(query, 1, true))
    then
      table.insert(items, item)
    end
  end
  local function choose(item)
    if not item then
      selector.on_select(nil)
      return
    end
    local item_ids = {}
    ---item is not a list
    for _, item_ in pairs(item) do
      table.insert(item_ids, title_to_id[item_])
    end
    selector.on_select(item_ids)
  end
  ---@diagnostic disable-next-line: undefined-global
  MiniPick.ui_select(items, {
    prompt = selector.title,
    format_item = function(item) return item.title end,
  }, choose)
end

return M
