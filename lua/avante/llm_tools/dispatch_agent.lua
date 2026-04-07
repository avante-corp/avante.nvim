local Providers = require("avante.providers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local History = require("avante.history")
local Line = require("avante.ui.line")
local Highlights = require("avante.highlights")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "dispatch_agent"

M.get_description = function()
  local provider = Providers[Config.provider]
  if Config.provider:match("copilot") and provider.model and provider.model:match("gpt") then
    return [[Launch a new agent that has access to the following tools: `glob`, `grep`, `ls`, `view`, `attempt_completion`. When you are searching for a keyword or file and are not confident that you will find the right match on the first try, use the Agent tool to perform the search for you.]]
  end

  return [[Launch a new agent that has access to the following tools: `glob`, `grep`, `ls`, `view`, `attempt_completion`. When you are searching for a keyword or file and are not confident that you will find the right match on the first try, use the Agent tool to perform the search for you. For example:

- If you are searching for a keyword like "config" or "logger", the Agent tool is appropriate
- If you want to read a specific file path, use the `view` or `glob` tool instead of the `dispatch_agent` tool, to find the match more quickly
- If you are searching for a specific class definition like "class Foo", use the `glob` tool instead, to find the match more quickly

RULES:
- Do not ask for more information than necessary. Use the tools provided to accomplish the user's request efficiently and effectively. When you've completed your task, you must use the attempt_completion tool to present the result to the user. The user may provide feedback, which you can use to make improvements and try again.
- NEVER end attempt_completion result with a question or request to engage in further conversation! Formulate the end of your result in a way that is final and does not require further input from the user.

OBJECTIVE:
1. Analyze the user's task and set clear, achievable goals to accomplish it. Prioritize these goals in a logical order.
2. Work through these goals sequentially, utilizing available tools one at a time as necessary. Each goal should correspond to a distinct step in your problem-solving process. You will be informed on the work completed and what's remaining as you go.
3. Once you've completed the user's task, you must use the attempt_completion tool to present the result of the task to the user. You may also provide a CLI command to showcase the result of your task; this can be particularly useful for web development tasks, where you can run e.g. \`open index.html\` to show the website you've built.

Usage notes:
1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.
3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
4. The agent's outputs should generally be trusted
5. IMPORTANT: The agent can not use `bash`, `write`, `str_replace`, so can not modify files. If you want to use these tools, use them directly instead of going through the agent.]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "prompt",
      description = "The task for the agent to perform",
      type = "string",
    },
  },
  required = { "prompt" },
  usage = {
    prompt = "The task for the agent to perform",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "result",
    description = "The result of the agent",
    type = "string",
  },
  {
    name = "error",
    description = "The error message if the agent fails",
    type = "string",
    optional = true,
  },
}

local function get_available_tools()
  return {
    require("avante.llm_tools.ls"),
    require("avante.llm_tools.grep"),
    require("avante.llm_tools.glob"),
    require("avante.llm_tools.view"),
    require("avante.llm_tools.attempt_completion"),
  }
end

---@class avante.DispatchAgentInput
---@field prompt string

---@type avante.LLMToolOnRender<avante.DispatchAgentInput>
function M.on_render(input, opts)
  if not input then return {} end
  local result_message = opts.result_message
  local store = opts.store or {}
  local messages = store.messages or {}
  local tool_use_summary = {}
  for _, msg in ipairs(messages) do
    local summary
    local tool_use = History.Helpers.get_tool_use_data(msg)
    if tool_use then
      local tool_result = History.Helpers.get_tool_result(tool_use.id, messages)
      if tool_result then
        if tool_use.name == "ls" then
          local path = tool_use.input.path
          if tool_result.is_error then
            summary = string.format("Ls %s: failed", path)
          else
            local ok, filepaths = pcall(vim.json.decode, tool_result.content)
            if ok then summary = string.format("Ls %s: %d paths", path, #filepaths) end
          end
        elseif tool_use.name == "grep" then
          local path = tool_use.input.path
          local query = tool_use.input.query
          if tool_result.is_error then
            summary = string.format("Grep %s in %s: failed", query, path)
          else
            local ok, filepaths = pcall(vim.json.decode, tool_result.content)
            if ok then summary = string.format("Grep %s in %s: %d paths", query, path, #filepaths) end
          end
        elseif tool_use.name == "glob" then
          local path = tool_use.input.path
          local pattern = tool_use.input.pattern
          if tool_result.is_error then
            summary = string.format("Glob %s in %s: failed", pattern, path)
          else
            local ok, result = pcall(vim.json.decode, tool_result.content)
            if ok then
              local matches = result.matches
              if matches then summary = string.format("Glob %s in %s: %d matches", pattern, path, #matches) end
            end
          end
        elseif tool_use.name == "view" then
          local path = tool_use.input.path
          if tool_result.is_error then
            summary = string.format("View %s: failed", path)
          else
            local ok, result = pcall(vim.json.decode, tool_result.content)
            if ok and type(result) == "table" and type(result.content) == "string" then
              local lines = vim.split(result.content, "\n")
              summary = string.format("View %s: %d lines", path, #lines)
            end
          end
        end
      end
      if summary then summary = "  " .. Utils.icon("🛠️ ") .. summary end
    else
      summary = History.Helpers.get_text_data(msg)
    end
    if summary then table.insert(tool_use_summary, summary) end
  end
  local state = "running"
  local icon = Utils.icon("🔄 ")
  local hl = Highlights.AVANTE_TASK_RUNNING
  if result_message then
    local result = History.Helpers.get_tool_result_data(result_message)
    if result then
      if result.is_error then
        state = "failed"
        icon = Utils.icon("❌ ")
        hl = Highlights.AVANTE_TASK_FAILED
      else
        state = "completed"
        icon = Utils.icon("✅ ")
        hl = Highlights.AVANTE_TASK_COMPLETED
      end
    end
  end
  local lines = {}
  table.insert(lines, Line:new({ { icon .. "Subtask " .. state, hl } }))
  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task:" } }))
  local prompt_lines = vim.split(input.prompt or "", "\n")
  for _, line in ipairs(prompt_lines) do
    table.insert(lines, Line:new({ { "    " .. line } }))
  end
  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task summary:" } }))
  for _, summary in ipairs(tool_use_summary) do
    local summary_lines = vim.split(summary, "\n")
    for _, line in ipairs(summary_lines) do
      table.insert(lines, Line:new({ { "    " .. line } }))
    end
  end
  return lines
end

---@type AvanteLLMToolFunc<avante.DispatchAgentInput>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx

  local Llm = require("avante.llm")
  if not on_complete then return false, "on_complete not provided" end

  local prompt = input.prompt
  local tools = get_available_tools()
  local start_time = Utils.get_timestamp()

  if on_log then on_log("prompt: " .. prompt) end

  local system_prompt = ([[You are a helpful assistant with access to various tools.
Your task is to help the user with their request: "${prompt}"
Be thorough and use the tools available to you to find the most relevant information.
When you're done, provide a clear and concise summary of what you found.]]):gsub("${prompt}", prompt)

  local history_messages = {}
  local tool_use_messages = {}

  local total_tokens = 0
  local result = ""

  ---@type avante.AgentLoopOptions
  local agent_loop_options = {
    system_prompt = system_prompt,
    user_input = "start",
    tools = tools,
    on_tool_log = session_ctx.on_tool_log,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        local idx = nil
        for i, m in ipairs(history_messages) do
          if m.uuid == msg.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = msg
        else
          table.insert(history_messages, msg)
        end
      end
      if opts.set_store then opts.set_store("messages", history_messages) end
      for _, msg in ipairs(msgs) do
        local tool_use = History.Helpers.get_tool_use_data(msg)
        if tool_use then
          tool_use_messages[msg.uuid] = true
          if tool_use.name == "attempt_completion" and tool_use.input and tool_use.input.result then
            result = tool_use.input.result
          end
        end
      end
    end,
    session_ctx = session_ctx,
    on_start = session_ctx.on_start,
    on_chunk = function(chunk)
      if not chunk then return end
      total_tokens = total_tokens + (#vim.split(chunk, " ") * 1.3)
    end,
    on_complete = function(err)
      if err ~= nil then
        err = string.format("dispatch_agent failed: %s", vim.inspect(err))
        on_complete(err, nil)
        return
      end
      local end_time = Utils.get_timestamp()
      local elapsed_time = Utils.datetime_diff(start_time, end_time)
      local tool_use_count = vim.tbl_count(tool_use_messages)
      local summary = "dispatch_agent Done ("
        .. (tool_use_count <= 1 and "1 tool use" or tool_use_count .. " tool uses")
        .. " · "
        .. math.ceil(total_tokens)
        .. " tokens · "
        .. elapsed_time
        .. "s)"
      if session_ctx.on_messages_add then
        local message = History.Message:new("assistant", "\n\n" .. summary, {
          just_for_display = true,
        })
        session_ctx.on_messages_add({ message })
      end
      on_complete(result, nil)
    end,
  }

  Llm.agent_loop(agent_loop_options)
end

return M
