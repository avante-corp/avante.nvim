---@mod avante-ui-selector    Abstraction over vim.ui.select
---@brief [[
---vim.ui.select-like with a few added features, for instance a default filter.
---Abstracts over the following UI selectors:
---- fzf-lua
---- snacks
---- telescope
---- mini.pick
---- native provider with fewer features
---@brief ]]
local Utils = require("avante.utils")

---@class avante.ui.SelectorItem
---@field id string
---@field title string

---@class avante.ui.SelectorOpts
---@field provider avante.SelectorProvider
---@field title string Prompt of the selector
---@field default_query string | nil Initial query entered in the selector
---@field items avante.ui.SelectorItem[]
---@field default_item_id string | nil only used in native selector, marks it with a specific character. Duplicate of selected_item_ids ?
---@field selected_item_ids string[] | nil
---@field provider_opts table | nil provider-specific (fzf-lua/snacks) options forwarded to the provider
---@field on_select fun(item_ids: string[] | nil)
---@field get_preview_content? fun(item_id: string): string?, string?
---@field on_delete_item? fun(item_id: string)
---@field on_open? fun()

---@class avante.ui.Selector: avante.ui.SelectorOpts
local Selector = {}
Selector.__index = Selector

---@param opts avante.ui.SelectorOpts
---@return avante.ui.Selector
function Selector:new(opts)
  local o = {}
  setmetatable(o, Selector)
  o.provider = opts.provider
  o.title = opts.title
  o.default_query = opts.default_query
  o.items = vim
    .iter(opts.items)
    :map(function(item)
      local new_item = vim.deepcopy(item)
      new_item.title = new_item.title:gsub("\n", " ")
      return new_item
    end)
    :totable()
  o.default_item_id = opts.default_item_id
  o.provider_opts = opts.provider_opts or {}
  o.on_select = opts.on_select
  o.selected_item_ids = opts.selected_item_ids or {}
  o.get_preview_content = opts.get_preview_content
  o.on_delete_item = opts.on_delete_item
  o.on_open = opts.on_open
  return o
end

function Selector:open()
  if type(self.provider) == "function" then
    self.provider(self)
    return
  end

  local ok, provider = pcall(require, "avante.ui.selector.providers." .. self.provider)
  if not ok then Utils.error("Unknown file selector provider: " .. self.provider) end
  provider.show(self)
end

return Selector
