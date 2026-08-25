---Renders ACP form elicitations.
---
---This is how an agent asks the user a question mid-turn. claude-agent-acp
---maps its built-in `AskUserQuestion` tool onto `elicitation/create`, and
---*disables that tool entirely* unless the client advertises
---`elicitation.form` (see acp-agent.ts: `disallowedTools = elicitationSupport
---.form ? [] : ["AskUserQuestion"]`). So without this, the agent simply reports
---that no such tool is available.
---
---Schema shape produced by claude-agent-acp:
---  question_<n>          string with `oneOf` enum options   (single select)
---                        or array with `items.anyOf`        (multi select)
---  question_<n>_custom   free-text "Other", always optional
---
---The reply is `{action = "accept", content = { [field] = value }}`, or
---`decline` / `cancel`.
---
---Questions are rendered in a float rather than through `vim.ui.select`,
---because every common `vim.ui.select` implementation draws `prompt` as a
---window *title* -- single line, truncated. Agent questions are frequently a
---sentence or two, so they must live in the window body to wrap.

local Utils = require("avante.utils")

local M = {}

local CUSTOM_SUFFIX = "_custom"
local CUSTOM_LABEL = "Type my own answer…"
local SKIP_LABEL = "Skip this question"

local MAX_WIDTH = 84
local MIN_WIDTH = 40

---Wrap `text` to `width` columns on word boundaries.
---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
  local lines = {}
  if not text or text == "" then return lines end

  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    if paragraph == "" then
      table.insert(lines, "")
    else
      local current = ""
      for word in paragraph:gmatch("%S+") do
        if current == "" then
          current = word
        elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
          current = current .. " " .. word
        else
          table.insert(lines, current)
          current = word
        end
      end
      if current ~= "" then table.insert(lines, current) end
    end
  end
  return lines
end

---Options for a field, from either `oneOf` or `items.anyOf`.
---@param schema table
---@return table[] options, boolean multi_select
local function field_options(schema)
  if schema.oneOf then return schema.oneOf, false end
  if schema.items and schema.items.anyOf then return schema.items.anyOf, true end
  return {}, schema.type == "array"
end

---Question fields in a stable order, skipping the paired free-text fields.
---@param properties table
---@return string[]
local function ordered_question_fields(properties)
  local keys = {}
  for key, _ in pairs(properties or {}) do
    if not key:match(CUSTOM_SUFFIX .. "$") then table.insert(keys, key) end
  end
  -- Fields are named question_0, question_1, ... so numeric order is the
  -- author's intended order; pairs() would randomise it.
  table.sort(keys, function(a, b)
    local a_num = tonumber(a:match("(%d+)$"))
    local b_num = tonumber(b:match("(%d+)$"))
    if a_num and b_num then return a_num < b_num end
    return a < b
  end)
  return keys
end

---The text to show for a question.
---
---claude puts the question in `message` for a single-question form and in each
---field's `description` for a multi-question one. `title` is only a short
---header, so it must never win over the actual question.
---@param schema table
---@param message string|nil
---@return string question, string|nil header
local function question_text(schema, message)
  local question = schema.description or message or schema.title or "Choose an option"
  local header = schema.title
  if header == question then header = nil end
  return question, header
end

---Build the choice list for a question.
---@param schema table
---@param has_custom boolean
---@return table[]
local function build_choices(schema, has_custom)
  local options = field_options(schema)
  local choices = {}
  for _, option in ipairs(options) do
    table.insert(choices, {
      label = option.title or option.const,
      value = option.const,
      description = option.description,
    })
  end
  if has_custom then table.insert(choices, { label = CUSTOM_LABEL, custom = true }) end
  table.insert(choices, { label = SKIP_LABEL, skip = true })
  return choices
end

---Render the float's buffer lines.
---@param question string
---@param header string|nil
---@param choices table[]
---@param width integer
---@return string[] lines, integer[] choice_line_numbers 1-indexed
local function build_lines(question, header, choices, width)
  local lines = {}
  local choice_lines = {}

  if header then
    table.insert(lines, header)
    table.insert(lines, "")
  end

  for _, line in ipairs(wrap_text(question, width)) do
    table.insert(lines, line)
  end
  table.insert(lines, "")

  for index, choice in ipairs(choices) do
    table.insert(lines, string.format("  %d. %s", index, choice.label))
    choice_lines[index] = #lines
    if choice.description then
      -- Indent continuation so the description reads as part of the option.
      for _, line in ipairs(wrap_text(choice.description, width - 6)) do
        table.insert(lines, "     " .. line)
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  <CR> select   1-9 jump   <Esc> cancel")

  return lines, choice_lines
