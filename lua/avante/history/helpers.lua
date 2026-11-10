local M = {}

---If message is a text message return the text.
---@param message avante.HistoryMessage
---@return string | nil
function M.get_text_data(message)
  local content = message.message.content
  if type(content) == "table" then
    assert(#content == 1, "more than one entry in message content")
    local item = content[1]
    if type(item) == "string" then
      return item
    elseif type(item) == "table" and item.type == "text" then
      return item.content
    end
  elseif type(content) == "string" then
    return content
  end
end

---If message is a "tool use" message returns information about the tool invocation.
---@param message avante.HistoryMessage
---@return AvanteLLMToolUse | nil
function M.get_tool_use_data(message)
  local content = message.message.content
  if type(content) == "table" then
    assert(#content == 1, "more than one entry in message content")
    local item = content[1]
    if item.type == "tool_use" then
      ---@cast item AvanteLLMToolUse
      return item
    end
  end
end

---If message is a "tool result" message returns results of the tool invocation.
---@param message avante.HistoryMessage
---@return AvanteLLMToolResult | nil
function M.get_tool_result_data(message)
  local content = message.message.content
  if type(content) == "table" then
    assert(#content == 1, "more than one entry in message content")
    local item = content[1]
    if item.type == "tool_result" then
      ---@cast item AvanteLLMToolResult
      return item
    end
  end
end

---Attempts to locate result of a tool execution given tool invocation ID
---@param id string
---@param messages avante.HistoryMessage[]
---@return AvanteLLMToolResult | nil
function M.get_tool_result(id, messages)
  for idx = #messages, 1, -1 do
    local msg = messages[idx]
    local result = M.get_tool_result_data(msg)
    if result and result.tool_use_id == id then return result end
  end
end

---Given a tool invocation ID locate corresponding tool use message
---@param id string
---@param messages avante.HistoryMessage[]
---@return avante.HistoryMessage | nil
function M.get_tool_use_message(id, messages)
  for idx = #messages, 1, -1 do
    local msg = messages[idx]
    local use = M.get_tool_use_data(msg)
    if use and use.id == id then return msg end
  end
end

---Given a tool invocation ID locate corresponding tool result message
---@param id string
---@param messages avante.HistoryMessage[]
---@return avante.HistoryMessage | nil
function M.get_tool_result_message(id, messages)
  for idx = #messages, 1, -1 do
    local msg = messages[idx]
    local result = M.get_tool_result_data(msg)
    if result and result.tool_use_id == id then return msg end
  end
end

---@param message avante.HistoryMessage
---@return boolean
function M.is_thinking_message(message)
  local content = message.message.content
  return type(content) == "table" and (content[1].type == "thinking" or content[1].type == "redacted_thinking")
end

---@param message avante.HistoryMessage
---@return boolean
function M.is_tool_result_message(message) return M.get_tool_result_data(message) ~= nil end

---@param message avante.HistoryMessage
---@return boolean
function M.is_tool_use_message(message) return M.get_tool_use_data(message) ~= nil end

return M
