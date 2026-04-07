local Line = require("avante.ui.line")
local Base = require("avante.llm_tools.base")
local Highlights = require("avante.highlights")
local Utils = require("avante.utils")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "AskUserQuestion"

function M.enabled()
  local Config = require("avante.config")
  return Config.mode == "agentic"
end

M.description =
  "Ask the user a clarifying question with optional answer choices. Use this when you need user input to proceed."

M.support_streaming = true

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "question",
      description = "The question to ask the user",
      type = "string",
    },
    {
      name = "options",
      description = "Optional array of answer choices",
      type = "table",
      optional = true,
    },
    {
      name = "multi_select",
      description = "Whether multiple selections are allowed",
      type = "boolean",
      optional = true,
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "answer",
    description = "The user's answer",
    type = "string",
  },
}

---@class AskUserQuestionInput
---@field question string
---@field text? string
---@field options? ({ label: string, value: string, description?: string })[]
---@field multi_select? boolean

--- Extract answer text from a tool_result message content
---@param result_content any
---@return string
local function extract_answer(result_content)
  if type(result_content) == "string" then return result_content end
  if type(result_content) == "table" then
    if result_content.text then return result_content.text end
    if result_content[1] and result_content[1].text then return result_content[1].text end
    return vim.inspect(result_content)
  end
  return "..."
end

---@type avante.LLMToolOnRender<AskUserQuestionInput>
function M.on_render(input, opts)
  if not input then return {} end
  local state = opts.state
  local lines = {}
  local question = input.question or input.text or "(no question)"

  -- Header
  local header_text = state == "generating" and "Question (waiting for answer)" or "Question"
  table.insert(lines, Line:new({ { Utils.icon("❓ ") .. header_text, Highlights.AVANTE_THINKING } }))
  table.insert(lines, Line:new({ { "" } }))

  -- Question text
  local question_lines = vim.split(question, "\n")
  for _, text_line in ipairs(question_lines) do
    table.insert(lines, Line:new({ { "  " .. text_line } }))
  end

  -- Show options if present
  if input.options and #input.options > 0 then
    table.insert(lines, Line:new({ { "" } }))
    for i, opt in ipairs(input.options) do
      local label = type(opt) == "table" and (opt.label or opt.name or opt.value) or tostring(opt)
      local desc = type(opt) == "table" and opt.description or nil
      local line_text = "  " .. i .. ". " .. label
      if desc then line_text = line_text .. " — " .. desc end
      table.insert(lines, Line:new({ { line_text } }))
    end
  end

  -- Show answer if completed
  if state ~= "generating" and opts.result_message then
    local result_content = opts.result_message.message and opts.result_message.message.content
    if result_content then
      local answer_text = extract_answer(result_content)
      table.insert(lines, Line:new({ { "" } }))
      table.insert(lines, Line:new({ { "  → " .. answer_text, Highlights.AVANTE_TASK_COMPLETED } }))
    end
  end

  return lines
end

---@type AvanteLLMToolFunc<AskUserQuestionInput>
function M.func(input, opts)
  local on_complete = opts.on_complete
  if not on_complete then return false, "on_complete not provided" end

  local question = input.question or input.text or "Please answer"
  local options = input.options or {}

  if #options > 0 then
    -- Show options via vim.ui.select
    local items = {}
    for _, opt in ipairs(options) do
      local label = type(opt) == "table" and (opt.label or opt.name or opt.value) or tostring(opt)
      table.insert(items, label)
    end
    vim.ui.select(items, { prompt = question }, function(choice)
      if choice then
        on_complete(choice, nil)
      else
        on_complete("(no answer)", nil)
      end
    end)
  else
    -- Free-text response
    vim.ui.input({ prompt = question .. ": " }, function(answer)
      if answer then
        on_complete(answer, nil)
      else
        on_complete("(no answer)", nil)
      end
    end)
  end
end

return M
