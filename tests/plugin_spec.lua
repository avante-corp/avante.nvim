local Config = require("avante.config")
Config.setup({})

describe("plugin commands", function()
  local originals, selected, logged_in
  local modules = { "avante.commands", "avante.path", "avante.api", "avante.model_selector" }

  before_each(function()
    originals = {
      loaded = vim.g.avante_loaded,
      support_paste_image = Config.support_paste_image,
      commands = vim.api.nvim_get_commands({}),
      modules = {},
    }
    for _, name in ipairs(modules) do
      originals.modules[name] = package.loaded[name]
    end
    vim.g.avante_loaded = nil
    Config.support_paste_image = function() return false end
    package.loaded["avante.commands"] = { setup = function() end }
    package.loaded["avante.path"] = {}
    package.loaded["avante.api"] = { login = function() logged_in = true end }
    package.loaded["avante.model_selector"] = { open = function(all, timeout) selected = { all, timeout } end }
    selected, logged_in = nil, false
  end)

  after_each(function()
    for name in pairs(vim.api.nvim_get_commands({})) do
      if not originals.commands[name] then vim.api.nvim_del_user_command(name) end
    end
    for _, name in ipairs(modules) do
      package.loaded[name] = originals.modules[name]
    end
    vim.g.avante_loaded = originals.loaded
    Config.support_paste_image = originals.support_paste_image
  end)

  it("loads and dispatches login and model-picker commands", function()
    dofile("plugin/avante.lua")
    vim.cmd("AvanteModels --all 2500")
    assert.same({ true, 2500 }, selected)
    vim.cmd("AvanteLogin")
    assert.is_true(logged_in)
  end)
end)
