local Base = require("avante.llm_tools.base")

---@class avante.tools.write_todos: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "write_todos"

M.description = "Write TODOs to the current task"

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "todos",
      description = "The entire TODOs array to write",
      type = "array",
      items = {
        name = "items",
        type = "object",
        fields = {
          {
            name = "id",
            description = "The ID of the TODO",
            type = "string",
          },
          {
            name = "content",
            description = "The content of the TODO",
            type = "string",
          },
          {
            name = "status",
            description = "The status of the TODO",
            type = "string",
            choices = { "todo", "doing", "done", "cancelled" },
          },
          {
            name = "priority",
            description = "The priority of the TODO",
            type = "string",
            choices = { "low", "medium", "high" },
          },
        },
      },
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the TODOs were added successfully",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the TODOs could not be updated",
    type = "string",
    optional = true,
  },
}

M.on_render = function() return {} end

---@type AvanteLLMToolFunc<{ todos: avante.TODO[] }>
function M.func(input, opts)
  local on_complete = opts.on_complete
  local sidebar = require("avante").get()
  if not sidebar then return false, "Avante sidebar not found" end
  local todos = input.todos
  if not todos or #todos == 0 then return false, "No todos provided" end
  sidebar:update_todos(todos)
  if on_complete then
    on_complete(true, nil)
    return nil, nil
  end
  return true, nil
end

return M
