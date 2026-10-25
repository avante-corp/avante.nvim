describe("providers", function()
  local Config
  local previous_avante
  local previous_avante_module

  before_each(function()
    previous_avante = vim.g.avante
    previous_avante_module = package.loaded["avante"]
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil

    Config = require("avante.config")
    Config.get_last_used_model = function() end
    Config.setup({
      provider = "test_openai",
      providers = {
        test_openai = {
          __inherited_from = "openai",
          api_key_name = "",
          model = "gpt-test",
          setup = function() end,
        },
        test_claude = {
          __inherited_from = "claude",
          api_key_name = "",
          model = "claude-test",
        },
      },
      windows = {
        sidebar_header = {
          include_model = true,
        },
      },
    })
  end)

  after_each(function()
    vim.g.avante = previous_avante
    package.loaded["avante"] = previous_avante_module
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil
  end)

  it("redraws the sidebar header after switching providers", function()
    local rendered = 0
    package.loaded["avante"] = {
      get = function()
        return {
          is_open = function() return true end,
          render_result = function() rendered = rendered + 1 end,
        }
      end,
    }

    require("avante.providers").refresh("test_claude")

    assert.are.same("test_claude", Config.provider)
    assert.are.same(1, rendered)
  end)

  it("keeps internal provider identity out of parsed user configuration", function()
    local Providers = require("avante.providers")
    local provider = Providers.test_openai
    local parsed = Providers.parse_config(provider)

    assert.same("test_openai", provider._name)
    assert.same("openai", provider._protocol)
    assert.is_nil(parsed._name)
    assert.is_nil(parsed._protocol)
  end)

  it("derives the protocol from inherited providers", function()
    local provider = require("avante.providers").test_claude

    assert.same("claude", provider._protocol)
    assert.is_function(provider.parse_api_key)
  end)

  it("inherits and overrides OpenAI-compatible dialects", function()
    local Providers = require("avante.providers")

    assert.same("openai", Providers.test_openai.dialect)
    assert.same("deepseek", Providers.deepseek.dialect)
    assert.same("openrouter", Providers.openrouter.dialect)
    assert.same("moonshot", Providers.moonshot.dialect)
    assert.same("xai", Providers.xai.dialect)
    assert.same("zai", Providers.glm.dialect)
    assert.same("mistral", Providers.mistral.dialect)
  end)

  it("uses provider-specific routes without reusing DeepSeek response IDs", function()
    local Providers = require("avante.providers")

    assert.same("responses", Providers.resolve_api_route(Providers.deepseek, nil))
    assert.is_false(Providers.deepseek.support_previous_response_id)
    assert.same("chat", Providers.resolve_api_route(Providers.moonshot, nil))
  end)

  it("selects Responses for GPT-5 and GPT-6 model families", function()
    local Providers = require("avante.providers")
    for _, name in ipairs({ "openai", "copilot" }) do
      for _, model in ipairs({ "gpt-5", "gpt-6", "gpt-5-mini", "gpt-5.4", "gpt-6-sol", "gpt-5-codex" }) do
        local provider = vim.deepcopy(Providers[name])
        provider.model = model
        assert.same("responses", Providers.resolve_api_route(provider, nil), name .. ": " .. model)
      end
      for _, model in ipairs({ "custom-chat-model", "gpt-50", "gpt-60", "claude-sonnet-5-5", "other-gpt-5-codex" }) do
        local provider = vim.deepcopy(Providers[name])
        provider.model = model
        assert.same("chat", Providers.resolve_api_route(provider, nil), name .. ": " .. model)
      end
    end
  end)

  it("rejects legacy custom request builders with a migration error", function()
    Config.providers.legacy = {
      endpoint = "https://example.test/v1",
      model = "test-model",
      parse_curl_args = function() end,
    }

    local ok, err = pcall(function() return require("avante.providers").legacy end)
    assert.is_false(ok)
    assert.matches("__inherited_from", err, nil, true)
    assert.matches("parse_curl_args", err, nil, true)
  end)
end)
