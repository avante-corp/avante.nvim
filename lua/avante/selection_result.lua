---@class avante.SelectionResult
---@field filepath string Filepath of the selected content
---@field filetype string Filetype of the selected content
---@field content string Selected content
---@field range avante.Range Selection range
local SelectionResult = {}
SelectionResult.__index = SelectionResult

-- Create a selection content and range
---@param filepath string Filepath of the selected content
---@param filetype string Filetype of the selected content
---@param content string Selected content
---@param range avante.Range Selection range
---@return avante.SelectionResult
function SelectionResult:new(filepath, filetype, content, range)
  local instance = setmetatable({}, self)
  instance.filepath = filepath
  instance.filetype = filetype
  instance.content = content
  instance.range = range
  return instance
end

return SelectionResult
