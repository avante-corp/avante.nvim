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

  it("resets the sidebar chat after switching providers", function()
    local reset = 0
    package.loaded["avante"] = {
      get = function()
        return {
          is_open = function() return true end,
          reset_chat_history = function() reset = reset + 1 end,
        }
      end,
    }

    require("avante.providers").refresh("test_claude")

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

  it("keeps internal provider identity out of parsed user configuration", function()
    local Providers = require("avante.providers")
    local provider = Providers.test_openai
    local parsed = Providers.parse_config(provider)

    assert.same("test_openai", provider._name)
    assert.same("openai", provider._protocol)
    assert.same("openai", provider._dialect)
    assert.is_nil(parsed._name)
    assert.is_nil(parsed._protocol)
    assert.is_nil(parsed._dialect)
  end)

  it("derives the protocol from inherited providers", function()
    local provider = require("avante.providers").test_claude

    assert.same("claude", provider._protocol)
    assert.is_function(provider.parse_api_key)
  end)

  for _, case in ipairs({
    { name = "test_claude", auth_type = "subscription" },
    { name = "test_openai", auth_type = "subscription" },
    { name = "copilot" },
  }) do
    it("sets up " .. case.name .. " without reading an API key", function()
      Config.override({
        provider = case.name,
        providers = {
          [case.name] = {
            api_key_name = "UNUSED_API_KEY",
            auth_type = case.auth_type,
            parse_api_key = function() error("subscription must not read API keys") end,
          },
        },
      })
      local Providers = require("avante.providers")
      Providers.setup()
      local provider = Providers[case.name]
      assert.same("subscription", provider.auth_type)
      assert.is_false(Providers.env.require_api_key(provider))
      assert.is_true(provider.is_env_set())
      assert.is_true(vim.g.avante_login)
    end)
  end

  it("uses the base configuration's selected implementation", function()
    Config.override({
      providers = {
        qwen = { __inherited_from = "claude" },
        deepseek = { __inherited_from = "qwen", model = "claude-test" },
        private_provider = { __inherited_from = "deepseek" },
      },
    })
    local provider = require("avante.providers").private_provider
    assert.same("claude", provider._protocol)
    assert.is_nil(provider._dialect)
    assert.is_function(provider.get_rate_limit_sleep_time)
  end)

  it("keeps built-in dialects and provider defaults while inheriting OpenAI", function()
    local Providers = require("avante.providers")
    for _, name in ipairs({ "deepseek", "openrouter", "moonshot", "xai", "zai", "mistral" }) do
      local provider = Providers[name]
      assert.same("openai", Config.providers[name].__inherited_from, name)
      assert.same(name, provider._dialect, name)
      assert.same(16384, provider.extra_request_body.max_completion_tokens, name)
      assert.same(name == "moonshot" and "high" or "medium", provider.extra_request_body.reasoning_effort, name)
      assert.same((name == "deepseek" or name == "moonshot") and 1048576 or 128000, provider.context_window, name)
      assert.same(name == "xai" or name == "zai", provider.support_previous_response_id, name)
    end
    assert.same(4096, Providers.mistral.extra_request_body.max_tokens)
  end)

  it("propagates OpenAI configuration through dialect providers with child overrides", function()
    Config.override({
      providers = {
        openai = {
          context_window = 1,
          use_response_api = false,
          support_previous_response_id = false,
          extra_request_body = { max_completion_tokens = 1, reasoning_effort = "low" },
        },
      },
    })
    local Providers = require("avante.providers")
    for _, name in ipairs({ "deepseek", "openrouter", "moonshot", "xai", "zai", "mistral" }) do
      local provider = Providers[name]
      assert.same(1, provider.extra_request_body.max_completion_tokens, name)
      assert.same(name == "moonshot" and "high" or "low", provider.extra_request_body.reasoning_effort, name)
      assert.same((name == "deepseek" or name == "moonshot") and 1048576 or 1, provider.context_window, name)
      assert.same(name == "deepseek", provider.use_response_api, name)
      assert.is_false(provider.support_previous_response_id, name)
      assert.same(name, provider._dialect, name)
    end
  end)

  it("inherits the implementation of every built-in provider", function()
    local Providers = require("avante.providers")
    for _, config in pairs(Config.providers) do
      assert.is_nil(config.dialect)
    end
    for name in pairs(Config._defaults.providers) do
      local custom_name = "custom_" .. name
      Config.providers[custom_name] = { __inherited_from = name }
      local child = Providers[custom_name]
      assert.same(Providers[name]._protocol, child._protocol, name)
      assert.same(Providers[name]._dialect, child._dialect, name)
      assert.same(Config.providers[name].model, child.model, name)
    end
  end)

  it("resolves custom inheritance chains with child overrides and independent configurations", function()
    Config.override({
      providers = {
        deepseek = { extra_request_body = { temperature = 0.1, max_tokens = 16384 } },
        private_deepseek = {
          __inherited_from = "deepseek",
          endpoint = "https://example.test/v1",
          model = "private-model",
          extra_request_body = { temperature = 0.2, max_tokens = 8192 },
        },
        nested = {
          __inherited_from = "private_deepseek",
          model = "nested-model",
          extra_request_body = { temperature = 0.7 },
        },
      },
    })
    local Providers = require("avante.providers")
    local parent = Providers.private_deepseek
    assert.same("private-model", parent.model)
    parent.extra_request_body.max_tokens = 1
    local child = Providers.nested

    assert.same("nested", child._name)
    assert.same("private_deepseek", child.__inherited_from)
    assert.same("deepseek", parent.__inherited_from)
    assert.same("openai", child._protocol)
    assert.same("deepseek", child._dialect)
    assert.same("https://example.test/v1", child.endpoint)
    assert.same("DEEPSEEK_API_KEY", child.api_key_name)
    assert.same("nested-model", child.model)
    assert.same({
      temperature = 0.7,
      max_tokens = 8192,
      max_completion_tokens = 16384,
      reasoning_effort = "medium",
    }, child.extra_request_body)
    assert.same("responses", Providers.resolve_api_route(child))
    assert.is_false(child.support_previous_response_id)
    assert.is_function(child.list_models)
    child.extra_request_body.max_tokens = 1
    child.extra_request_body.temperature = 1
    assert.same(0.2, parent.extra_request_body.temperature)
    assert.same(0.2, Config.providers.private_deepseek.extra_request_body.temperature)
    assert.same(16384, Config.providers.deepseek.extra_request_body.max_tokens)
    assert.same(16384, Providers.deepseek.extra_request_body.max_tokens)
  end)

  it("requires explicit ChatGPT subscription authentication at each inheritance level", function()
    Config.override({
      providers = {
        openai = { auth_type = "subscription" },
        deepseek = { auth_type = "subscription" },
        nested = { __inherited_from = "deepseek" },
        opted_in = { __inherited_from = "nested", auth_type = "subscription" },
        leaf = { __inherited_from = "opted_in" },
      },
    })
    local Providers = require("avante.providers")
    assert.same("api_key", Providers.openrouter.auth_type)
    assert.is_true(Providers.env.require_api_key(Providers.openrouter))
    assert.same("subscription", Providers.deepseek.auth_type)
    assert.same("api_key", Providers.nested.auth_type)
    assert.same("subscription", Providers.opted_in.auth_type)
    assert.same("api_key", Providers.leaf.auth_type)
    assert.is_true(Providers.env.require_api_key(Providers.leaf))
  end)

  it("rejects missing parents and inheritance cycles without caching failed providers", function()
    local Providers = require("avante.providers")
    Config.providers.child = { __inherited_from = "parent" }
    for _, case in ipairs({
      { parent = "missing_provider", message = "Failed to find provider: missing_provider" },
      { parent = "parent", message = "Circular provider inheritance: parent" },
      { parent = "child", message = "Circular provider inheritance: child" },
    }) do
      Config.providers.parent = { __inherited_from = case.parent }
      assert.error_matches(function() return Providers.child end, case.message, nil, true)
      assert.is_nil(rawget(Providers, "child"))
      assert.is_nil(rawget(Providers, "parent"))
    end
    Config.providers.parent = { __inherited_from = "openai" }
    assert.same("openai", Providers.child._protocol)
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

  it("rejects custom providers without a parent", function()
    Config.providers.custom = {
      endpoint = "https://example.test/v1",
      model = "test-model",
    }

    local ok, err = pcall(function() return require("avante.providers").custom end)
    assert.is_false(ok)
    assert.matches("__inherited_from", err, nil, true)
  end)
end)
