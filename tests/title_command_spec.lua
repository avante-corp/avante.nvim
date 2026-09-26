local Utils = require("avante.utils")
local Config = require("avante.config")

local function title_command()
  return assert(vim.iter(Utils.get_commands()):find(function(command) return command.name == "title" end))
end

describe("/title", function()
  local original_local_only_commands
  local original_slash_commands

  before_each(function()
    original_local_only_commands = Config.local_only_commands
    original_slash_commands = Config.slash_commands
    Config.local_only_commands = { "title" }
    Config.slash_commands = {}
  end)

  after_each(function()
    Config.local_only_commands = original_local_only_commands
    Config.slash_commands = original_slash_commands
  end)

  it("renames the active thread from its arguments", function()
    local renamed
    title_command().callback({
      rename_thread = function(_, title) renamed = title end,
    }, "  Release prep  ")

    assert.equals("Release prep", renamed)
  end)

  it("prompts for a title when no arguments are given", function()
    local original_input = vim.ui.input
    local prompt_opts
    local renamed
    vim.ui.input = function(opts, callback)
      prompt_opts = opts
      callback("Prompted title")
    end

    title_command().callback({
      chat_history = { title = "Current title" },
      rename_thread = function(_, title) renamed = title end,
    }, "")

    vim.ui.input = original_input
    assert.equals("Current title", prompt_opts.default)
    assert.equals("Prompted title", renamed)
  end)

  it("cannot be replaced by an ACP command with the same name", function()
    Utils.register_acp_commands({ { name = "title", description = "Agent title" } })

    local command = title_command()
    assert.equals("builtin", command.source)
    assert.is_function(command.callback)
  end)
end)
