local Base = require("avante.llm_tools.base")

---@class avante.tools.read_todos: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "read_todos"

M.description = "Read TODOs from the current task"

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {},
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "todos",
    description = "The TODOs from the current task",
    type = "array",
  },
}

M.on_render = function() return {} end

---@param _input table
---@param opts AvanteLLMToolFuncOpts
---@return avante.TODO[]|false|nil, string?
function M.func(_input, opts)
  local on_complete = opts.on_complete
  local sidebar = require("avante").get()
  if not sidebar then return false, "Avante sidebar not found" end
  local todos = sidebar.chat_history.todos or {}
  if on_complete then
    on_complete(vim.json.encode(todos), nil)
    return nil, nil
  end
  return todos, nil
end

return M
