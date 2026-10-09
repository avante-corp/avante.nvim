local Message = require("avante.history.message")

local M = {}

local CONVERSATION_UPDATES = {
  user_message_chunk = true,
  agent_message_chunk = true,
  agent_thought_chunk = true,
  tool_call = true,
  tool_call_update = true,
}

---Whether a session update is part of the conversation (as opposed to plans, commands, modes, ...)
---@param update table
---@return boolean
function M.is_conversation_update(update)
  return type(update) == "table" and CONVERSATION_UPDATES[update.sessionUpdate] == true
end

---@param content any
---@return string|nil
local function content_text(content)
  if type(content) ~= "table" then return nil end
  if content.type == "text" and type(content.text) == "string" then return content.text end
  if content.type == "resource_link" then
    local name = content.name or content.uri
    if type(name) == "string" then return "@" .. name end
  end
  return nil
end

---@param message avante.HistoryMessage|nil
---@return table|nil
local function thinking_item(message)
  if not message or message.message.role ~= "assistant" or type(message.message.content) ~= "table" then return nil end
  local item = message.message.content[1]
  if type(item) == "table" and item.type == "thinking" then return item end
  return nil
end

---@class avante.acp.UpdateState
---@field messages avante.HistoryMessage[]
---@field tool_calls table<string, avante.HistoryMessage>
---@field resolved_tool_calls table<string, boolean>
---@field include_user? boolean

---@param state avante.acp.UpdateState
---@param role "user"|"assistant"
---@param text string
---@return avante.HistoryMessage
local function append_text(state, role, text)
  local last_message = state.messages[#state.messages]
  if last_message and last_message.message.role == role then
    local content = last_message.message.content
    if type(content) == "string" then
      last_message.message.content = content .. text
      return last_message
    end
    if type(content) == "table" then
      local appended = false
      for index, item in ipairs(content) do
        if type(item) == "string" then
          content[index] = item .. text
          appended = true
        elseif type(item) == "table" and item.type == "text" then
          item.text = item.text .. text
          appended = true
        end
      end
      if appended then return last_message end
    end
  end
  local message = Message:new(role, text, { is_user_submission = role == "user" })
  table.insert(state.messages, message)
  return message
end

---@param state avante.acp.UpdateState
---@param update table
---@return avante.HistoryMessage[] changed
---@return avante.HistoryMessage|nil tool_call
function M.apply_update(state, update)
  local kind = update.sessionUpdate
  if kind == "user_message_chunk" or kind == "agent_message_chunk" then
    if kind == "user_message_chunk" and not state.include_user then return {}, nil end
    local text = content_text(update.content)
    if not text then return {}, nil end
    local role = kind == "user_message_chunk" and "user" or "assistant"
    return { append_text(state, role, text) }, nil
  end

  if kind == "agent_thought_chunk" then
    local text = content_text(update.content)
    if not text then return {}, nil end
    local last_message = state.messages[#state.messages]
    local item = thinking_item(last_message)
    if item then
      item.thinking = item.thinking .. text
      return { last_message }, nil
    end
    local message = Message:new("assistant", { type = "thinking", thinking = text })
    table.insert(state.messages, message)
    return { message }, nil
  end

  if (kind ~= "tool_call" and kind ~= "tool_call_update") or type(update.toolCallId) ~= "string" then
    return {}, nil
  end

  local id = update.toolCallId
  local patch = vim.tbl_extend("force", {}, update)
  if type(patch.content) == "table" and next(patch.content) == nil then patch.content = nil end
  local changed = {}
  local message = state.tool_calls[id]
  if message then
    message.acp_tool_call = vim.tbl_deep_extend("force", message.acp_tool_call or {}, patch)
  else
    message = Message:new("assistant", {
      type = "tool_use",
      id = id,
      name = update.kind or update.title or "",
      input = update.rawInput or {},
    }, { uuid = id })
    message.acp_tool_call = patch
    if type(update.rawInput) == "table" and update.rawInput.description then
      message.tool_use_logs = { update.rawInput.description }
    end
    state.tool_calls[id] = message
    table.insert(state.messages, message)
  end
  table.insert(changed, message)

  local status = message.acp_tool_call.status
  if status == "pending" or status == "in_progress" then
    message.is_calling = true
    message.state = "generating"
  elseif status == "completed" or status == "failed" then
    message.is_calling = false
    message.state = "generated"
    if not state.resolved_tool_calls[id] then
      state.resolved_tool_calls[id] = true
      local result = Message:new("assistant", {
        type = "tool_result",
        tool_use_id = id,
        content = nil,
        is_error = status == "failed",
      })
      table.insert(state.messages, result)
      table.insert(changed, result)
    end
  end
  return changed, message
end

---Converts the session updates an agent replays during session/load into history messages,
---mirroring how live updates are turned into messages while streaming.
---@param updates table[]
---@return avante.HistoryMessage[]
function M.to_messages(updates)
  ---@type avante.HistoryMessage[]
  local messages = {}
  ---@type table<string, avante.HistoryMessage>
  local tool_calls = {}
  ---@type table<string, boolean>
  local resolved_tool_calls = {}

  local state = {
    messages = messages,
    tool_calls = tool_calls,
    resolved_tool_calls = resolved_tool_calls,
    include_user = true,
  }
  for _, update in ipairs(updates) do
    M.apply_update(state, update)
  end

  -- The replay is history: no tool call is still running, whatever its last status was.
  for _, message in pairs(tool_calls) do
    message.is_calling = false
    message.state = "generated"
  end

  return messages
end

return M
