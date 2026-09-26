local M = {}

---@param filename string|nil
---@param color_count integer
---@return integer
function M.color_index(filename, color_count)
  if color_count < 1 then return 1 end
  local thread_number = tonumber((filename or ""):match("(%d+)%.json$"))
  if not thread_number then return 1 end
  return ((thread_number - 1) % color_count) + 1
end

---@param history avante.ChatHistory|nil
---@return string
function M.display(history)
  local title = history and history.title or nil
  if type(title) == "string" then title = title:match("^%s*(.-)%s*$") end
  if title and title ~= "" and title ~= "untitled" then return title end

  local thread_number = history and history.filename and history.filename:match("(%d+)%.json$") or nil
  return thread_number and ("Untitled #" .. thread_number) or "Untitled"
end

return M
