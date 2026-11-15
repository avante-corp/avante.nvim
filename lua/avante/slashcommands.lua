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
--- - `/usage`: estimate the current context breakdown
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
    description = "Estimate the current context breakdown",
    details = "Estimate the current context breakdown",
    name = "usage",
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
  usage = function(sidebar, args, cb)
    local function format(value)
      local formatted = tostring(value):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
      return formatted
    end
    local function show(lines)
      sidebar:update_content(table.concat(lines, "\n"), { focus = false, scroll = false })
      if cb then cb(args) end
    end

    -- ACP agents build their own prompt, so we can't estimate it locally:
    -- report what the agent sent back for the latest request instead.
    if require("avante.api").is_acp_provider() then
      local usage = sidebar.chat_history and sidebar.chat_history.tokens_usage
      local context = sidebar.chat_history and sidebar.chat_history.acp_context_usage
      if not usage and not context then return show({ "No token usage reported by the ACP agent yet." }) end
      local lines = {}
      if context then
        table.insert(lines, "**Context window** _(reported by the agent)_")
        local percent = context.size > 0 and math.floor(context.used / context.size * 100 + 0.5) or 0
        table.insert(
          lines,
          string.format("• Used: %s / %s (%d%%)", format(context.used), format(context.size), percent)
        )
        if context.cost then
          table.insert(lines, string.format("• Session cost: %.4f %s", context.cost.amount, context.cost.currency))
        end
      end
      if usage then
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, "**Token usage** _(reported by the agent for the latest request)_")
        for _, entry in ipairs({
          { "Input tokens", usage.prompt_tokens },
          { "Cached input tokens", usage.cached_input_tokens },
          { "Output tokens", usage.completion_tokens },
          { "Reasoning tokens", usage.reasoning_tokens },
          { "Total", usage.total_tokens },
        }) do
          if entry[2] ~= nil then table.insert(lines, string.format("• %s: %s", entry[1], format(entry[2]))) end
        end
      end
      return show(lines)
    end

    sidebar:get_generate_prompts_options("", function(options)
      local breakdown = { system = 0, tools = 0, subagents = 0, conversation = 0 }
      local prompts = require("avante.llm").generate_prompts(options)
      local count_tokens = require("avante.utils").tokens.calculate_tokens
      breakdown.system = count_tokens(prompts.system_prompt or "")
      for _, message in ipairs(prompts.messages or {}) do
        breakdown.conversation = breakdown.conversation + count_tokens(message.content)
      end
      local provider = require("avante.providers")[require("avante.config").provider]
      if not (provider and provider.disable_tools) then
        -- Count the JSON Schema definitions actually sent to the provider.
        for _, definition in ipairs(require("avante.libs.rig_client").tool_definitions(prompts.tools)) do
          local tokens = count_tokens(vim.json.encode(definition))
          if definition.name == "dispatch_agent" then
            breakdown.subagents = breakdown.subagents + tokens
          else
            breakdown.tools = breakdown.tools + tokens
          end
        end
      end
      local total_token_count = breakdown.system + breakdown.tools + breakdown.subagents + breakdown.conversation
      local function row(label, value)
        local percent = total_token_count > 0 and math.floor(value / total_token_count * 100 + 0.5) or 0
        return string.format("• %s: %s (%d%%)", label, format(value), percent)
      end
      show({
        "**Context breakdown** _(estimated)_",
        row("System prompt", breakdown.system),
        row("Tool definitions", breakdown.tools),
        row("Subagent definitions", breakdown.subagents),
        row("Conversation", breakdown.conversation),
      })
    end)
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
    local api = require("avante.api")
    if api.is_acp_provider() then
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
      ---@return AvanteSlashCommand
      function(command)
        local command_ = vim.deepcopy(command)
        command_.callback = callbacks[command.name]
        return command_
      end
    )
    :totable()
end

return M
