local provider = require("avante.ui.selector.providers.mini_pick")

describe("mini.pick selector", function()
  local previous
  before_each(function() previous = rawget(_G, "MiniPick") end)
  after_each(function() rawset(_G, "MiniPick", previous) end)

  it("returns the selected item's ID once when its title differs", function()
    local selected
    rawset(_G, "MiniPick", {
      ui_select = function(items, _, choose) choose(items[1]) end,
    })
    provider.show({
      items = { { id = "file-id", title = "File title" } },
      selected_item_ids = {},
      title = "Choose file",
      on_select = function(ids) selected = ids end,
    })
    assert.same({ "file-id" }, selected)
  end)
end)
