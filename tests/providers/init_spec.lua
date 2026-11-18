describe("providers", function()
  local Config
  local previous_avante
  local previous_avante_module
  local previous_api

  before_each(function()
    previous_avante = vim.g.avante
    previous_avante_module = package.loaded["avante"]
    previous_api = package.loaded["avante.api"]
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil
    package.loaded["avante.api"] = nil

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
    package.loaded["avante.api"] = previous_api
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil
  end)

  it("checks the selected provider and resets the sidebar chat after switching providers", function()
    local reset = 0
    package.loaded["avante"] = {
      get = function()
        return {
          is_open = function() return true end,
          reset_chat_history = function() reset = reset + 1 end,
        }
      end,
    }

    local checked = {}
    local check_stub = stub(require("avante.libs.rig_client"), "check_provider").invokes(
      function(provider) checked[#checked + 1] = { Config.provider, provider._name } end
    )
    local ok, err = pcall(function() require("avante.providers").refresh("test_claude") end)
    check_stub:revert()

    assert.is_true(ok, err)
    assert.same({ { "test_claude", "test_claude" } }, checked)
    assert.are.same("test_claude", Config.provider)
    assert.are.same(1, reset)
  end)

  it("does not create an ACP session when switching providers", function()
    local reset, submitted = 0, 0
    Config.override({ acp_providers = { test_acp = { command = "test-agent" } } })
    package.loaded["avante"] = {
      get = function()
        return {
          is_open = function() return true end,
          reset_chat_history = function() reset = reset + 1 end,
          handle_submit = function() submitted = submitted + 1 end,
        }
      end,
    }

    require("avante.providers").refresh("test_acp")

    assert.are.same("test_acp", Config.provider)
    assert.are.same(1, reset)
    assert.are.same(0, submitted)
  end)

  it("honors explicit suggestion providers and evaluates selectors per suggestion", function()
    local initialized, resolved = 0, 0
    Config.override({
      provider = "test_acp",
      acp_providers = { test_acp = { command = "test-agent" } },
      auto_suggestions_acp_provider = "test_claude",
      auto_suggestions_provider = "test_openai",
      providers = { test_openai = { setup = function() initialized = initialized + 1 end } },
    })
    local Providers = require("avante.providers")
    Providers.setup()
    assert.equals("test_openai", Providers.get_auto_suggestions_provider()._name)
    assert.equals(1, initialized)

    Config.override({
      auto_suggestions_provider = function(current_provider_name)
        assert.equals("test_acp", current_provider_name)
        resolved = resolved + 1
        return "test_openai"
      end,
    })
    Providers.setup()
    assert.equals(0, resolved)
    for _ = 1, 2 do
      assert.equals("test_openai", Providers.get_auto_suggestions_provider()._name)
    end
    assert.equals(2, resolved)
    assert.equals(1, initialized)
  end)

  it("follows provider switches and initializes the ACP suggestion API provider only once", function()
    local initialized = 0
    Config.override({
      provider = "test_acp",
      acp_providers = { test_acp = { command = "test-agent" } },
      auto_suggestions_acp_provider = "test_claude",
      providers = { test_claude = { setup = function() initialized = initialized + 1 end } },
    })
    package.loaded["avante"] = { get = function() end }
    local Providers = require("avante.providers")
    Providers.setup()
    assert.equals(0, initialized)

    local selected_providers = {}
    for _, name in ipairs({ "test_acp", "test_openai", "test_acp" }) do
      Providers.refresh(name)
      selected_providers[#selected_providers + 1] = Providers.get_auto_suggestions_provider()._name
    end
    assert.same({ "test_claude", "test_openai", "test_claude" }, selected_providers)
    assert.equals(1, initialized)
  end)

  it("keeps internal provider identity out of parsed user configuration", function()
    local Providers = require("avante.providers")
    local provider = Providers.test_openai
    local config = Config.get_provider_config("test_openai")
    local parsed = Providers.parse_config(provider)

    assert.same("openai", config.__inherited_from)
    assert.is_nil(config._name)
    assert.is_nil(config._protocol)
    assert.is_nil(config._dialect)
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

  it("sets up Claude subscriptions without prompting for an API key", function()
    Config.override({
      provider = "test_claude",
      providers = {
        test_claude = {
          api_key_name = "ANTHROPIC_API_KEY",
          auth_type = "subscription",
          parse_api_key = function() error("subscription must not read API keys") end,
        },
      },
    })
    local Providers = require("avante.providers")
    Providers.setup()
    assert.is_false(Providers.env.require_api_key(Providers.test_claude))
    assert.is_true(Providers.test_claude.is_env_set())
    assert.is_true(vim.g.avante_login)
  end)

  it("sets up ChatGPT subscriptions without prompting for an API key", function()
    Config.override({
      providers = {
        test_openai = {
          api_key_name = "OPENAI_API_KEY",
          auth_type = "subscription",
          parse_api_key = function() error("subscription must not read API keys") end,
        },
      },
    })
    local Providers = require("avante.providers")
    Providers.setup()
    assert.is_false(Providers.env.require_api_key(Providers.test_openai))
    assert.is_true(Providers.test_openai.is_env_set())
  end)

  it("sets up Copilot without external plugins or API keys", function()
    Config.override({
      provider = "copilot",
      providers = {
        copilot = {
          api_key_name = "IGNORED_API_KEY",
          parse_api_key = function() error("Copilot authentication belongs in Rust") end,
        },
      },
    })
    local Providers = require("avante.providers")
    Providers.setup()
    assert.is_false(Providers.env.require_api_key(Providers.copilot))
    assert.is_true(Providers.copilot.is_env_set())
  end)

  it("does not inherit ChatGPT subscription authentication into API providers", function()
    Config.override({ providers = { openai = { auth_type = "subscription" } } })
    local Providers = require("avante.providers")
    assert.same("api_key", Providers.deepseek.auth_type)
    assert.is_true(Providers.env.require_api_key(Providers.deepseek))
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
