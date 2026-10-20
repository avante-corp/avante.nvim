local stub = require("luassert.stub")
local Path = require("avante.path")

describe("api.select_history ACP lifecycle", function()
  local previous_avante, previous_selector, previous_api
  local save_latest_stub

  before_each(function()
    previous_avante = package.loaded["avante"]
    previous_selector = package.loaded["avante.history_selector"]
    previous_api = package.loaded["avante.api"]
    package.loaded["avante.api"] = nil
    save_latest_stub = stub(Path.history, "save_latest_filename")
  end)

  after_each(function()
    save_latest_stub:revert()
    package.loaded["avante"] = previous_avante
    package.loaded["avante.history_selector"] = previous_selector
    package.loaded["avante.api"] = previous_api
  end)

  it("stops the old ACP client before reconnecting an open sidebar to the selected history", function()
    local calls = {}
    local sidebar = {
      stop_acp_client = function() table.insert(calls, "stop") end,
      switch_to_history_and_reconnect = function() table.insert(calls, "switch") end,
      focus_input = function() end,
    }
    package.loaded["avante"] = {
      is_sidebar_open = function() return true end,
      get = function() return sidebar end,
    }
    package.loaded["avante.history_selector"] = {
      open = function(_, callback) callback("selected.json") end,
    }

    require("avante.api").select_history()

    assert.same({ "stop", "switch" }, calls)
    assert.stub(save_latest_stub).was_called_with(vim.api.nvim_get_current_buf(), "selected.json")
  end)
end)
