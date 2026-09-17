local Utils = require("avante.utils")
local Highlights = require("avante.highlights")
local Config = require("avante.config")
local Providers = require("avante.providers")
local api = vim.api
local fn = vim.fn

local SUGGESTION_NS = api.nvim_create_namespace("avante_suggestion")

---Represents contents of a single code block that can be placed between start and end rows
---@class avante.SuggestionItem
---@field id integer
---@field content string
---@field start_row integer
---@field end_row integer
---@field original_start_row integer

---A list of code blocks that form a complete set of edits to implement a recommended change
---@alias avante.SuggestionSet avante.SuggestionItem[]

---@class avante.SuggestionContext
---@field suggestions_list avante.SuggestionSet[]
---@field current_suggestion_idx number
---@field prev_doc? table

---@class avante.Suggestion
---@field id number
---@field augroup integer
---@field ignore_patterns table
---@field negate_patterns table
---@field _timer? uv.uv_timer_t
---@field _contexts table
---@field is_on_throttle boolean
local Suggestion = {}
Suggestion.__index = Suggestion

---@param id number
---@return avante.Suggestion
function Suggestion:new(id)
  local instance = setmetatable({}, self)
  local gitignore_path = Utils.get_project_root() .. "/.gitignore"
  local gitignore_patterns, gitignore_negate_patterns = Utils.parse_gitignore(gitignore_path)

  instance.id = id
  instance._timer = nil
  instance._contexts = {}
  instance.ignore_patterns = gitignore_patterns
  instance.negate_patterns = gitignore_negate_patterns
  instance.is_on_throttle = false
  if Config.behaviour.auto_suggestions then
    if not vim.g.avante_login or vim.g.avante_login == false then
      api.nvim_exec_autocmds("User", { pattern = Providers.env.REQUEST_LOGIN_PATTERN })
      vim.g.avante_login = true
    end
    instance:setup_autocmds()
  end
  return instance
end

function Suggestion:destroy()
  self:stop_timer()
  self:reset()
  self:delete_autocmds()
end

---Validates a potential suggestion item, ensuring that it has all needed data
---@param item table The suggestion item to validate.
---@return boolean `true` if valid, otherwise `false`.
local function validate_suggestion_item(item)
  return not not (
    item.content
    and type(item.content) == "string"
    and item.start_row
    and type(item.start_row) == "number"
    and item.end_row
    and type(item.end_row) == "number"
    and item.start_row <= item.end_row
  )
end

---Validates incoming raw suggestion data and builds a suggestion set, minimizing content
---@param raw_suggestions table[]
---@param current_content string[]
---@return avante.SuggestionSet
local function build_suggestion_set(raw_suggestions, current_content)
  ---@type avante.SuggestionSet
  local items = vim
    .iter(raw_suggestions)
    :map(function(s)
      --- 's' is a table generated from parsing json, it may not have
      --- all the expected keys or they may have bad values.
      if not validate_suggestion_item(s) then
        Utils.error("Provider returned malformed or invalid suggestion data", { once = true })
        return
      end

      local lines = vim.split(s.content, "\n")
      local new_start_row = s.start_row
      for i = s.start_row, s.start_row + #lines - 1 do
        if current_content[i] ~= lines[i - s.start_row + 1] then break end
        new_start_row = i + 1
      end
      local new_content_lines = new_start_row ~= s.start_row and vim.list_slice(lines, new_start_row - s.start_row + 1)
        or lines
      if #new_content_lines == 0 then return nil end
      new_content_lines = Utils.trim_line_numbers(new_content_lines)
      return {
        id = s.start_row,
        original_start_row = s.start_row,
        start_row = new_start_row,
        end_row = s.end_row,
        content = table.concat(new_content_lines, "\n"),
      }
    end)
    :filter(function(s) return s ~= nil end)
    :totable()

  --- sort the suggestions by start_row
  table.sort(items, function(a, b) return a.start_row < b.start_row end)
  return items
end

