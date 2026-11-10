---@alias avante.ui.LineSection table
---
---@class avante.ui.Line
---@field sections avante.ui.LineSection[]
local M = {}
M.__index = M

---@param sections avante.ui.LineSection[]
---@return avante.ui.Line
function M:new(sections)
  local this = setmetatable({}, M)
  this.sections = sections
  return this
end

---@param ns_id number
---@param bufnr number
---@param line number
---@param offset number | nil
function M:set_highlights(ns_id, bufnr, line, offset)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local col_start = offset or 0
  for _, section in ipairs(self.sections) do
    local text = section[1]
    local highlight = section[2]
    if type(highlight) == "function" then highlight = highlight() end
    if highlight then
      vim.highlight.range(bufnr, ns_id, highlight, { line, col_start }, { line, col_start + #text })
    end
    col_start = col_start + #text
  end
end

---@param section_index number
---@param offset number | nil
---@return number[]
function M:get_section_pos(section_index, offset)
  offset = offset or 0
  local col_start = 0
  for i = 1, section_index - 1 do
    if i == section_index then break end
    local section = self.sections[i]
    local text = type(section) == "table" and section[1] or section
    col_start = col_start + #text
  end

  local current = self.sections[section_index]
  local text = type(current) == "table" and current[1] or current
  return { offset + col_start, offset + col_start + #text }
end

function M:__tostring()
  local content = {}
  for _, section in ipairs(self.sections) do
    local text = section[1]
    table.insert(content, text)
  end
  return table.concat(content, "")
end

function M:__eq(other)
  if not other or type(other) ~= "table" or not other.sections then return false end
  return vim.deep_equal(self.sections, other.sections)
end

function M:bind_events(ns_id, bufnr, line) end

function M:unbind_events(bufnr, line) end

return M
