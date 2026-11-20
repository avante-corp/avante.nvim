local stub = require("luassert.stub")

describe("AvanteSwitchProvider exact selection", function()
  local Config = require("avante.config")
  local api = require("avante.api")
  local selector = require("avante.ui.selector")
  local original_providers, original_acp_providers
  local switch_stub, selector_stub, selector_opts

  before_each(function()
    vim.cmd("runtime plugin/avante.lua")
    original_providers, original_acp_providers = Config.providers, Config.acp_providers
    Config.providers = { claude = {}, openai = {} }
    Config.acp_providers = { codex = { command = "codex-acp" } }
    selector_opts = nil
    switch_stub = stub(api, "switch_provider")
    selector_stub = stub(selector, "new").invokes(function(_, opts)
      selector_opts = opts
      return { open = function() end }
    end)
  end)

  after_each(function()
    switch_stub:revert()
    selector_stub:revert()
    Config.providers, Config.acp_providers = original_providers, original_acp_providers
  end)

  it("switches directly to an exact ACP provider", function()
    vim.cmd("AvanteSwitchProvider codex")
    assert.stub(switch_stub).was_called_with("codex", false)
    assert.stub(selector_stub).was_not_called()
  end)

  it("passes --save through an exact provider selection", function()
    vim.cmd("AvanteSwitchProvider --save openai")
    assert.stub(switch_stub).was_called_with("openai", true)
    assert.stub(selector_stub).was_not_called()
  end)

  it("opens the selector for a partial provider name", function()
    vim.cmd("AvanteSwitchProvider co")
    assert.equals("co", selector_opts.default_query)
    assert.stub(switch_stub).was_not_called()
  end)

  it("does not directly select an excluded ACP provider", function()
    vim.cmd("AvanteSwitchProvider --acp false codex")
    assert.equals("codex", selector_opts.default_query)
    assert.stub(switch_stub).was_not_called()
  end)
end)
