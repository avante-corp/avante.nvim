local Config = require("avante.config")
local Utils = require("avante.utils")

local AVANTE_PROMPT_INPUT_HL = "AvantePromptInputHL"

-- last one in entries is always to hold current input
---@type {input: string}[], integer
local entries, idx = {}, 0
---@type {input: string}[]
local filtered_entries = {}

---@class avante.utils.promptLogger
local M = {}

function M.init()
  vim.api.nvim_set_hl(0, AVANTE_PROMPT_INPUT_HL, {
    fg = "#ff7700",
    bg = "#333333",
    bold = true,
    italic = true,
    underline = true,
  })

  entries = {}
  local dir = Config.prompt_logger.log_dir
  local log_file = vim.fs.joinpath(dir, "avante_prompts.log")
  local file = io.open(log_file, "r")
  if file then
    ---@type string
    local content = file:read("*a"):gsub("\n$", "")
    file:close()

    local lines = vim.split(content, "\n", { plain = true })
    for _, line in ipairs(lines) do
      local ok, entry = pcall(vim.fn.json_decode, line)
      if ok and entry and entry.time and entry.input then table.insert(entries, entry) end
    end
  end
  table.insert(entries, { input = "" })
  idx = #entries - 1
  filtered_entries = entries
end

function M.log_prompt(request)
  if (Config.acp_providers or {})[Config.provider] then return end
  if request == "" then return end
  local log_dir = Config.prompt_logger.log_dir
  local log_file = vim.fs.joinpath(log_dir, "avante_prompts.log")

  if vim.fn.isdirectory(log_dir) == 0 then vim.fn.mkdir(log_dir, "p") end

  local entry = {
    time = Utils.get_timestamp(),
    input = request,
  }

  -- Remove any existing entries with the same input
  for i = #entries - 1, 1, -1 do
    if entries[i].input == entry.input then table.remove(entries, i) end
  end

  -- Add the new entry
  if #entries > 0 then
    table.insert(entries, #entries, entry)
    idx = #entries - 1
    filtered_entries = entries
  else
    table.insert(entries, entry)
  end

  local max = Config.prompt_logger.max_entries

  -- Left trim entries if the count exceeds max_entries
  -- We need to keep the last entry (current input) and trim from the beginning
  if max > 0 and #entries > max + 1 then
    -- Calculate how many entries to remove
    local to_remove = #entries - max - 1
    -- Remove oldest entries from the beginning
    for _ = 1, to_remove do
      table.remove(entries, 1)
    end
  end

  local file = io.open(log_file, "w")
  if file then
    -- Write all entries to the log file, except the last one
    for i = 1, #entries - 1, 1 do
      file:write(vim.fn.json_encode(entries[i]) .. "\n")
    end
    file:close()
  else
    vim.notify("Failed to log prompt", vim.log.levels.ERROR)
  end
end

---@param delta integer
---@return {input: string}?
local function _read_log(delta)
  -- index of array starts from 1 in lua, while this idx starts from 0
  idx = ((idx - delta) % #filtered_entries + #filtered_entries) % #filtered_entries

  return filtered_entries[idx + 1]
end

local function update_current_input()
  local user_input = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  if idx == #filtered_entries - 1 or filtered_entries[idx + 1].input ~= user_input then
    entries[#entries].input = user_input

    vim.fn.clearmatches()
    -- Apply filtering if there's user input
    if user_input and user_input ~= "" then
      filtered_entries = {}
      for i = 1, #entries - 1 do
        if entries[i].input:lower():find(user_input:lower(), 1, true) then
          table.insert(filtered_entries, entries[i])
        end
      end
      -- Add the current input as the last entry
      table.insert(filtered_entries, entries[#entries])

      vim.fn.matchadd(AVANTE_PROMPT_INPUT_HL, user_input)
    else
      filtered_entries = entries
    end
    idx = #filtered_entries - 1
  end
end

---@param delta integer
---@return fun()
function M.on_log_retrieve(delta)
  return function()
    update_current_input()
    local res = _read_log(delta)
    if not res or not res.input then
      vim.notify("No log entry found.", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(res.input, "\n", { plain = true }))
    vim.api.nvim_win_set_cursor(
      0,
      { vim.api.nvim_buf_line_count(0), #vim.api.nvim_buf_get_lines(0, -2, -1, false)[1] }
    )
  end
end

return M
