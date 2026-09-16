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

---The question currently on screen, if any. See `M.prompt`.
local active = nil

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

---Screen rows `lines` need at `width` columns, with wrapping.
---@param lines string[]
---@param width integer
---@return integer
local function wrapped_height(lines, width)
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width)))
  end
  return math.max(1, rows)
end

---Ask for a free-text answer in a window that grows as it is typed.
---
---`vim.ui.input` draws in the cmdline: one line that neither wraps nor grows,
---so anything longer than the window scrolls sideways and a multi-line answer
---cannot be written at all. The question stays on screen here, as virtual
---lines that cannot be typed over.
---@param question string
---@param header string|nil
---@param callback fun(text: string|nil)
---@return integer win
local function input_float(question, header, callback)
  local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, vim.o.columns - 8))
  local inner = width - 2

  local context = {}
  if header then
    table.insert(context, header)
    table.insert(context, "")
  end
  for _, line in ipairs(wrap_text(question, inner)) do
    table.insert(context, line)
  end
  table.insert(context, "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local ns = vim.api.nvim_create_namespace("avante_elicitation_answer")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines_above = true,
    virt_lines = vim.tbl_map(function(line) return { { line, "Comment" } } end, context),
  })

  local max_answer_rows = math.max(3, vim.o.lines - #context - 8)
  local height = #context + 1
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Your answer ",
    title_pos = "center",
    footer = " <CR> send   i edit   q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function resize()
    if not vim.api.nvim_win_is_valid(win) then return end
    local rows = wrapped_height(vim.api.nvim_buf_get_lines(buf, 0, -1, false), inner)
    vim.api.nvim_win_set_height(win, #context + math.min(rows, max_answer_rows))
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = resize,
  })

  local done = false
  ---Close before answering, so the close handler below sees this as handled.
  local function finish(text)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(text)
  end

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    finish(text ~= "" and text or nil)
  end

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("n", "<CR>", submit)
  map("i", "<C-s>", function()
    vim.cmd("stopinsert")
    submit()
  end)
  map("n", "q", function() finish(nil) end)
  map("n", "<Esc>", function() finish(nil) end)

  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      if done then return end
      done = true
      callback(nil)
    end,
  })

  -- Scheduled: this runs from the question float's keymap, and `startinsert`
  -- issued from there is dropped, leaving the first keystroke to be read as a
  -- normal-mode command.
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then vim.cmd("startinsert") end
  end)

  return win
end

---Present one question in a float.
---@param schema table
---@param message string|nil
---@param has_custom boolean
---@param callback fun(value: any|nil, cancelled: boolean, is_custom: boolean|nil)
---@return fun() close the window this question is waiting in, whichever it is
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

  -- Follows the question into the free-text window, so a caller that wants to
  -- take the question away closes whichever one the user is looking at.
  local open_win = win

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
      -- Claim the answer before closing. Closing fires the cancel autocmd
      -- below, which told the agent the question had been dismissed before the
      -- user had typed a word; the answer then arrived as a second reply to an
      -- already-answered request, so it was ignored and the tool reported
      -- "Tool use aborted".
      answered = true
      -- Closed first so the answer window is not drawn under this one.
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      open_win = input_float(question, header, function(text)
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

  return function()
    if open_win and vim.api.nvim_win_is_valid(open_win) then vim.api.nvim_win_close(open_win, true) end
  end
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

  local replied = false

  ---Answer the agent, leaving a trace when nothing was answered.
  ---
  ---A dismissal is otherwise invisible from the sidebar: the agent reports it
  ---as an opaque tool failure ("Tool use aborted"), so without this a question
  ---that was asked and dropped looks like a bug rather than a choice.
  ---
  ---Answers once and only once: a request already answered cannot be revised,
  ---and a second reply to it is a protocol error.
  local session = {}

  local function finish(answer)
    if replied then return end
    replied = true
    if active == session then active = nil end
    if answer.action == "cancel" then
      Utils.warn("Agent question dismissed; the agent was told you did not answer")
    elseif answer.action == "decline" then
      Utils.info("Agent question skipped")
    end
    reply(answer)
  end

  ---Take this question off the screen because a newer one has arrived.
  ---
  ---Answered before the window closes, so closing does not read as the user
  ---dismissing a question they were never shown the end of.
  function session.dismiss()
    if not replied then
      replied = true
      reply({ action = "cancel" })
    end
    if session.close then session.close() end
  end

  -- One agent question on screen at a time. An agent whose tool call has hit
  -- its own deadline asks again, and each retry would otherwise stack another
  -- window on top of the last, every one of them waiting on a call that has
  -- already been abandoned.
  local previous = active
  active = session
  if previous then previous.dismiss() end

  local function next_field()
    if index > #fields then
      if vim.tbl_isempty(content) then
        finish({ action = "decline" })
      else
        finish({ action = "accept", content = content })
      end
      return
    end

    local field = fields[index]
    index = index + 1
    local has_custom = properties[field .. CUSTOM_SUFFIX] ~= nil

    session.close = ask(properties[field], params.message, has_custom, function(value, cancelled, is_custom)
      if cancelled then
        finish({ action = "cancel" })
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

M._wrapped_height = wrapped_height
M._ordered_question_fields = ordered_question_fields
M._field_options = field_options
M._wrap_text = wrap_text
M._question_text = question_text
M._build_lines = build_lines
M._build_choices = build_choices

return M