---Parses provider response and builds a list of suggestions
---@param full_response string
---@param bufnr integer
---@return avante.SuggestionSet[] | nil
local function build_suggestion_list(full_response, bufnr)
  -- Clean up markdown code blocks
  full_response = Utils.trim_think_content(full_response)
  full_response = full_response:gsub("<suggestions>\n(.-)\n</suggestions>", "%1")
  full_response = full_response:gsub("^```%w*\n(.-)\n```$", "%1")
  full_response = full_response:gsub("(.-)\n```\n?$", "%1")
  -- Remove everything before the first '[' to ensure we get just the JSON array
  full_response = full_response:gsub("^.-(%[.*)", "%1")
  -- Remove everything after the last ']' to ensure we get just the JSON array
  full_response = full_response:gsub("(.*%]).-$", "%1")

  local ok, suggestions_list = pcall(vim.json.decode, full_response)
  if not ok then
    Utils.error("Error while decoding suggestions: " .. full_response, { once = true, title = "Avante" })
    return
  end

  if not suggestions_list then
    Utils.info("No suggestions found", { once = true, title = "Avante" })
    return
  end
  if #suggestions_list ~= 0 and not vim.islist(suggestions_list[1]) then suggestions_list = { suggestions_list } end

  local current_lines = Utils.get_buf_lines(0, -1, bufnr)

  return vim
    .iter(suggestions_list)
    :map(function(suggestions) return build_suggestion_set(suggestions, current_lines) end)
    :totable()
end

function Suggestion:suggest()
  Utils.debug("suggesting")

  local ctx = self:ctx()
  local doc = Utils.get_doc()
  ctx.prev_doc = doc

  local bufnr = api.nvim_get_current_buf()
  local filetype = api.nvim_get_option_value("filetype", { buf = bufnr })
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  table.insert(lines, "")
  table.insert(lines, "")
  local code_content = table.concat(Utils.prepend_line_numbers(lines), "\n")

  local full_response = ""

  local provider = Providers[Config.auto_suggestions_provider or Config.provider]

  ---@type AvanteLLMMessage[]
  local llm_messages = {
    {
      role = "user",
      content = [[
<filepath>a.py</filepath>
<code>
L1: def fib
L2:
L3: if __name__ == "__main__":
L4:     # just pass
L5:     pass
</code>
      ]],
    },
    {
      role = "assistant",
      content = "ok",
    },
    {
      role = "user",
      content = '{"insertSpaces":true,"tabSize":4,"indentSize":4,"position":{"row":1,"col":7}}',
    },
    {
      role = "assistant",
      content = [[
<suggestions>
[
  [
    {
      "start_row": 1,
      "end_row": 1,
      "content": "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)"
    },
    {
      "start_row": 4,
      "end_row": 5,
      "content": "    fib(int(input()))"
    },
  ],
  [
    {
      "start_row": 1,
      "end_row": 1,
      "content": "def fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n        yield a\n        a, b = b, a + b"
    },
    {
      "start_row": 4,
      "end_row": 5,
      "content": "    list(fib(int(input())))"
    },
  ]
]
</suggestions>
          ]],
    },
  }

  local HistoryMessage = require("avante.history.message")
  local history_messages = vim
    .iter(llm_messages)
    :map(function(msg) return HistoryMessage:new(msg.role, msg.content) end)
    :totable()

  local diagnostics = Utils.lsp.get_diagnostics(bufnr)

  local Llm = require("avante.llm")
  Llm.stream({
    provider = provider,
    ask = true,
    diagnostics = vim.json.encode(diagnostics),
    selected_files = { { content = code_content, file_type = filetype, path = "" } },
    code_lang = filetype,
    history_messages = history_messages,
    instructions = vim.json.encode(doc),
    mode = "suggesting",
    on_start = function(_) end,
    on_chunk = function(chunk) full_response = full_response .. chunk end,
    on_stop = function(stop_opts)
      local err = stop_opts.error
      if err then
        Utils.error("Error while suggesting: " .. vim.inspect(err), { once = true, title = "Avante" })
        return
      end
      Utils.debug("full_response:", full_response)
      vim.schedule(function()
        local cursor_row, cursor_col = Utils.get_cursor_pos()
        if cursor_row ~= doc.position.row or cursor_col ~= doc.position.col then return end

        ctx.suggestions_list = build_suggestion_list(full_response, bufnr)
        ctx.current_suggestions_idx = 1

        self:show()
      end)
    end,
  })
