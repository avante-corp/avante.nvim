local Base = require("avante.llm_tools.base")
local History = require("avante.history")

---@class avante.tools.delete_tool_use_messages: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "delete_tool_use_messages"

M.description =
  "Since many tool use messages are useless for completing subsequent tasks and may cause excessive token consumption or even prevent task completion, you need to decide whether to invoke this tool to delete the useless tool use messages."

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "tool_use_id",
      description = "The tool use id",
      type = "string",
    },
  },
  usage = {
    tool_use_id = "The tool use id",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "True if the deletion was successful, false otherwise",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ tool_use_id: string }>
function M.func(input, _opts)
  local sidebar = require("avante").get()
  if not sidebar then return false, "Avante sidebar not found" end
  local history_messages = History.get_history_messages(sidebar.chat_history)
  local the_deleted_message_uuids = {}
  for _, msg in ipairs(history_messages) do
    local use = History.Helpers.get_tool_use_data(msg)
    if use then
      if use.id == input.tool_use_id then table.insert(the_deleted_message_uuids, msg.uuid) end
      goto continue
    end
    local result = History.Helpers.get_tool_result_data(msg)
    if result then
      if result.tool_use_id == input.tool_use_id then table.insert(the_deleted_message_uuids, msg.uuid) end
    end
    ::continue::
  end
  sidebar:delete_history_messages(the_deleted_message_uuids)
  return true, nil
end

return M
