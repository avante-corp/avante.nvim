describe("config", function()
  local Config
  local previous_avante

  before_each(function()
    previous_avante = vim.g.avante
    package.loaded["avante.config"] = nil
    Config = require("avante.config")
    Config.get_last_used_model = function() end
  end)

  after_each(function()
    vim.g.avante = previous_avante
    package.loaded["avante.config"] = nil
  end)

  it("loads setup options from vim.g.avante", function()
    vim.g.avante = {
      provider = "openai",
      behaviour = {
        auto_suggestions = true,
      },
    }

    Config.setup({})

    assert.are.same("openai", Config.provider)
    assert.is_true(Config.behaviour.auto_suggestions)
  end)

  it("disables previous response IDs by default", function()
    Config.setup({})

    assert.is_false(Config.providers.openai.support_previous_response_id)
  end)

  it("does not expose provider request timeouts", function()
    Config.setup({})

    for name, provider in pairs(Config.providers) do
      assert.is_nil(provider.timeout, name .. " still defines a provider timeout")
    end
  end)

  it("lets explicit setup options override vim.g.avante", function()
    vim.g.avante = {
      provider = "openai",
      behaviour = {
        auto_suggestions = true,
      },
    }

    Config.setup({
      provider = "claude",
      behaviour = {
        auto_suggestions = false,
      },
    })

    assert.are.same("claude", Config.provider)
    assert.is_false(Config.behaviour.auto_suggestions)
  end)

  it("uses the last provider and model when no provider is configured", function()
    Config.get_last_used_model = function() return "gpt-test", "openai" end

    Config.setup({
      windows = {
        sidebar_header = {
          include_model = true,
        },
      },
    })

    assert.are.same("openai", Config.provider)
    assert.are.same("gpt-test", Config.providers.openai.model)
  end)

  it("does not let the last provider override an explicit setup provider", function()
    Config.get_last_used_model = function() return "gpt-test", "openai" end

    Config.setup({ provider = "claude" })

    assert.are.same("claude", Config.provider)
    assert.are_not.same("gpt-test", Config.providers.claude.model)
  end)

  it("does not let the last provider override vim.g.avante.provider", function()
    vim.g.avante = {
      provider = "claude",
    }
    Config.get_last_used_model = function() return "gpt-test", "openai" end

    Config.setup({})

    assert.are.same("claude", Config.provider)
    assert.are_not.same("gpt-test", Config.providers.claude.model)
  end)
end)
