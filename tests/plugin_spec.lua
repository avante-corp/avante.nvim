describe("plugin provider picker", function()
  local Config
  local commands
  local selected
  local switched_provider
  local previous_avante_loaded
  local previous_create_user_command
  local previous_select
  local previous_modules
  local module_names = {
    "avante.api",
    "avante.commands",
    "avante.config",
    "avante.path",
    "avante.providers",
    "avante.utils",
  }

  before_each(function()
    previous_modules = {}
    for _, name in ipairs(module_names) do
      previous_modules[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    previous_avante_loaded = vim.g.avante_loaded
    previous_create_user_command = vim.api.nvim_create_user_command
    previous_select = vim.ui.select

    Config = {
      acp_providers = { test_acp = { command = "test-agent" } },
      providers = { test_openai = {} },
      support_paste_image = function() return false end,
    }
    commands = {}
    selected = nil
    switched_provider = nil

    package.loaded["avante.api"] = {
      switch_provider = function(provider_name) switched_provider = provider_name end,
    }
    package.loaded["avante.commands"] = { setup = function() end }
    package.loaded["avante.config"] = Config
    package.loaded["avante.path"] = {}
    package.loaded["avante.utils"] = {}

    vim.g.avante_loaded = nil
    vim.api.nvim_create_user_command = function(name, command) commands[name] = command end
    vim.ui.select = function(items, opts, on_choice) selected = { items = items, opts = opts, on_choice = on_choice } end

    dofile("plugin/avante.lua")
  end)

  after_each(function()
    for _, name in ipairs(module_names) do
      package.loaded[name] = previous_modules[name]
    end
    vim.g.avante_loaded = previous_avante_loaded
    vim.api.nvim_create_user_command = previous_create_user_command
    vim.ui.select = previous_select
  end)

  it("marks ACP providers only in the picker label", function()
    commands.AvanteSwitchProvider({ args = "" })

    assert.are.same("test_acp (ACP)", selected.opts.format_item("test_acp"))
    assert.are.same("test_openai", selected.opts.format_item("test_openai"))

    selected.on_choice("test_acp", 1)
    assert.are.same("test_acp", switched_provider)
  end)
end)
