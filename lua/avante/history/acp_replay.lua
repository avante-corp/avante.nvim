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
---@param role "user" | "assistant"
---@return boolean
local function is_text_message(message, role)
  return message ~= nil and message.message.role == role and type(message.message.content) == "string"
end

-- When continuing an ACP session, llm.lua sends the recent user messages wrapped in
-- <previous_user_message> tags, followed by one of these markers. The agent stores that whole
-- prompt as the user's turn, so imports unwrap it back to the message the user typed.
local CONTINUATION_MARKER =
  "<system_context>Continuing from previous session with %d+ recent user messages</system_context>"
local RECOVERY_MARKER =
  "<system_context>Continuing from previous ACP session with %d+ recent messages preserved for context</system_context>"

---Recovers the user's own message from a prompt avante built when continuing an ACP session.
---Text that isn't such a prompt is returned unchanged.
---@param text string
---@return string
function M.unwrap_avante_prompt(text)
  local newest_first
  if text:find(CONTINUATION_MARKER) then
    newest_first = true -- the continuation lists user messages newest first
  elseif text:find(RECOVERY_MARKER) then
    newest_first = false -- recovery lists the conversation oldest first
  else
    return text
  end

  local user_messages = {}
  for message in text:gmatch("<previous_user_message>(.-)</previous_user_message>") do
    table.insert(user_messages, message)
  end
  if #user_messages == 0 then return text end
  return newest_first and user_messages[1] or user_messages[#user_messages]
end

---@param message avante.HistoryMessage|nil
---@return table|nil
local function thinking_item(message)
  if not message or message.message.role ~= "assistant" or type(message.message.content) ~= "table" then return nil end
  local item = message.message.content[1]
  if type(item) == "table" and item.type == "thinking" then return item end
  return nil
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

  for _, update in ipairs(updates) do
    local kind = update.sessionUpdate
    local last_message = messages[#messages]

    if kind == "user_message_chunk" or kind == "agent_message_chunk" then
      local text = content_text(update.content)
      if text then
        local role = kind == "user_message_chunk" and "user" or "assistant"
        if is_text_message(last_message, role) then
          last_message.message.content = last_message.message.content .. text
        else
          table.insert(messages, Message:new(role, text, { is_user_submission = role == "user" }))
        end
      end
    elseif kind == "agent_thought_chunk" then
      local text = content_text(update.content)
      if text then
        local item = thinking_item(last_message)
        if item then
          item.thinking = item.thinking .. text
        else
          table.insert(messages, Message:new("assistant", { type = "thinking", thinking = text }))
        end
      end
    elseif (kind == "tool_call" or kind == "tool_call_update") and type(update.toolCallId) == "string" then
      local id = update.toolCallId
      local patch = vim.deepcopy(update)
      if type(patch.content) == "table" and next(patch.content) == nil then patch.content = nil end

      local message = tool_calls[id]
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
        tool_calls[id] = message
        table.insert(messages, message)
      end

      local status = message.acp_tool_call.status
      if (status == "completed" or status == "failed") and not resolved_tool_calls[id] then
        resolved_tool_calls[id] = true
        table.insert(
          messages,
          Message:new("assistant", {
            type = "tool_result",
            tool_use_id = id,
            content = nil,
            is_error = status == "failed",
          })
        )
      end
    end
  end

  -- The replay is history: no tool call is still running, whatever its last status was.
  for _, message in pairs(tool_calls) do
    message.is_calling = false
    message.state = "generated"
  end

  for _, message in ipairs(messages) do
    local content = message.message.content
    if message.message.role == "user" and type(content) == "string" then
      message.message.content = M.unwrap_avante_prompt(content)
    end
  end

  return messages
end

return M
