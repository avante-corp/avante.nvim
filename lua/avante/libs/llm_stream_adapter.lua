local HistoryMessage = require("avante.history.message")

local M = {}

function M.add_message(part, state, opts)
  local content = part.content
  local msg = HistoryMessage:new("assistant", content, {
    state = state,
    uuid = part.uuid,
    turn_id = part.turn_id,
    order = part.order,
    original_content = type(content) == "string" and content or nil,
  })
  msg.message.native = part.native
  msg.message.origin = part.origin
  part.uuid = msg.uuid
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
end

function M.finish_pending_messages(parts, opts, finish_tools, origin)
  for _, part in ipairs(parts) do
    local is_tool = type(part.content) == "table" and part.content.type == "tool_use"
    if not is_tool or finish_tools then
      part.origin = origin
      M.add_message(part, "generated", opts)
    end
  end
end

return M
