---@mod avante-slashcommands Slash commands
---@brief [[
---Built-in slash commands available in the Avante input buffer.
---
--- Slash commands are triggered by typing `/` at the beginning of a chat
--- message. Commands with callbacks are handled locally by Avante; other
--- commands may rewrite the prompt before it is submitted.
---
--- - `/help`: show available commands
--- - `/init`: initialize AGENTS.md based on the current project
--- - `/clear`: clear chat history
--- - `/new`: start a new chat
--- - `/resume`: open a picker for previous chat sessions
--- - `/compact`: compact history messages
--- - `/model`: select model
--- - `/lines <start>-<end> <question>`: ask about specific lines
--- - `/commit`: generate a commit message
---@brief ]]

---@class avante.SlashCommands
---@field get_builtin_commands fun(): AvanteSlashCommand[]

local M = {}

---@type AvanteSlashCommand[]
local builtin_commands = {
  {
    description = "Show help message",
    details = "Show help message",
    name = "help",
  },
  {
    description = "Init AGENTS.md based on the current project",
    details = "Init AGENTS.md based on the current project",
    name = "init",
  },
  {
    description = "Clear chat history",
    details = "Clear chat history",
    name = "clear",
  },
  {
    description = "New chat",
    details = "New chat",
    name = "new",
  },
  {
    description = "Resume a previous chat session",
    details = "Open a picker for previous chat sessions",
    name = "resume",
  },
  {
    description = "Compact history messages to save tokens",
    details = "Compact history messages to save tokens",
    name = "compact",
  },
  {
    description = "Select model",
    details = "Select model",
    name = "model",
  },
  {
    shorthelp = "Ask a question about specific lines",
    description = "/lines <start>-<end> <question>",
    details = "Ask a question about specific lines\n/lines <start>-<end> <question>",
    name = "lines",
  },
  {
    description = "Commit the changes",
    details = "Commit the changes",
    name = "commit",
  },
}

---@param commands AvanteSlashCommand[]
---@return string
local function get_help_text(commands)
  local help_text = ""
  for _, command in ipairs(commands) do
    help_text = help_text .. "- " .. command.name .. ": " .. (command.shorthelp or command.description) .. "\n"
  end
  return help_text
end

---@type {[AvanteSlashCommandBuiltInName]: AvanteSlashCommandCallback}
local callbacks = {
  help = function(sidebar, args, cb)
    sidebar:update_content(get_help_text(builtin_commands), { focus = false, scroll = false })
    if cb then cb(args) end
  end,
  clear = function(sidebar, args, cb) sidebar:clear_history(args, cb) end,
  new = function(sidebar, args, cb) sidebar:new_chat(args, cb) end,
  resume = function(_, _, cb)
    vim.cmd("Avante resume")
    if cb then cb("") end
  end,
  compact = function(sidebar, args, cb) sidebar:compact_history_messages(args, cb) end,
  init = function(sidebar, args, cb) sidebar:init_current_project(args, cb) end,
  lines = function(_, args, cb)
    if cb then cb(args) end
  end,
  commit = function(_, _, cb)
    local question = "Please commit the changes"
    if cb then cb(question) end
  end,
  model = function(_, _, cb)
    local Config = require("avante.config")
    local api = require("avante.api")
    if Config.acp_providers[Config.provider] then
      api.select_acp_model()
    else
      api.select_model()
    end
    if cb then cb("") end
  end,
}

---@return AvanteSlashCommand[]
function M.get_builtin_commands()
  return vim
    .iter(builtin_commands)
    :map(
      ---@param command AvanteSlashCommand
      function(command)
        local command_ = vim.deepcopy(command)
        command_.callback = callbacks[command.name]
        return command_
      end
    )
    :totable()
end

return M
