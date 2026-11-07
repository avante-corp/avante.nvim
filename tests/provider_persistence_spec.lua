describe("provider persistence", function()
  local stub = require("luassert.stub")
  local Config
  local selector_stub
  local state_dir
  local original_stdpath
  local previous_avante
  local previous_avante_module

  local function setup(provider)
    Config.setup({
      provider = provider,
      providers = {
        jedha = {
          __inherited_from = "openai",
          model = "jedha-model",
          api_key_name = "",
          setup = function() end,
        },
      },
      acp_providers = { test_acp = { command = "test-agent" } },
      windows = { sidebar_header = { include_model = true } },
    })
  end

  local function restart(provider)
    for _, name in ipairs({ "avante.config", "avante.providers", "avante.api", "avante.model_selector" }) do
      package.loaded[name] = nil
    end
    Config = require("avante.config")
    setup(provider)
  end

  before_each(function()
    previous_avante = vim.g.avante
    vim.g.avante = nil
    previous_avante_module = package.loaded["avante"]
    package.loaded["avante"] = { get = function() end }
    state_dir = vim.fn.tempname()
    original_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(kind)
      if kind == "state" then return state_dir end
      return original_stdpath(kind)
    end
    restart("claude")
  end)

  after_each(function()
    if selector_stub then selector_stub:revert() end
    selector_stub = nil
    vim.fn.stdpath = original_stdpath
    vim.fn.delete(state_dir, "rf")
    vim.g.avante = previous_avante
    package.loaded["avante"] = previous_avante_module
    for _, name in ipairs({ "avante.config", "avante.providers", "avante.api", "avante.model_selector" }) do
      package.loaded[name] = nil
    end
  end)

  it("restores an explicitly saved custom provider over the configured default", function()
    require("avante.api").switch_provider("jedha", true)
    restart("claude")
    assert.are.equal("jedha", Config.provider)
    assert.are.equal("jedha-model", Config.providers.jedha.model)
  end)

  it("keeps provider and model switches temporary without --save", function()
    Config.override({ providers = { jedha = { list_models = false, model_names = { "another-model" } } } })
    require("avante.api").switch_provider("jedha")
    selector_stub = stub(require("avante.ui.selector"), "new").invokes(function(_, opts)
      return { open = function() opts.on_select({ "jedha/another-model" }) end }
    end)
    require("avante.model_selector").open()

    assert.equals("jedha", Config.provider)
    assert.equals("another-model", Config.providers.jedha.model)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(state_dir, "avante", "config.json")))
    restart("claude")
    assert.equals("claude", Config.provider)
  end)

  it("does not overwrite a saved choice with a temporary switch", function()
    require("avante.api").switch_provider("jedha", true)
    require("avante.api").switch_provider("test_acp")
    restart("claude")
    assert.are.equal("jedha", Config.provider)
  end)

  it("restores an ACP provider without a model", function()
    require("avante.api").switch_provider("test_acp", true)
    restart("claude")
    assert.are.equal("test_acp", Config.provider)
  end)

  it("restores a standard provider over an ACP startup default", function()
    require("avante.api").switch_provider("jedha", true)
    restart("test_acp")
    assert.are.equal("jedha", Config.provider)
  end)

  it("accepts older provider-only records", function()
    vim.fn.mkdir(vim.fs.joinpath(state_dir, "avante"), "p")
    vim.fn.writefile(
      { vim.json.encode({ last_provider = "jedha" }) },
      vim.fs.joinpath(state_dir, "avante", "config.json")
    )
    restart(nil)
    assert.are.equal("jedha", Config.provider)
    assert.are.equal("jedha-model", Config.providers.jedha.model)
  end)

  it("preserves an explicitly saved provider when selecting another model", function()
    require("avante.api").switch_provider("jedha", true)
    Config.save_last_model("another-model", "jedha")
    restart("claude")
    assert.are.equal("jedha", Config.provider)
    assert.are.equal("another-model", Config.providers.jedha.model)
  end)

  it("falls back when a saved provider has been removed", function()
    require("avante.api").switch_provider("jedha", true)
    Config.setup({ provider = "claude" })
    assert.are.equal("claude", Config.provider)
  end)
end)
