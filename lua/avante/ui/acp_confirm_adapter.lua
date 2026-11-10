local Highlights = require("avante.highlights")

---@class avante.ui.ConfirmAdapter
local M = {}

---@class avante.ui.ACPConfirmAdapter.ACPMappedOptions
---@field yes? string
---@field all? string
---@field no? string

---Converts the ACP permission options to confirmation popup-compatible format (yes/all/no)
---@param options avante.acp.PermissionOption[]
---@return avante.ui.ACPConfirmAdapter.ACPMappedOptions
function M.map_acp_options(options)
  local option_map = { yes = nil, all = nil, no = nil }

  for _, opt in ipairs(options) do
    if opt.kind == "allow_once" then
      option_map.yes = opt.optionId
    elseif opt.kind == "allow_always" then
      option_map.all = opt.optionId
    elseif opt.kind == "reject_once" then
      option_map.no = opt.optionId

      -- elseif opt.kind == "reject_always" then
      -- ignore, no 4th option in the confirm popup yet
    end
  end

  return option_map
end

---@class avante.ui.ACPConfirmAdapter.ButtonOption
---@field id string
---@field icon string
---@field name string
---@field hl? string

---@param options avante.acp.PermissionOption[]
---@return avante.ui.ACPConfirmAdapter.ButtonOption[]
function M.generate_buttons_for_acp_options(options)
  ---@type avante.ui.ACPConfirmAdapter.ButtonOption[]
  local items = vim
    .iter(options)
    :map(function(item)
      ---@cast item avante.acp.PermissionOption
      local icon = item.kind == "allow_once" and "" or ""
      if item.kind == "allow_always" then icon = "" end
      local hl = nil
      if item.kind == "reject_once" or item.kind == "reject_always" then hl = Highlights.BUTTON_DANGER_HOVER end
      ---@type avante.ui.ACPConfirmAdapter.ButtonOption
      local button = {
        id = item.optionId,
        name = item.name,
        icon = icon,
        hl = hl,
      }
      return button
    end)
    :totable()
  -- Sort to have "allow" first, then "allow always", then "reject"
  table.sort(items, function(a, b) return a.name < b.name end)
  return items
end

return M