end

function Suggestion:show()
  Utils.debug("showing suggestions, mode:", fn.mode())

  self:hide()

  if not fn.mode():match("^[iR]") then return end

  local ctx = self:ctx()

  local bufnr = api.nvim_get_current_buf()

  local suggestions = ctx.suggestions_list and ctx.suggestions_list[ctx.current_suggestions_idx] or nil

  Utils.debug("show suggestions", suggestions)

  if not suggestions then return end

  for _, suggestion in ipairs(suggestions) do
    local start_row = suggestion.start_row
    local end_row = suggestion.end_row
    local content = suggestion.content

    local lines = vim.split(content, "\n")

    local current_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local virt_text_win_col = 0
    local cursor_row, _ = Utils.get_cursor_pos()

    if start_row == end_row and start_row == cursor_row and current_lines[start_row] and #lines > 0 then
      if vim.startswith(lines[1], current_lines[start_row]) then
        virt_text_win_col = #current_lines[start_row]
        lines[1] = string.sub(lines[1], #current_lines[start_row] + 1)
      else
        local patch = vim.text.diff(
          current_lines[start_row],
          lines[1],
          ---@diagnostic disable-next-line: missing-fields
          { algorithm = "histogram", result_type = "indices", ctxlen = vim.o.scrolloff }
        )
        Utils.debug("patch", patch)
        if patch and #patch > 0 then
          virt_text_win_col = patch[1][3]
          lines[1] = string.sub(lines[1], patch[1][3] + 1)
        end
      end
    end

    local virt_lines = {}

    for _, line in ipairs(lines) do
      table.insert(virt_lines, { { line, Highlights.SUGGESTION } })
    end

    local extmark = {
      id = suggestion.id,
      virt_text_win_col = virt_text_win_col,
      virt_lines = virt_lines,
    }

    if virt_text_win_col > 0 then
      extmark.virt_text = { { lines[1], Highlights.SUGGESTION } }
      extmark.virt_lines = vim.list_slice(virt_lines, 2)
    end

    extmark.hl_mode = "combine"

    local buf_lines = Utils.get_buf_lines(0, -1, bufnr)
    local buf_lines_count = #buf_lines

    while buf_lines_count < end_row do
      api.nvim_buf_set_lines(bufnr, buf_lines_count, -1, false, { "" })
      buf_lines_count = buf_lines_count + 1
    end

    if virt_text_win_col > 0 or start_row - 2 < 0 then
      api.nvim_buf_set_extmark(bufnr, SUGGESTION_NS, start_row - 1, 0, extmark)
    else
      api.nvim_buf_set_extmark(bufnr, SUGGESTION_NS, start_row - 2, 0, extmark)
    end

    for i = start_row, end_row do
      if i == start_row and start_row == cursor_row and virt_text_win_col > 0 then goto continue end
      Utils.debug("add highlight", i - 1)
      local old_line = current_lines[i]
      api.nvim_buf_set_extmark(
        bufnr,
        SUGGESTION_NS,
        i - 1,
        0,
        { hl_group = Highlights.TO_BE_DELETED, end_row = i - 1, end_col = #old_line }
      )
      ::continue::
    end
  end
end

function Suggestion:is_visible()
  local extmarks = api.nvim_buf_get_extmarks(0, SUGGESTION_NS, 0, -1, { details = false })
  return #extmarks > 0
end

function Suggestion:hide() api.nvim_buf_clear_namespace(0, SUGGESTION_NS, 0, -1) end

function Suggestion:ctx()
  local bufnr = api.nvim_get_current_buf()
  local ctx = self._contexts[bufnr]
  if not ctx then
    ctx = {
      suggestions_list = {},
      current_suggestions_idx = 0,
      prev_doc = {},
      internal_move = false,
    }
    self._contexts[bufnr] = ctx
  end
  return ctx
end

function Suggestion:reset()
  self._timer = nil
  local bufnr = api.nvim_get_current_buf()
  self._contexts[bufnr] = nil
end

function Suggestion:stop_timer()
  if self._timer then
    pcall(function()
      self._timer:stop()
      self._timer:close()
    end)
    self._timer = nil
  end
end

function Suggestion:next()
  local ctx = self:ctx()
  if #ctx.suggestions_list == 0 then return end
  ctx.current_suggestions_idx = (ctx.current_suggestions_idx % #ctx.suggestions_list) + 1
  self:show()
end

function Suggestion:prev()
  local ctx = self:ctx()
  if #ctx.suggestions_list == 0 then return end
  ctx.current_suggestions_idx = ((ctx.current_suggestions_idx - 2 + #ctx.suggestions_list) % #ctx.suggestions_list) + 1
  self:show()
end

function Suggestion:dismiss()
  self:stop_timer()
  self:hide()
  self:reset()
end

function Suggestion:get_current_suggestion()
  local ctx = self:ctx()
  local suggestions = ctx.suggestions_list and ctx.suggestions_list[ctx.current_suggestions_idx] or nil
  if not suggestions then return nil end
  local cursor_row, _ = Utils.get_cursor_pos(0)
  Utils.debug("cursor row", cursor_row)
  for _, suggestion in ipairs(suggestions) do
    if suggestion.original_start_row - 1 <= cursor_row and suggestion.end_row >= cursor_row then return suggestion end
  end
end

function Suggestion:get_next_suggestion()
  local ctx = self:ctx()
  local suggestions = ctx.suggestions_list and ctx.suggestions_list[ctx.current_suggestions_idx] or nil
  if not suggestions then return nil end
  local cursor_row, _ = Utils.get_cursor_pos()
  local new_suggestions = {}
  for _, suggestion in ipairs(suggestions) do
    table.insert(new_suggestions, suggestion)
  end
  --- sort the suggestions by cursor distance
  table.sort(
    new_suggestions,
    function(a, b) return math.abs(a.start_row - cursor_row) < math.abs(b.start_row - cursor_row) end
  )
  --- get the closest suggestion to the cursor
  return new_suggestions[1]
end

function Suggestion:accept()
  local ctx = self:ctx()
  local suggestions = ctx.suggestions_list and ctx.suggestions_list[ctx.current_suggestions_idx] or nil
  Utils.debug("suggestions", suggestions)
  if not suggestions then
    if Config.mappings.suggestion and Config.mappings.suggestion.accept == "<Tab>" then
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Tab>", true, false, true), "n", true)
    end
    return
  end
  local suggestion = self:get_current_suggestion()
  Utils.debug("current suggestion", suggestion)
  if not suggestion then
    suggestion = self:get_next_suggestion()
    if suggestion then
      Utils.debug("next suggestion", suggestion)
      local lines = api.nvim_buf_get_lines(0, 0, -1, false)
      local first_line_row = suggestion.start_row
      if first_line_row > 1 then first_line_row = first_line_row - 1 end
      local line = lines[first_line_row]
      local col = 0
      if line ~= nil then col = #line end
      self:set_internal_move(true)
      api.nvim_win_set_cursor(0, { first_line_row, col })
      vim.cmd("normal! zz")
      vim.cmd("noautocmd startinsert")
      self:set_internal_move(false)
      return
    end
  end
  if not suggestion then return end
  api.nvim_buf_del_extmark(0, SUGGESTION_NS, suggestion.id)
  local bufnr = api.nvim_get_current_buf()
  local start_row = suggestion.start_row
  local end_row = suggestion.end_row
  local content = suggestion.content
  local lines = vim.split(content, "\n")
  local cursor_row, _ = Utils.get_cursor_pos()

  local replaced_line_count = end_row - start_row + 1

  if replaced_line_count > #lines then
    Utils.debug("delete lines")
    api.nvim_buf_set_lines(bufnr, start_row + #lines - 1, end_row, false, {})
    api.nvim_buf_set_lines(bufnr, start_row - 1, start_row + #lines, false, lines)
  else
    local start_line = start_row - 1
    local end_line = end_row
    if end_line < start_line then end_line = start_line end
    Utils.debug("replace lines", start_line, end_line, lines)
    api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
  end

  local row_diff = #lines - replaced_line_count

  ctx.suggestions_list[ctx.current_suggestions_idx] = vim
    .iter(suggestions)
    :filter(function(s) return s.start_row ~= suggestion.start_row end)
    :map(function(s)
      if s.start_row > suggestion.start_row then
        s.original_start_row = s.original_start_row + row_diff
        s.start_row = s.start_row + row_diff
        s.end_row = s.end_row + row_diff
      end
      return s
    end)
    :totable()

  local line_count = #lines

  local down_count = line_count - 1
  if start_row > cursor_row then down_count = down_count + 1 end

  local cursor_keys = string.rep("<Down>", down_count) .. "<End>"
  suggestions = ctx.suggestions_list and ctx.suggestions_list[ctx.current_suggestions_idx] or {}

  if #suggestions > 0 then self:set_internal_move(true) end
  api.nvim_feedkeys(api.nvim_replace_termcodes(cursor_keys, true, false, true), "n", false)
  if #suggestions > 0 then self:set_internal_move(false) end
end

function Suggestion:is_internal_move()
  local ctx = self:ctx()
  Utils.debug("is internal move", ctx and ctx.internal_move)
  return ctx and ctx.internal_move
end

function Suggestion:set_internal_move(internal_move)
  local ctx = self:ctx()
  if not internal_move then
    vim.schedule(function()
      Utils.debug("set internal move", internal_move)
      ctx.internal_move = internal_move
    end)
  else
    Utils.debug("set internal move", internal_move)
    ctx.internal_move = internal_move
  end
end

function Suggestion:setup_autocmds()
  self.augroup = api.nvim_create_augroup("avante_suggestion_" .. self.id, { clear = true })
  local last_cursor_pos = {}

  local check_for_suggestion = Utils.debounce(function()
    if self.is_on_throttle then return end
    local current_cursor_pos = api.nvim_win_get_cursor(0)
    if last_cursor_pos[1] == current_cursor_pos[1] and last_cursor_pos[2] == current_cursor_pos[2] then
      self.is_on_throttle = true
      vim.defer_fn(function() self.is_on_throttle = false end, Config.suggestion.throttle)
      self:suggest()
    end
  end, Config.suggestion.debounce)

  local function suggest_callback()
    if self.is_on_throttle then return end

    if self:is_internal_move() then return end

    if not vim.bo.buflisted then return end

    if vim.bo.buftype ~= "" then return end

    local full_path = api.nvim_buf_get_name(0)
    if
      Config.behaviour.auto_suggestions_respect_ignore
      and Utils.is_ignored(full_path, self.ignore_patterns, self.negate_patterns)
    then
      return
    end

    local ctx = self:ctx()

    if ctx.prev_doc and vim.deep_equal(ctx.prev_doc, Utils.get_doc()) then return end

    self:hide()
    last_cursor_pos = api.nvim_win_get_cursor(0)
    self._timer = check_for_suggestion()
  end

  api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    callback = suggest_callback,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = self.augroup,
    callback = function()
      if fn.mode():match("^[iR]") then suggest_callback() end
    end,
  })

  api.nvim_create_autocmd("CursorMovedI", {
    group = self.augroup,
    callback = suggest_callback,
  })

  api.nvim_create_autocmd("InsertLeave", {
    group = self.augroup,
    callback = function()
      last_cursor_pos = {}
      self:hide()
      self:reset()
    end,
  })
end

function Suggestion:delete_autocmds()
  if self.augroup then api.nvim_del_augroup_by_id(self.augroup) end
  self.augroup = nil
end

return Suggestion
