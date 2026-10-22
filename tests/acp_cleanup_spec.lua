local stub = require("luassert.stub")
local Avante = require("avante")

describe("ACP lifecycle cleanup", function()
  local saved_clients, saved_sidebars, saved_selections

  before_each(function()
    saved_clients, saved_sidebars, saved_selections = Avante.acp_clients, Avante.sidebars, Avante.selections
    Avante.acp_clients, Avante.sidebars, Avante.selections = {}, {}, {}
  end)

  after_each(function()
    Avante.acp_clients, Avante.sidebars, Avante.selections = saved_clients, saved_sidebars, saved_selections
  end)

  it("waits through the configured close deadline before force stopping", function()
    local waited
    local wait_stub = stub(vim, "wait").invokes(function(timeout)
      waited = timeout
      return false
    end)
    local client = {
      config = { session_close_timeout = 900 },
      stop = function() end,
      force_stop = stub(),
    }
    Avante.acp_clients.one = client

    Avante.cleanup_all_acp_clients()

    wait_stub:revert()
    assert.equals(1000, waited)
    assert.stub(client.force_stop).was_called(1)
    assert.same({}, Avante.acp_clients)
  end)

  it("stops the tab's ACP client before resetting the sidebar", function()
    local calls = {}
    Avante.sidebars[7] = {
      stop_acp_client = function() table.insert(calls, "stop") end,
      reset = function() table.insert(calls, "reset") end,
    }
    Avante.selections[7] = { delete_autocmds = function() table.insert(calls, "selection") end }

    Avante._cleanup_tab(7)

    assert.same({ "stop", "reset", "selection" }, calls)
    assert.is_nil(Avante.sidebars[7])
  end)
end)
