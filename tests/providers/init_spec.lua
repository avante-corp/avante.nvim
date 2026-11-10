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
        test_openai_parent = {
          __inherited_from = "test_openai",
          endpoint = "https://parent.example.test/v1",
          api_key_name = "PARENT_API_KEY",
          model = "parent-model",
          extra_request_body = {
            parent_option = true,
            overridden_option = "parent",
          },
        },
        test_openai_child = {
          __inherited_from = "test_openai_parent",
          model = "child-model",
          extra_request_body = {
            child_option = true,
            overridden_option = "child",
          },
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
          render_result_header = function() rendered = rendered + 1 end,
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

  it("resolves cascading provider inheritance", function()
    local provider = require("avante.providers").test_openai_child

    assert.same("openai", provider._protocol)
    assert.same("test_openai_child", provider._name)
    assert.same("https://parent.example.test/v1", provider.endpoint)
    assert.same("child-model", provider.model)
    assert.same("openai", provider.dialect)
    assert.is_true(provider.extra_request_body.parent_option)
    assert.is_true(provider.extra_request_body.child_option)
    assert.same("child", provider.extra_request_body.overridden_option)
  end)

  it("rejects circular provider inheritance", function()
    Config.providers.cycle_a = { __inherited_from = "cycle_b" }
    Config.providers.cycle_b = { __inherited_from = "cycle_c" }
    Config.providers.cycle_c = { __inherited_from = "cycle_a" }

    local ok, err = pcall(function() return require("avante.providers").cycle_a end)

    assert.is_false(ok)
    assert.matches("Circular provider inheritance: cycle_a -> cycle_b -> cycle_c -> cycle_a", err, nil, true)
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
    assert.same("api_key", Providers.test_openai_child.auth_type)
    assert.is_true(Providers.env.require_api_key(Providers.test_openai_child))
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
