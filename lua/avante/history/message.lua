local Utils = require("avante.utils")

---@class avante.HistoryMessage
local M = {}
M.__index = M

---@class avante.HistoryMessage.Opts
---@field uuid? string
---@field turn_id? string
---@field order? integer
---@field state? avante.HistoryMessageState
---@field displayed_content? string
---@field original_content? AvanteLLMMessageContent
---@field selected_code? AvanteSelectedCode
---@field selected_filepaths? string[]
---@field is_calling? boolean
---@field is_dummy? boolean
---@field is_user_submission? boolean
---@field just_for_display? boolean
---@field is_usage_summary? boolean
---@field visible? boolean
---
---@param role "user" | "assistant"
---@param content AvanteLLMMessageContentItem
---@param opts? avante.HistoryMessage.Opts
---@return avante.HistoryMessage
function M:new(role, content, opts)
  ---@type AvanteLLMMessage
  local message = { role = role, content = type(content) == "string" and content or { content } }
  local obj = {
    message = message,
    uuid = Utils.uuid(),
    state = "generated",
    timestamp = Utils.get_timestamp(),
    is_user_submission = false,
    visible = true,
  }
  obj = vim.tbl_extend("force", obj, opts or {})
  return setmetatable(obj, M)
end

---Creates a new instance of synthetic (dummy) history message
---@param role "assistant" | "user"
---@param item AvanteLLMMessageContentItem
---@return avante.HistoryMessage
function M:new_synthetic(role, item) return M:new(role, item, { is_dummy = true }) end

---Creates a new instance of synthetic (dummy) history message attributed to the assistant
---@param item AvanteLLMMessageContentItem
---@return avante.HistoryMessage
function M:new_assistant_synthetic(item) return M:new_synthetic("assistant", item) end

---Creates a new instance of synthetic (dummy) history message attributed to the user
---@param item AvanteLLMMessageContentItem
---@return avante.HistoryMessage
function M:new_user_synthetic(item) return M:new_synthetic("user", item) end

---Updates content of a message as long as it is a simple text (or empty).
---@param new_content string
function M:update_content(new_content)
  assert(type(self.message.content) == "string", "can only update content of simple string messages")
  self.message.content = new_content
end

return M
