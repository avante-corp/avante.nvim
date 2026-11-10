---@param s string
---@return string
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

---@param diff_text string
---@return string
local function diff2search_replace(diff_text)
  if not diff_text:match("@@%s*%-%d+,%d+%s%+") then return diff_text end

  local blocks = {}
  local pos = 1
  local len = #diff_text

  -- 解析每一个 @@ 块
  while pos <= len do
    -- 找到下一个 @@ 起始
    local start_at = diff_text:find("@@%s*%-%d+,%d+%s%+", pos)
    if not start_at then break end

    -- 找到该块结束位置（下一个 @@ 或文件末尾）
    local next_at = diff_text:find("@@%s*%-%d+,%d+%s%+", start_at + 1)
    local block_end = next_at and (next_at - 1) or len
    local block = diff_text:sub(start_at, block_end)

    -- 去掉首行的 @@ ... @@ 行
    local first_nl = block:find("\n")
    if first_nl then block = block:sub(first_nl + 1) end

    local search_lines, replace_lines = {}, {}
    for _, line in ipairs(split_lines(block)) do
      local first = line:sub(1, 1)
      if first == "-" then
        table.insert(search_lines, line:sub(2))
      elseif first == "+" then
        table.insert(replace_lines, line:sub(2))
      elseif first == " " then
        table.insert(search_lines, line:sub(2))
        table.insert(replace_lines, line:sub(2))
      end
    end

    local search = table.concat(search_lines, "\n")
    local replace = table.concat(replace_lines, "\n")

    table.insert(blocks, "------- SEARCH\n" .. trim(search) .. "\n=======\n" .. trim(replace) .. "\n+++++++ REPLACE")
    pos = block_end + 1
  end

  return table.concat(blocks, "\n\n")
end

return diff2search_replace
