local stub = require("luassert.stub")
local Config = require("avante.config")
local Helpers = require("avante.llm_tools.helpers")
local Confirm = require("avante.ui.confirm")
local Llm = require("avante.llm")

describe("tool confirmation callbacks", function()
  local behaviour, saved_popups, open_stub, close_stub, owner, saved_cancelled

  before_each(function()
    behaviour, saved_popups = Config.behaviour, Helpers.confirm_popups
    saved_cancelled = Helpers.is_cancelled
    Config.behaviour = { confirmation_ui_style = "popup", auto_approve_tool_permissions = false }
    Helpers.confirm_popups = {}
    owner = { containers = { input = { winid = vim.api.nvim_get_current_win() } }, update_content = function() end }
    open_stub = stub(Confirm, "open")
    close_stub = stub(Confirm, "close")
  end)

  after_each(function()
    open_stub:revert()
    close_stub:revert()
    Config.behaviour, Helpers.confirm_popups = behaviour, saved_popups
    Helpers.is_cancelled = saved_cancelled
  end)

  for _, choice in ipairs({ "yes", "all", "no" }) do
    it("returns the ACP popup " .. choice .. " option ID without granting unrelated future tools", function()
      local ctx, result = {}, nil
      local ids = { yes = "custom-once", all = "custom-rule", no = "custom-reject" }
      local popup = Helpers.confirm(
        "ACP",
        function(ok, reason, id) result = { ok = ok, reason = reason, id = id } end,
        {
          sidebar = owner,
          permission_options = {
            { optionId = ids.yes, kind = "allow_once" },
            { optionId = ids.all, kind = "allow_always" },
            { optionId = ids.no, kind = "reject_once" },
          },
        },
        ctx
      )

      popup.callback(choice)

      assert.is_true(vim.wait(500, function() return result ~= nil end, 5))
      assert.same({ ok = choice ~= "no", id = ids[choice] }, result)
      assert.is_nil(ctx.always_yes)
    end)
  end

  it("keeps generic popup All Yes and rejection reasons", function()
    local ctx, results = {}, {}
    local first = Helpers.confirm(
      "generic",
      function(ok, reason) table.insert(results, { ok, reason }) end,
      { sidebar = owner },
      ctx
    )
    first.callback("all")
    local second = Helpers.confirm(
      "generic",
      function(ok, reason) table.insert(results, { ok, reason }) end,
      { sidebar = owner },
      {}
    )
    second.callback("no", "not this time")

    assert.is_true(vim.wait(500, function() return #results == 2 end, 5))
    assert.is_true(ctx.always_yes)
    assert.same({ { true }, { false, "not this time" } }, results)
  end)

  for _, choice in ipairs({ "allow_once", "allow_always", "reject_once" }) do
    it("preserves the default inline option " .. choice .. " for non-ACP tools", function()
      Config.behaviour.confirmation_ui_style = "inline_buttons"
      local ctx, result = {}, nil
      Helpers.confirm(
        "generic",
        function(ok, reason) result = { ok = ok, reason = reason } end,
        { sidebar = owner },
        ctx
      )

      owner.permission_handler(choice)

      assert.is_true(vim.wait(500, function() return result ~= nil end, 5))
      assert.same({ ok = choice ~= "reject_once", reason = choice == "reject_once" and choice or nil }, result)
      assert.equals(choice == "allow_always", ctx.always_yes == true)
    end)
  end

  it("finishes a replaced popup from the same owner without answering the replacement", function()
    local first_result, second_result
    Helpers.confirm("first", function(ok, reason) first_result = { ok, reason } end, { sidebar = owner }, {})
    local second = Helpers.confirm(
      "second",
      function(ok, reason) second_result = { ok, reason } end,
      { sidebar = owner },
      {}
    )

    assert.is_true(vim.wait(500, function() return first_result ~= nil end, 5))
    assert.same({ false, "cancel" }, first_result)
    assert.is_nil(second_result)
    second.callback("yes")
    assert.is_true(vim.wait(500, function() return second_result ~= nil end, 5))
    assert.same({ true }, second_result)
  end)

  it("cancels pending popups for every owner through the global cancellation action", function()
    local results = {}
    for index = 1, 2 do
      local other = { containers = { input = { winid = vim.api.nvim_get_current_win() } } }
      Helpers.confirm(
        "request " .. index,
        function(ok, reason) results[index] = { ok, reason } end,
        { sidebar = other },
        {}
      )
    end

    Llm.cancel_inflight_request()

    assert.is_true(vim.wait(500, function() return results[1] ~= nil and results[2] ~= nil end, 5))
    assert.same({ { false, "cancel" }, { false, "cancel" } }, results)
  end)

  it("releases only the stopped sidebar's pending popup", function()
    local result
    owner.acp_client_generation = 0
    Helpers.confirm("stopped chat", function(ok, reason) result = { ok, reason } end, { sidebar = owner }, {})
    local other = { containers = { input = { winid = vim.api.nvim_get_current_win() } } }
    local other_popup = Helpers.confirm("other chat", function() end, { sidebar = other }, {})

    require("avante.sidebar").stop_acp_client(owner)

    assert.is_true(vim.wait(500, function() return result ~= nil end, 5))
    assert.same({ false, "cancel" }, result)
    assert.is_nil(Helpers.confirm_popups[owner])
    assert.equals(other_popup, Helpers.confirm_popups[other])
  end)
end)
