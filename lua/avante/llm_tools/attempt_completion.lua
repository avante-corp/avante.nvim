local Base = require("avante.llm_tools.base")
local Config = require("avante.config")
local Highlights = require("avante.highlights")
local Line = require("avante.ui.line")

---@alias AttemptCompletionInput {result: string, command?: string}

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "attempt_completion"

M.description = [[
After each tool use, the user will respond with the result of that tool use, i.e. if it succeeded or failed, along with any reasons for failure. Once you've received the results of tool uses and can confirm that the task is complete, use this tool to present the result of your work to the user. Optionally you may provide a CLI command to showcase the result of your work. The user may respond with feedback if they are not satisfied with the result, which you can use to make improvements and try again.
IMPORTANT NOTE: This tool CANNOT be used until you've confirmed from the user that any previous tool uses were successful. Failure to do so will result in code corruption and system failure. Before using this tool, you must ask yourself in `think` tool calling if you've confirmed from the user that any previous tool uses were successful. If not, then DO NOT use this tool.
]]

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
      description = [[A CLI command to execute to show a live demo of the result to the user. For example, use \`open index.html\` to display a created html website, or \`open localhost:3000\` to display a locally running development server. But DO NOT use commands like \`echo\` or \`cat\` that merely print text. This command should be valid for the current operating system. Ensure the command is properly formatted and does not contain any harmful instructions.]],
      type = "string",
      optional = true,
    },
  },
  usage = {
    result = "The result of the task. Formulate this result in a way that is final and does not require further input from the user. Don't end your result with questions or offers for further assistance.",
    command = "A CLI command to execute to show a live demo of the result to the user. For example, use `open index.html` to display a created html website, or `open localhost:3000` to display a locally running development server. But DO NOT use commands like `echo` or `cat` that merely print text. This command should be valid for the current operating system. Ensure the command is properly formatted and does not contain any harmful instructions.",
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
  if not input then return {} end
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

  if
    input.command
    and input.command ~= vim.NIL
    and input.command ~= ""
    and not vim.startswith(input.command, "open ")
  then
    opts.session_ctx.always_yes = false
    require("avante.llm_tools.bash").func({ command = input.command }, opts)
  else
    opts.on_complete(true, nil)
  end
end

return M
