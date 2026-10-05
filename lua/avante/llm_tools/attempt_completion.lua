local Base = require("avante.llm_tools.base")
local Config = require("avante.config")
local Highlights = require("avante.highlights")
local Line = require("avante.ui.line")

---@alias AttemptCompletionInput {result: string, command?: string}

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "attempt_completion"

M.description =
  [[Present the result once the task is complete and previous tool results confirm the relevant operations succeeded. Summarize the changes and verification accurately. An optional command can demonstrate the result through the normal command permission flow.]]

M.support_streaming = true

M.enabled = function() return Config.mode == "agentic" end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "result",
      description = "The result of the task. Formulate this result in a way that is final and does not require further input from the user. Don't end your result with questions or offers for further assistance.",
      type = "string",
    },
    {
      name = "command",
      description = "An optional CLI command to demonstrate the result. It runs from the project root through normal command permissions and must be valid for the current operating system.",
      type = "string",
      optional = true,
    },
  },
  usage = {
    result = "The result of the task. Formulate this result in a way that is final and does not require further input from the user. Don't end your result with questions or offers for further assistance.",
    command = "A CLI command to demonstrate the result from the project root",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the task was completed successfully",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the file was not read successfully",
    type = "string",
    optional = true,
  },
}

---@type avante.LLMToolOnRender<AttemptCompletionInput>
function M.on_render(input)
  local lines = {}
  table.insert(lines, Line:new({ { "✓  Task Completed", Highlights.AVANTE_TASK_COMPLETED } }))
  table.insert(lines, Line:new({ { "" } }))
  local result = input.result or ""
  local text_lines = vim.split(result, "\n")
  for _, text_line in ipairs(text_lines) do
    table.insert(lines, Line:new({ { text_line } }))
  end
  return lines
end

---@type AvanteLLMToolFunc<AttemptCompletionInput>
function M.func(input, opts)
  if not opts.on_complete then return false, "on_complete not provided" end
  local sidebar = require("avante").get()
  if not sidebar then return false, "Avante sidebar not found" end

  local is_streaming = opts.streaming or false
  if is_streaming then
    -- wait for stream completion as command may not be complete yet
    return
  end

  opts.session_ctx.attempt_completion_is_called = true

  if input.command and input.command ~= vim.NIL and input.command ~= "" then
    opts.session_ctx.always_yes = false
    require("avante.llm_tools.bash").func({ path = ".", command = input.command }, opts)
  else
    opts.on_complete(true, nil)
  end
end

return M
