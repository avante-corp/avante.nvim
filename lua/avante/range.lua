---@class avante.Range
---@field start avante.RangeSelection start point
---@field finish avante.RangeSelection Selection end point
local Range = {}
Range.__index = Range

---@class avante.RangeSelection: table<string, integer>
---@field lnum number
---@field col number

---Create a selection range
---@param start avante.RangeSelection Selection start point
---@param finish avante.RangeSelection Selection end point
---@return avante.Range
function Range:new(start, finish)
  local instance = setmetatable({}, Range)
  instance.start = start
  instance.finish = finish
  return instance
end

---Check if the line and column are within the range
---@param lnum number Line number
---@param col number Column number
---@return boolean
function Range:contains(lnum, col)
  local start = self.start
  local finish = self.finish
  if lnum < start.lnum or lnum > finish.lnum then return false end
  if lnum == start.lnum and col < start.col then return false end
  if lnum == finish.lnum and col > finish.col then return false end
  return true
end

return Range