end

---Present one question in a float.
---@param schema table
---@param message string|nil
---@param has_custom boolean
---@param callback fun(value: any|nil, cancelled: boolean, is_custom: boolean|nil)
local function ask_float(schema, message, has_custom, callback)
  local question, header = question_text(schema, message)
  local choices = build_choices(schema, has_custom)
  local _, multi_select = field_options(schema)

  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, vim.o.columns - 8))
  local lines, choice_lines = build_lines(question, header, choices, width - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local height = math.min(#lines, math.max(10, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Agent question ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local answered = false
  local function finish(value, cancelled, is_custom)
    if answered then return end
    answered = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(value, cancelled, is_custom)
  end

  local function choose(index)
    local choice = choices[index]
    if not choice then return end
    if choice.skip then
      finish(nil, false)
      return
    end
    if choice.custom then
      -- Close first so the input prompt is not drawn under the float.
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      vim.ui.input({ prompt = (header or "Answer") .. ": " }, function(text)
        answered = true
        if text == nil or text == "" then
          callback(nil, false)
          return
        end
        callback(text, false, true)
      end)
      return
    end
    finish(multi_select and { choice.value } or choice.value, false)
  end

  --- Which choice the cursor is currently on.
  local function current_choice()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local best = 1
    for index, line in ipairs(choice_lines) do
      if line <= row then best = index end
    end
    return best
  end

  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true }) end

  map("<CR>", function() choose(current_choice()) end)
  map("<Esc>", function() finish(nil, true) end)
  map("q", function() finish(nil, true) end)
  for index = 1, math.min(9, #choices) do
    map(tostring(index), function() choose(index) end)
  end

  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      -- Closing the window any other way cancels, so the agent is never left
      -- waiting on a window that no longer exists.
      if not answered then
        answered = true
        callback(nil, true)
      end
    end,
  })

  if choice_lines[1] then vim.api.nvim_win_set_cursor(win, { choice_lines[1], 0 }) end
end

---Fallback for when there is no UI to draw into (headless, tests).
local function ask_select(schema, message, has_custom, callback)
  local question, header = question_text(schema, message)
  local choices = build_choices(schema, has_custom)
  local _, multi_select = field_options(schema)

  vim.ui.select(choices, {
    prompt = question,
    format_item = function(choice)
      if choice.description then return choice.label .. "  (" .. choice.description .. ")" end
      return choice.label
    end,
  }, function(choice)
    if choice == nil then
      callback(nil, true)
      return
    end
    if choice.skip then
      callback(nil, false)
      return
    end
    if choice.custom then
      vim.ui.input({ prompt = (header or "Answer") .. ": " }, function(text)
        if text == nil or text == "" then
          callback(nil, false)
          return
        end
        callback(text, false, true)
      end)
      return
    end
    callback(multi_select and { choice.value } or choice.value, false)
  end)
end

---Present an elicitation and reply.
---@param params table bridge `ui/elicitation` params
---@param reply fun(answer: table)
function M.prompt(params, reply)
  local mode = params.mode or {}
  local schema = mode.requestedSchema or mode.requested_schema or {}
  local properties = schema.properties or {}
  local fields = ordered_question_fields(properties)

  if #fields == 0 then
    -- A form we cannot render (url mode, empty schema). Declining is honest;
    -- the agent can then proceed without the answer.
    Utils.debug("Elicitation had no renderable fields; declining")
    reply({ action = "decline" })
    return
  end

  local has_ui = #vim.api.nvim_list_uis() > 0
  local ask = has_ui and ask_float or ask_select

  local content = {}
  local index = 1

  local function next_field()
    if index > #fields then
      if vim.tbl_isempty(content) then
        reply({ action = "decline" })
      else
        reply({ action = "accept", content = content })
      end
      return
    end

    local field = fields[index]
    index = index + 1
    local has_custom = properties[field .. CUSTOM_SUFFIX] ~= nil

    ask(properties[field], params.message, has_custom, function(value, cancelled, is_custom)
      if cancelled then
        reply({ action = "cancel" })
        return
      end
      if value ~= nil then
        if is_custom then
          content[field .. CUSTOM_SUFFIX] = value
        else
          content[field] = value
        end
      end
      -- Schedule so the next window is not opened from inside the previous
      -- window's close handler.
      vim.schedule(next_field)
    end)
  end

  vim.schedule(next_field)
end

M._ordered_question_fields = ordered_question_fields
M._field_options = field_options
M._wrap_text = wrap_text
M._question_text = question_text
M._build_lines = build_lines
M._build_choices = build_choices

return M
