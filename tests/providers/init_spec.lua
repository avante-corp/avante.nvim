describe("providers", function()
  local Config
  local Providers
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
          api_key_name = "",
          model = "gpt-test",
          parse_curl_args = function() end,
          setup = function() end,
        },
        test_claude = {
          api_key_name = "",
          model = "claude-test",
          parse_curl_args = function() end,
          setup = function() end,
        },
      },
      acp_providers = {
        test_acp = {
          command = "test-agent",
        },
      },
      windows = {
        sidebar_header = {
          include_model = true,
        },
      },
    })
    Providers = require("avante.providers")
  end)

  after_each(function()
    vim.g.avante = previous_avante
    package.loaded["avante"] = previous_avante_module
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil
    Providers = nil
  end)

  it("marks ACP providers in provider picker labels", function()
    assert.are.same("test_openai", Providers.format_provider_name("test_openai"))
    assert.are.same("test_acp (ACP)", Providers.format_provider_name("test_acp"))
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
end)
