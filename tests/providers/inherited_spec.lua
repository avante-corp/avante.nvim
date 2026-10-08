describe("inherited providers", function()
  local Config, Providers
  local original_openai_config

  before_each(function()
    package.loaded["avante.providers"] = nil
    Config = require("avante.config")
    if Config.providers == nil then Config.providers = {} end
    original_openai_config = Config.providers.openai
    Providers = require("avante.providers")
  end)

  after_each(function()
    if Config.providers then
      Config.providers.my_inherited_a = nil
      Config.providers.my_inherited_b = nil
      Config.providers.my_inherited_c = nil
      if original_openai_config ~= nil then Config.providers.openai = original_openai_config end
    end
  end)

  it("does not inherit auth_type from the base provider config", function()
    Config.providers.openai = { auth_type = "chatgpt" }
    Config.providers.my_inherited_a = {
      __inherited_from = "openai",
      api_key_name = "MY_KEY",
    }

    local functor = Providers.my_inherited_a

    assert.is_nil(functor.auth_type)
    assert.equals("MY_KEY", functor.api_key_name)
  end)

  it("respects an explicit auth_type on the inherited provider", function()
    Config.providers.openai = { auth_type = "chatgpt" }
    Config.providers.my_inherited_b = {
      __inherited_from = "openai",
      auth_type = "chatgpt",
    }

    local functor = Providers.my_inherited_b

    assert.equals("chatgpt", functor.auth_type)
  end)

  it("installs a generic setup instead of the base module setup", function()
    Config.providers.openai = { auth_type = "chatgpt" }
    Config.providers.my_inherited_c = {
      __inherited_from = "openai",
      api_key_name = "MY_KEY",
    }

    package.loaded["avante.tokenizers"] = { setup = function() end }

    local functor = Providers.my_inherited_c
    local openai_functor = require("avante.providers.openai")

    local OpenAIAuth = require("avante.auth.providers.openai")
    local auth_setup_called = false
    local original_auth_setup = OpenAIAuth.setup
    OpenAIAuth.setup = function() auth_setup_called = true end

    local ok = pcall(functor.setup)

    OpenAIAuth.setup = original_auth_setup

    assert.is_true(ok)
    assert.not_equals(openai_functor.setup, functor.setup)
    assert.is_false(auth_setup_called)
  end)
end)
