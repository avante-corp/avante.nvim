local api = vim.api
local fn = vim.fn
local lsp = vim.lsp

local LRUCache = require("avante.utils.lru_cache")
local diff2search_replace = require("avante.utils.diff2search_replace")

---@class avante.utils: LazyUtilCore
---@field tokens avante.utils.tokens
---@field root avante.utils.root
---@field file avante.utils.file
---@field path avante.utils.path
---@field environment avante.utils.environment
---@field lsp avante.utils.lsp
---@field logger avante.utils.promptLogger
local M = {}

setmetatable(M, {
  __index = function(t, k)
    local ok, lazyutil = pcall(require, "lazy.core.util")
    if ok and lazyutil[k] then return lazyutil[k] end

    ---@diagnostic disable-next-line: no-unknown
    t[k] = require("avante.utils." .. k)
    return t[k]
  end,
})

---Check if a plugin is installed
---@param plugin string
---@return boolean
function M.has(plugin)
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if ok then return LazyConfig.plugins[plugin] ~= nil end

  local res, _ = pcall(require, plugin)
  return res
end

function M.is_win() return M.path.is_win() end

M.path_sep = M.path.SEP

---@return "linux" | "darwin" | "windows"
function M.get_os_name()
  local os_name = vim.uv.os_uname().sysname
  if os_name == "Linux" then
    return "linux"
  elseif os_name == "Darwin" then
    return "darwin"
  elseif os_name == "Windows_NT" then
    return "windows"
  else
    error("Unsupported operating system: " .. os_name)
  end
end

function M.get_system_info()
  local os_name = vim.uv.os_uname().sysname
  local os_version = vim.uv.os_uname().release
  local os_machine = vim.uv.os_uname().machine
  local lang = os.getenv("LANG")
  local shell = os.getenv("SHELL")

  local res = string.format(
    "- Platform: %s-%s-%s\n- Shell: %s\n- Language: %s\n- Current date: %s",
    os_name,
    os_version,
    os_machine,
    shell,
    lang,
    os.date("%Y-%m-%d")
  )

  local project_root = M.root.get()
  if project_root then res = res .. string.format("\n- Project root: %s", project_root) end

  local is_git_repo = vim.fn.isdirectory(".git") == 1
  if is_git_repo then res = res .. "\n- The user is operating inside a git repository" end

  return res
end

---@param input_cmd string
---@param shell_cmd string?
local function get_cmd_for_shell(input_cmd, shell_cmd)
  local shell = vim.o.shell:lower()
  local cmd = {}

  -- powershell then we can just run the cmd
  if shell:match("powershell") then
    cmd = { "powershell.exe", "-NoProfile", "-Command", input_cmd:gsub('"', "'") }
  elseif shell:match("pwsh") then
    cmd = { "pwsh.exe", "-NoProfile", "-Command", input_cmd:gsub('"', "'") }
  elseif fn.has("win32") > 0 then
    cmd = { "powershell.exe", "-NoProfile", "-Command", input_cmd:gsub('"', "'") }
  else
    -- linux and macos we will just do sh -c
    shell_cmd = shell_cmd or "sh -c"
    for _, cmd_part in ipairs(vim.split(shell_cmd, " ")) do
      table.insert(cmd, cmd_part)
    end
    table.insert(cmd, input_cmd)
  end

  return cmd
end

--- This function will run given shell command synchronously.
---@param input_cmd string
---@param shell_cmd string?
---@return vim.SystemCompleted
function M.shell_run(input_cmd, shell_cmd)
  local cmd = get_cmd_for_shell(input_cmd, shell_cmd)

  local result = vim.system(cmd, { text = true }):wait()

  return { stdout = result.stdout, code = result.code }
end

---@param input_cmd string
---@param shell_cmd string?
---@param on_complete fun(output: string, code: integer)
---@param cwd? string
---@param timeout? integer Timeout in milliseconds
function M.shell_run_async(input_cmd, shell_cmd, on_complete, cwd, timeout)
  local cmd = get_cmd_for_shell(input_cmd, shell_cmd)
  ---@type string[]
  local output = {}
  local timer = nil
  local completed = false

  -- Create a wrapper for on_complete to ensure it's only called once
  local function complete_once(out, code)
    if completed then return end
    completed = true

    -- Clean up timer if it exists
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end

    on_complete(out, code)
  end

  -- Start the job
  local job_id = fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if not data then return end
      vim.list_extend(output, data)
    end,
    on_stderr = function(_, data)
      if not data then return end
      vim.list_extend(output, data)
    end,
    on_exit = function(_, exit_code) complete_once(table.concat(output, "\n"), exit_code) end,
    cwd = cwd,
  })

  -- Set up timeout if specified
  if timeout and timeout > 0 then
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout, 0, function()
        vim.schedule(function()
          if not completed and job_id then
            -- Kill the job
            fn.jobstop(job_id)
            -- Complete with timeout error
            complete_once("Command timed out after " .. timeout .. "ms", 124)
          end
        end)
      end)
    end
  end
end

---@see https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/util/toggle.lua
---
---@alias _ToggleSet fun(state: boolean): nil
---@alias _ToggleGet fun(): boolean
---
---@class ToggleBind
---@field name string
---@field set _ToggleSet
---@field get _ToggleGet
---
---@class ToggleBind.wrap: ToggleBind
---@operator call:boolean

---@param toggle ToggleBind
function M.toggle_wrap(toggle)
  return setmetatable(toggle, {
    __call = function()
      toggle.set(not toggle.get())
      local state = toggle.get()
      if state then
        M.info("enabled: " .. toggle.name)
      else
        M.warn("disabled: " .. toggle.name)
      end
      return state
    end,
  }) --[[@as ToggleBind.wrap]]
end

-- Wrapper around vim.keymap.set that will
-- not create a keymap if a lazy key handler exists.
-- It will also set `silent` to true by default.
--
---@param mode string|string[] Mode short-name, see |nvim_set_keymap()|.
---                            Can also be list of modes to create mapping on multiple modes.
---@param lhs string           Left-hand side |{lhs}| of the mapping.
---@param rhs string|function  Right-hand side |{rhs}| of the mapping, can be a Lua function.
---
---@param opts? vim.keymap.set.Opts
function M.safe_keymap_set(mode, lhs, rhs, opts)
  ---@type boolean
  local ok
  ---@module "lazy.core.handler"
  local H

  ok, H = pcall(require, "lazy.core.handler")
  if not ok then
    M.debug("lazy.nvim is not available. Avante will use vim.keymap.set")
    vim.keymap.set(mode, lhs, rhs, opts)
    return
  end

  local Keys = H.handlers.keys
  ---@cast Keys LazyKeysHandler
  local modes = type(mode) == "string" and { mode } or mode
  ---@cast modes -string

  ---@param m string
  ---@diagnostic disable-next-line: undefined-field
  modes = vim.tbl_filter(function(m) return not (Keys and Keys.have and Keys:have(lhs, m)) end, modes)

  -- don't create keymap if a lazy keys handler exists
  if #modes > 0 then
    opts = opts or {}
    opts.silent = opts.silent ~= false
    if opts.remap and not vim.g.vscode then
      ---@diagnostic disable-next-line: no-unknown
      opts.remap = nil
    end
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

---@param str string
---@param opts? {suffix?: string, prefix?: string}
function M.trim(str, opts)
  local res = str
  if not opts then return res end
  if opts.suffix then
    res = res:sub(#res - #opts.suffix + 1) == opts.suffix and res:sub(1, #res - #opts.suffix) or res
  end
  if opts.prefix then res = res:sub(1, #opts.prefix) == opts.prefix and res:sub(#opts.prefix + 1) or res end
  return res
end

function M.in_visual_mode()
  local current_mode = fn.mode()
  return current_mode == "v" or current_mode == "V" or current_mode == ""
end

---Get the selected content and range in Visual mode
---@return avante.SelectionResult | nil Selected content and range
function M.get_visual_selection_and_range()
  if not M.in_visual_mode() then return nil end

  local Range = require("avante.range")
  local SelectionResult = require("avante.selection_result")

  -- Get the start and end positions of Visual mode
  local start_pos = fn.getpos("v")
  local end_pos = fn.getpos(".")

  -- Get the start and end line and column numbers
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]
  -- If the start point is after the end point, swap them
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end
  local content = "" -- luacheck: ignore
  local range = Range:new({ lnum = start_line, col = start_col }, { lnum = end_line, col = end_col })
  -- Check if it's a single-line selection
  if start_line == end_line then
    -- Get partial content of a single line
    local line = fn.getline(start_line)
    -- content = string.sub(line, start_col, end_col)
    content = line
  else
    -- Multi-line selection: Get all lines in the selection
    local lines = fn.getline(start_line, end_line)
    -- Extract partial content of the first line
    -- lines[1] = string.sub(lines[1], start_col)
    -- Extract partial content of the last line
    -- lines[#lines] = string.sub(lines[#lines], 1, end_col)
    -- Concatenate all lines in the selection into a string
    if type(lines) == "table" then
      content = table.concat(lines, "\n")
    else
      content = lines
    end
  end
  if not content then return nil end
  local filepath = fn.expand("%:p")
  local filetype = M.get_filetype(filepath)
  -- Return the selected content and range
  return SelectionResult:new(filepath, filetype, content, range)
end

---Wrapper around `api.nvim_buf_get_lines` which defaults to the current buffer
---@param start integer
---@param end_ integer
---@param buf integer?
---@return string[]
function M.get_buf_lines(start, end_, buf) return api.nvim_buf_get_lines(buf or 0, start, end_, false) end

---Get cursor row and column as (1, 0) based
---@param win_id integer?
---@return integer, integer
---@diagnostic disable-next-line: redundant-return-value
function M.get_cursor_pos(win_id) return unpack(api.nvim_win_get_cursor(win_id or 0)) end

---Check if the buffer is likely to have actionable conflict markers
---@param bufnr integer?
---@return boolean
function M.is_valid_buf(bufnr)
  bufnr = bufnr or 0
  return #vim.bo[bufnr].buftype == 0 and vim.bo[bufnr].modifiable
end

--- Check if a NUI container is valid:
--- 1. Container must exist
--- 2. Container must have a valid buffer number
--- 3. Container must have a valid window ID (optional, based on check_winid parameter)
--- Always returns a boolean value
---@param container NuiSplit | nil
---@param check_winid boolean? Whether to check window validity, defaults to false
---@return boolean
function M.is_valid_container(container, check_winid)
  -- Default check_winid to false if not specified
  if check_winid == nil then check_winid = false end

  -- First check if container exists
  if container == nil then return false end

  -- Check buffer validity
  if container.bufnr == nil or not api.nvim_buf_is_valid(container.bufnr) then return false end

  -- Check window validity if requested
  if check_winid then
    if container.winid == nil or not api.nvim_win_is_valid(container.winid) then return false end
  end

  return true
end

---@param name string?
---@return table
function M.get_hl(name)
  if not name then return {} end
  return api.nvim_get_hl(0, { name = name, link = false })
end

--- vendor from lazy.nvim for early access and override

---@param path string
---@return string
function M.norm(path) return M.path.normalize(path) end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.notify(msg, opts)
  if msg == nil then return end
  if vim.in_fast_event() then
    return vim.schedule(function() M.notify(msg, opts) end)
  end

  opts = opts or {}
  if type(msg) == "table" then
    ---@diagnostic disable-next-line: no-unknown
    msg = table.concat(vim.tbl_filter(function(line) return line or false end, msg), "\n")
  end
  ---@diagnostic disable-next-line: undefined-field
  if opts.stacktrace then
    ---@diagnostic disable-next-line: undefined-field
    msg = msg .. M.pretty_trace({ level = opts.stacklevel or 2 })
  end
  local lang = opts.lang or "markdown"
  ---@diagnostic disable-next-line: undefined-field
  local n = opts.once and vim.notify_once or vim.notify
  n(msg, opts.level or vim.log.levels.INFO, {
    on_open = function(win)
      pcall(function() vim.treesitter.language.add("markdown") end)
      vim.wo[win].conceallevel = 3
      vim.wo[win].concealcursor = ""
      vim.wo[win].spell = false
      local buf = api.nvim_win_get_buf(win)
      if not pcall(vim.treesitter.start, buf, lang) then
        vim.bo[buf].filetype = lang
        vim.bo[buf].syntax = lang
      end
    end,
    title = opts.title or "Avante",
  })
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.error(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.ERROR
  M.notify(msg, opts)
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.info(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.INFO
  M.notify(msg, opts)
end

---@param msg string|string[]
---@param opts? LazyNotifyOpts
function M.warn(msg, opts)
  opts = opts or {}
  opts.level = vim.log.levels.WARN
  M.notify(msg, opts)
end

-- Debug log file handle (shared across calls, stored outside M to avoid __index)
local debug_log_file = nil

function M.debug(...)
  if not require("avante.config").debug then return end

  local args = { ... }
  if #args == 0 then return end

  -- Get caller information
  local info = debug.getinfo(2, "Sl")
  local caller_source = info.source:match("@(.+)$") or "unknown"
  local caller_module = caller_source:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")

  local timestamp = M.get_timestamp()
  local parts = {
    "[" .. timestamp .. "] [AVANTE] [DEBUG] [" .. caller_module .. ":" .. info.currentline .. "]",
  }

  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      table.insert(parts, arg)
    else
      table.insert(parts, vim.inspect(arg))
    end
  end

  local message = table.concat(parts, " ") .. "\n"

  -- Write to log file instead of printing
  if not debug_log_file then
    debug_log_file = io.open("/tmp/avante-debug.log", "a")
  end
  if debug_log_file then
    debug_log_file:write(message)
    debug_log_file:flush()
  end
end

function M.tbl_indexof(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then return i end
  end
  return nil
end

function M.update_win_options(winid, opt_name, key, value)
  local cur_opt_value = api.nvim_get_option_value(opt_name, { win = winid })

  if cur_opt_value:find(key .. ":") then
    cur_opt_value = cur_opt_value:gsub(key .. ":[^,]*", key .. ":" .. value)
  else
    if #cur_opt_value > 0 then cur_opt_value = cur_opt_value .. "," end
    cur_opt_value = cur_opt_value .. key .. ":" .. value
  end

  api.nvim_set_option_value(opt_name, cur_opt_value, { win = winid })
end

function M.get_win_options(winid, opt_name, key)
  local cur_opt_value = api.nvim_get_option_value(opt_name, { win = winid })
  if not cur_opt_value then return end
  local pieces = vim.split(cur_opt_value, ",")
  for _, piece in ipairs(pieces) do
    local kv_pair = vim.split(piece, ":")
    if kv_pair[1] == key then return kv_pair[2] end
  end
end

function M.get_winid(bufnr)
  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then return winid end
  end
end

function M.unlock_buf(bufnr)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = true
end

function M.lock_buf(bufnr)
  if bufnr == api.nvim_get_current_buf() then vim.cmd("noautocmd stopinsert") end
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---@param winnr? number
---@return nil
function M.scroll_to_end(winnr)
  winnr = winnr or 0
  local bufnr = api.nvim_win_get_buf(winnr)
  local lnum = api.nvim_buf_line_count(bufnr)
  local last_line = api.nvim_buf_get_lines(bufnr, -2, -1, true)[1]
  api.nvim_win_set_cursor(winnr, { lnum, api.nvim_strwidth(last_line) })
end

---@param bufnr nil|integer
---@return nil
function M.buf_scroll_to_end(bufnr)
  for _, winnr in ipairs(M.buf_list_wins(bufnr or 0)) do
    M.scroll_to_end(winnr)
  end
end

---@param bufnr nil|integer
---@return integer[]
function M.buf_list_wins(bufnr)
  local wins = {}

  if not bufnr or bufnr == 0 then bufnr = api.nvim_get_current_buf() end

  for _, winnr in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(winnr) and api.nvim_win_get_buf(winnr) == bufnr then table.insert(wins, winnr) end
  end

  return wins
end

local sidebar_buffer_var_name = "is_avante_sidebar_buffer"

function M.mark_as_sidebar_buffer(bufnr) api.nvim_buf_set_var(bufnr, sidebar_buffer_var_name, true) end

function M.is_sidebar_buffer(bufnr)
  local ok, v = pcall(api.nvim_buf_get_var, bufnr, sidebar_buffer_var_name)
  if not ok then return false end
  return v == true
end

function M.trim_spaces(s) return s:match("^%s*(.-)%s*$") end

---Remove trailing spaces from each line in a string
---@param content string The content to process
---@return string The content with trailing spaces removed from each line
function M.remove_trailing_spaces(content)
  if not content then return content end
  local lines = vim.split(content, "\n")
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("%s+$", "")
  end
  return table.concat(lines, "\n")
end

function M.fallback(v, default_value) return type(v) == "nil" and default_value or v end

---Join URL parts together, handling slashes correctly
---@param ... string URL parts to join
---@return string Joined URL
function M.url_join(...)
  local parts = { ... }
  local result = parts[1] or ""

  for i = 2, #parts do
    local part = parts[i]
    if not part or part == "" then goto continue end

    -- Remove trailing slash from result if present
    if result:sub(-1) == "/" then result = result:sub(1, -2) end

    -- Remove leading slash from part if present
    if part:sub(1, 1) == "/" then part = part:sub(2) end

    -- Join with slash
    result = result .. "/" .. part

    ::continue::
  end

  if result:sub(-1) == "/" then result = result:sub(1, -2) end

  return result
end

-- luacheck: push no max comment line length
---@param type_name "'nil'" | "'number'" | "'string'" | "'boolean'" | "'table'" | "'function'" | "'thread'" | "'userdata'" | "'list'" | '"map"'
---@return boolean
function M.is_type(type_name, v)
  ---@diagnostic disable-next-line: deprecated
  local islist = vim.islist or vim.tbl_islist
  if type_name == "list" then return islist(v) end

  if type_name == "map" then return type(v) == "table" and not islist(v) end

  return type(v) == type_name
end
-- luacheck: pop

---@param text string
---@return string
function M.get_indentation(text)
  if not text then return "" end
  return text:match("^%s*") or ""
end

function M.trim_space(text)
  if not text then return text end
  return text:gsub("%s*", "")
end

function M.trim_escapes(text)
  if not text then return text end
  local res = text
    :gsub("//n", "/n")
    :gsub("//r", "/r")
    :gsub("//t", "/t")
    :gsub('/"', '"')
    :gsub('\\"', '"')
    :gsub("\\n", "\n")
    :gsub("\\r", "\r")
    :gsub("\\t", "\t")
  return res
end

---@param original_lines string[]
---@param target_lines string[]
---@param compare_fn fun(line_a: string, line_b: string): boolean
---@return integer | nil start_line
---@return integer | nil end_line
function M.try_find_match(original_lines, target_lines, compare_fn)
  local start_line, end_line
  for i = 1, #original_lines - #target_lines + 1 do
    local match = true
    for j = 1, #target_lines do
      if not compare_fn(original_lines[i + j - 1], target_lines[j]) then
        match = false
        break
      end
    end
    if match then
      start_line = i
      end_line = i + #target_lines - 1
      break
    end
  end
  return start_line, end_line
end

---@param original_lines string[]
---@param target_lines string[]
---@return integer | nil start_line
---@return integer | nil end_line
function M.fuzzy_match(original_lines, target_lines)
  local start_line, end_line
  ---exact match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return line_a == line_b end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---fuzzy match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim(line_a, { suffix = " \t" }) == M.trim(line_b, { suffix = " \t" }) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim_space match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim_space(line_a) == M.trim_space(line_b) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim slashes match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return line_a == M.trim_escapes(line_b) end
  )
  if start_line ~= nil and end_line ~= nil then return start_line, end_line end
  ---trim slashes and trim_space match
  start_line, end_line = M.try_find_match(
    original_lines,
    target_lines,
    function(line_a, line_b) return M.trim_space(line_a) == M.trim_space(M.trim_escapes(line_b)) end
  )
  return start_line, end_line
end

function M.relative_path(absolute)
  local project_root = M.get_project_root()
  return M.make_relative_path(absolute, project_root)
end

function M.get_doc()
  local absolute = api.nvim_buf_get_name(0)
  local params = lsp.util.make_position_params(0, "utf-8")

  local position = {
    row = params.position.line + 1,
    col = params.position.character,
  }

  local doc = {
    uri = params.textDocument.uri,
    version = api.nvim_buf_get_var(0, "changedtick"),
    relativePath = M.relative_path(absolute),
    insertSpaces = vim.o.expandtab,
    tabSize = fn.shiftwidth(),
    indentSize = fn.shiftwidth(),
    position = position,
  }

  return doc
end

---Prepends line numbers to each line in a list of strings.
---@param lines string[] The lines of content to prepend line numbers to.
---@param start_line? integer The starting line number. Defaults to 1.
---@return string[] A new list of strings with line numbers prepended.
function M.prepend_line_numbers(lines, start_line)
  start_line = start_line or 1
  return vim
    .iter(lines)
    :enumerate()
    :map(function(i, line) return string.format("L%d: %s", i + start_line, line) end)
    :totable()
end

---Iterates through a list of strings and removes prefixes in form of "L<number>: " from them
---@param content string[]
---@return string[]
function M.trim_line_numbers(content)
  return vim.iter(content):map(function(line) return (line:gsub("^L%d+: ", "")) end):totable()
end

---Debounce a function call
---@param func fun(...) function to debounce
---@param delay integer delay in milliseconds
---@return fun(...): uv.uv_timer_t debounced function
function M.debounce(func, delay)
  local timer = nil

  return function(...)
    local args = { ... }

    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end

    timer = vim.defer_fn(function()
      func(unpack(args))
      timer = nil
    end, delay)

    return timer
  end
end

---Creates a double-tap detector for a key
---Tracks keypresses and executes callback only on double-tap within timeout window
---@param callback function Function to call on double-tap
---@param timeout integer Time window for double-tap in milliseconds (default 300)
---@param bufnr integer|nil Optional buffer number to scope the state to
---@return function Handler function for the key press
---@return table State object with is_expr_mode flag for insert mode mappings
function M.create_double_tap_handler(callback, timeout, bufnr)
  timeout = timeout or 300
  local state = {
    last_press_time = 0,
    timer = nil,
    pending_newline = false,
  }

  local handler = function(...)
    local args = { ... }
    local current_time = vim.loop.now()
    local time_diff = current_time - state.last_press_time

    -- Clean up existing timer
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
      state.timer:close()
      state.timer = nil
    end

    -- Check if this is a double-tap (second press within timeout)
    if time_diff < timeout and state.last_press_time > 0 then
      -- Double-tap detected! Execute callback and reset state
      state.last_press_time = 0
      state.pending_newline = false
      callback(unpack(args))
      return "" -- Return empty string for expr mapping
    else
      -- First press, record timestamp and mark pending newline
      state.last_press_time = current_time
      state.pending_newline = true
      
      -- Set up timer to insert the pending newline after timeout
      state.timer = vim.defer_fn(function()
        if state.pending_newline then
          state.pending_newline = false
          -- Insert the newline that was suppressed on first tap
          vim.schedule(function()
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
              local mode = vim.api.nvim_get_mode().mode
              if mode == "i" or mode == "ic" then
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
              end
            end
          end)
        end
        state.last_press_time = 0
        state.timer = nil
      end, timeout)
      
      return "" -- Suppress immediate newline, will be inserted by timer if not double-tapped
    end
  end
  
  return handler
end

---Throttle a function call
---@param func fun(...) function to throttle
---@param delay integer delay in milliseconds
---@return fun(...): nil throttled function
function M.throttle(func, delay)
  local timer = nil

  return function(...)
    if timer then return end

    local args = { ... }

    timer = vim.defer_fn(function()
      func(unpack(args))
      timer = nil
    end, delay)
  end
end

function M.winline(winid)
  -- If the winid is not provided, then line number should be 1, so that it can land on the first line
  if not vim.api.nvim_win_is_valid(winid) then return 1 end

  local line = 1
  vim.api.nvim_win_call(winid, function() line = fn.winline() end)

  return line
end

function M.get_project_root() return M.root.get() end

function M.is_same_file_ext(target_ext, filepath)
  local ext = fn.fnamemodify(filepath, ":e")
  if (target_ext == "tsx" and ext == "ts") or (target_ext == "ts" and ext == "tsx") then return true end
  if (target_ext == "jsx" and ext == "js") or (target_ext == "js" and ext == "jsx") then return true end
  return ext == target_ext
end

-- Get recent filepaths in the same project and same file ext
---@param limit? integer
---@param filenames? string[]
---@param same_file_ext? boolean
---@return string[]
function M.get_recent_filepaths(limit, filenames, same_file_ext)
  local project_root = M.get_project_root()
  local current_ext = fn.expand("%:e")
  local oldfiles = vim.v.oldfiles
  local recent_files = {}

  for _, file in ipairs(oldfiles) do
    if vim.startswith(file, project_root) then
      local has_ext = file:match("%.%w+$")
      if not has_ext then goto continue end
      if same_file_ext then
        if not M.is_same_file_ext(current_ext, file) then goto continue end
      end
      if filenames and #filenames > 0 then
        for _, filename in ipairs(filenames) do
          if file:find(filename) then table.insert(recent_files, file) end
        end
      else
        table.insert(recent_files, file)
      end
      if #recent_files >= (limit or 10) then break end
    end
    ::continue::
  end

  return recent_files
end

local function pattern_to_lua(pattern)
  local lua_pattern = pattern:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
  lua_pattern = lua_pattern:gsub("%*%*/", ".-/")
  lua_pattern = lua_pattern:gsub("%*", "[^/]*")
  lua_pattern = lua_pattern:gsub("%?", ".")
  if lua_pattern:sub(-1) == "/" then lua_pattern = lua_pattern .. ".*" end
  return lua_pattern
end

function M.parse_gitignore(gitignore_path)
  local ignore_patterns = {}
  local negate_patterns = {}
  local file = io.open(gitignore_path, "r")
  if not file then return ignore_patterns, negate_patterns end

  for line in file:lines() do
    if line:match("%S") and not line:match("^#") then
      local trimmed_line = line:match("^%s*(.-)%s*$")
      if trimmed_line:sub(1, 1) == "!" then
        table.insert(negate_patterns, pattern_to_lua(trimmed_line:sub(2)))
      else
        table.insert(ignore_patterns, pattern_to_lua(trimmed_line))
      end
    end
  end

  file:close()
  ignore_patterns = vim.list_extend(ignore_patterns, { "%.git", "%.worktree", "__pycache__", "node_modules" })
  return ignore_patterns, negate_patterns
end

-- @param file string
-- @param ignore_patterns string[]
-- @param negate_patterns string[]
-- @return boolean
function M.is_ignored(file, ignore_patterns, negate_patterns)
  for _, pattern in ipairs(negate_patterns) do
    if file:match(pattern) then return false end
  end
  for _, pattern in ipairs(ignore_patterns) do
    if file:match(pattern .. "/") or file:match(pattern .. "$") then return true end
  end
  return false
end

---@param options { directory: string, add_dirs?: boolean, max_depth?: integer }
---@return string[]
function M.scan_directory(options)
  local cmd_supports_max_depth = true
  local cmd = (function()
    if vim.fn.executable("rg") == 1 then
      local cmd = {
        "rg",
        "--files",
        "--color",
        "never",
        "--no-require-git",
        "--no-ignore-parent",
        "--hidden",
        "--glob",
        "!.git/",
      }

      if options.max_depth ~= nil then vim.list_extend(cmd, { "--max-depth", options.max_depth }) end
      table.insert(cmd, options.directory)

      return cmd
    end

    -- fd is called 'fdfind' on Debian/Ubuntu due to naming conflicts
    local fd_executable = vim.fn.executable("fd") == 1 and "fd"
      or (vim.fn.executable("fdfind") == 1 and "fdfind" or nil)
    if fd_executable then
      local cmd = {
        fd_executable,
        "--type",
        "f",
        "--color",
        "never",
        "--no-require-git",
        "--hidden",
        "--exclude",
        ".git",
      }

      if options.max_depth ~= nil then vim.list_extend(cmd, { "--max-depth", options.max_depth }) end
      vim.list_extend(cmd, { "--base-directory", options.directory })

      return cmd
    end
  end)()

  if not cmd then
    if M.path_exists(M.join_paths(options.directory, ".git")) and vim.fn.executable("git") == 1 then
      if vim.fn.has("win32") == 1 then
        cmd = {
          "powershell",
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          string.format(
            "Push-Location '%s'; (git ls-files --exclude-standard), (git ls-files --exclude-standard --others)",
            options.directory:gsub("/", "\\")
          ),
        }
      else
        cmd = {
          "bash",
          "-c",
          string.format("cd %s && git ls-files -co --exclude-standard", options.directory),
        }
      end
      cmd_supports_max_depth = false
    else
      M.error("No search command found, please install fd or fdfind or rg")
      return {}
    end
  end

  local files = vim.fn.systemlist(cmd)

  files = vim
    .iter(files)
    :map(function(file)
      if not M.is_absolute_path(file) then return M.join_paths(options.directory, file) end
      return file
    end)
    :totable()

  if options.max_depth ~= nil and not cmd_supports_max_depth then
    files = vim
      .iter(files)
      :filter(function(file)
        local base_dir = options.directory
        if base_dir:sub(-2) == "/." then base_dir = base_dir:sub(1, -3) end
        local rel_path = M.make_relative_path(file, base_dir)
        local pieces = vim.split(rel_path, "/")
        return #pieces <= options.max_depth
      end)
      :totable()
  end

  if options.add_dirs then
    local dirs = {}
    local dirs_seen = {}
    for _, file in ipairs(files) do
      local dir = M.get_parent_path(file)
      if not dirs_seen[dir] then
        table.insert(dirs, dir)
        dirs_seen[dir] = true
      end
    end
    files = vim.list_extend(dirs, files)
  end

  return files
end

function M.get_parent_path(filepath)
  if filepath == nil then error("filepath cannot be nil") end
  if filepath == "" then return "" end
  local is_abs = M.is_absolute_path(filepath)
  if filepath:sub(-1) == M.path_sep then filepath = filepath:sub(1, -2) end
  if filepath == "" then return "" end
  local parts = vim.split(filepath, M.path_sep)
  local parent_parts = vim.list_slice(parts, 1, #parts - 1)
  local res = table.concat(parent_parts, M.path_sep)
  if res == "" then
    if is_abs then return M.path_sep end
    return "."
  end
  return res
end

function M.make_relative_path(filepath, base_dir) return M.path.relative(base_dir, filepath, false) end

function M.is_absolute_path(path) return M.path.is_absolute(path) end

function M.to_absolute_path(path)
  if not path or path == "" then return path end
  if path:sub(1, 1) == "/" or path:sub(1, 7) == "term://" then return path end
  return M.join_paths(M.get_project_root(), path)
end

function M.join_paths(...)
  local paths = { ... }
  local result = paths[1] or ""
  for i = 2, #paths do
    local path = paths[i]
    if path == nil or path == "" then goto continue end

    if M.is_absolute_path(path) then
      result = path
      goto continue
    end

    result = result == "" and path or M.path.join(result, path)
    ::continue::
  end
  return M.norm(result)
end

function M.path_exists(path) return M.path.is_exist(path) end

function M.is_first_letter_uppercase(str) return string.match(str, "^[A-Z]") ~= nil end

---@param content string
---@return { new_content: string, enable_project_context: boolean, enable_diagnostics: boolean }
function M.extract_mentions(content)
  -- if content contains @codebase, enable project context and remove @codebase
  local new_content = content
  local enable_project_context = false
  local enable_diagnostics = false
  if content:match("@codebase") then
    enable_project_context = true
    new_content = content:gsub("@codebase", "")
  end
  if content:match("@diagnostics") then enable_diagnostics = true end
  return {
    new_content = new_content,
    enable_project_context = enable_project_context,
    enable_diagnostics = enable_diagnostics,
  }
end

---@return AvanteMention[]
function M.get_mentions()
  return {
    {
      description = "codebase",
      command = "codebase",
      details = "repo map",
    },
    {
      description = "diagnostics",
      command = "diagnostics",
      details = "diagnostics",
    },
  }
end

---@return AvanteMention[]
function M.get_chat_mentions()
  local mentions = M.get_mentions()

  table.insert(mentions, {
    description = "file",
    command = "file",
    details = "add files...",
    callback = function(sidebar) sidebar.file_selector:open() end,
  })

  table.insert(mentions, {
    description = "quickfix",
    command = "quickfix",
    details = "add files in quickfix list to chat context",
    callback = function(sidebar) sidebar.file_selector:add_quickfix_files() end,
  })

  table.insert(mentions, {
    description = "buffers",
    command = "buffers",
    details = "add open buffers to the chat context",
    callback = function(sidebar) sidebar.file_selector:add_buffer_files() end,
  })

  return mentions
end

---@return AvanteShortcut[]
function M.get_shortcuts()
  local Config = require("avante.config")

  -- Built-in shortcuts
  local builtin_shortcuts = {
    {
      name = "refactor",
      description = "Refactor code with best practices",
      details = "Automatically refactor code to improve readability, maintainability, and follow best practices while preserving functionality",
      prompt = "Please refactor this code following best practices, improving readability and maintainability while preserving functionality.",
    },
    {
      name = "test",
      description = "Generate unit tests",
      details = "Create comprehensive unit tests covering edge cases, error scenarios, and various input conditions",
      prompt = "Please generate comprehensive unit tests for this code, covering edge cases and error scenarios.",
    },
    {
      name = "document",
      description = "Add documentation",
      details = "Add clear and comprehensive documentation including function descriptions, parameter explanations, and usage examples",
      prompt = "Please add clear and comprehensive documentation to this code, including function descriptions, parameter explanations, and usage examples.",
    },
    {
      name = "debug",
      description = "Add debugging information",
      details = "Add comprehensive debugging information including logging statements, error handling, and debugging utilities",
      prompt = "Please add comprehensive debugging information to this code, including logging statements, error handling, and debugging utilities.",
    },
    {
      name = "optimize",
      description = "Optimize performance",
      details = "Analyze and optimize code for better performance considering time complexity, memory usage, and algorithmic improvements",
      prompt = "Please analyze and optimize this code for better performance, considering time complexity, memory usage, and algorithmic improvements.",
    },
    {
      name = "security",
      description = "Security review",
      details = "Perform a security review identifying potential vulnerabilities, security best practices, and recommendations for improvement",
      prompt = "Please perform a security review of this code, identifying potential vulnerabilities, security best practices, and recommendations for improvement.",
    },
  }

  -- Load MDX shortcuts from directory if configured
  local mdx_shortcuts = {}
  if Config.shortcuts_directory then
    local MDXParser = require("avante.utils.mdx_parser")
    mdx_shortcuts = MDXParser.load_shortcuts_from_directory(Config.shortcuts_directory)
  end

  local user_shortcuts = Config.shortcuts or {}
  local result = {}

  -- Create maps for quick lookup (precedence: config > mdx > builtin)
  local builtin_map = {}
  for _, shortcut in ipairs(builtin_shortcuts) do
    builtin_map[shortcut.name] = shortcut
  end

  local mdx_map = {}
  for _, shortcut in ipairs(mdx_shortcuts) do
    mdx_map[shortcut.name] = shortcut
  end

  -- Track which shortcuts have been added to avoid duplicates
  local added = {}

  -- Priority 1: User shortcuts from config (highest precedence)
  for _, user_shortcut in ipairs(user_shortcuts) do
    table.insert(result, user_shortcut)
    added[user_shortcut.name] = true
  end

  -- Priority 2: MDX shortcuts (override builtins, but not config)
  for _, mdx_shortcut in ipairs(mdx_shortcuts) do
    if not added[mdx_shortcut.name] then
      table.insert(result, mdx_shortcut)
      added[mdx_shortcut.name] = true
    end
  end

  -- Priority 3: Built-in shortcuts (lowest precedence)
  for _, builtin_shortcut in ipairs(builtin_shortcuts) do
    if not added[builtin_shortcut.name] then
      table.insert(result, builtin_shortcut)
      added[builtin_shortcut.name] = true
    end
  end

  return result
end

---@param content string
---@return string new_content
---@return boolean has_shortcuts
function M.extract_shortcuts(content)
  local shortcuts = M.get_shortcuts()
  local new_content = content
  local has_shortcuts = false

  for _, shortcut in ipairs(shortcuts) do
    -- Create the search pattern (plain text)
    local search_pattern = "#" .. shortcut.name
    
    -- Check if this shortcut exists in the content using plain text search
    if content:find(search_pattern, 1, true) then -- true = plain text search
      has_shortcuts = true
      M.debug("Replacing shortcut #" .. shortcut.name .. " with prompt: " .. shortcut.prompt)
      
      -- Escape both the shortcut name and # for use in Lua pattern
      -- We need to escape all special pattern characters
      local escaped_name = shortcut.name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
      local pattern = "%#" .. escaped_name -- %# escapes the # character
      
      -- Perform the replacement, escaping % in the replacement string
      new_content = new_content:gsub(pattern, function()
        -- Return the prompt, escaping any % characters for gsub
        return (shortcut.prompt:gsub("%%", "%%%%"))
      end)
    end
  end

  return new_content, has_shortcuts
end

---@param path string
---@param set_current_buf? boolean
---@return integer bufnr
function M.open_buffer(path, set_current_buf)
  if set_current_buf == nil then set_current_buf = true end

  local abs_path = M.join_paths(M.get_project_root(), path)

  local bufnr ---@type integer
  if set_current_buf then
    bufnr = vim.fn.bufnr(abs_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd("noautocmd write") end)
    end
    vim.cmd("noautocmd edit " .. abs_path)
    bufnr = vim.api.nvim_get_current_buf()
  else
    bufnr = vim.fn.bufnr(abs_path, true)
    pcall(vim.fn.bufload, bufnr)
  end

  vim.cmd("filetype detect")

  return bufnr
end

---@param bufnr integer
---@param new_lines string[]
---@return { start_line: integer, end_line: integer, content: string[] }[]
local function get_buffer_content_diffs(bufnr, new_lines)
  local old_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diffs = {}
  local prev_diff_idx = nil
  for i, line in ipairs(new_lines) do
    if line ~= old_lines[i] then
      if prev_diff_idx == nil then prev_diff_idx = i end
    else
      if prev_diff_idx ~= nil then
        local content = vim.list_slice(new_lines, prev_diff_idx, i - 1)
        table.insert(diffs, { start_line = prev_diff_idx, end_line = i, content = content })
        prev_diff_idx = nil
      end
    end
  end
  if prev_diff_idx ~= nil then
    table.insert(
      diffs,
      { start_line = prev_diff_idx, end_line = #new_lines + 1, content = vim.list_slice(new_lines, prev_diff_idx) }
    )
  end
  if #new_lines < #old_lines then
    table.insert(diffs, { start_line = #new_lines + 1, end_line = #old_lines + 1, content = {} })
  end
  table.sort(diffs, function(a, b) return a.start_line > b.start_line end)
  return diffs
end

--- Update the buffer content more efficiently by only updating the changed lines
---@param bufnr integer
---@param new_lines string[]
function M.update_buffer_content(bufnr, new_lines)
  local diffs = get_buffer_content_diffs(bufnr, new_lines)
  if #diffs == 0 then return end
  for _, diff in ipairs(diffs) do
    api.nvim_buf_set_lines(bufnr, diff.start_line - 1, diff.end_line - 1, false, diff.content)
  end
end

---@param ns_id number
---@param bufnr integer
---@param old_lines avante.ui.Line[]
---@param new_lines avante.ui.Line[]
---@param skip_line_count? integer
function M.update_buffer_lines(ns_id, bufnr, old_lines, new_lines, skip_line_count)
  skip_line_count = skip_line_count or 0
  old_lines = old_lines or {}
  new_lines = new_lines or {}

  -- Unbind events from existing lines before rewriting the buffer section.
  for i, old_line in ipairs(old_lines) do
    if old_line and type(old_line.unbind_events) == "function" then
      local line_1b = skip_line_count + i
      pcall(old_line.unbind_events, old_line, bufnr, line_1b)
    end
  end

  -- Collect the text representation of each line and track their positions.
  local cleaned_text_lines = {}
  local line_positions = {}
  local current_line_0b = skip_line_count

  for idx, line in ipairs(new_lines) do
    local pieces = vim.split(tostring(line), "\n")
    line_positions[idx] = current_line_0b
    vim.list_extend(cleaned_text_lines, pieces)
    current_line_0b = current_line_0b + #pieces
  end

  -- Replace the entire dynamic portion of the buffer.
  vim.api.nvim_buf_set_lines(bufnr, skip_line_count, -1, false, cleaned_text_lines)

  -- Re-apply highlights and bind events for the new lines.
  for i, line in ipairs(new_lines) do
    local line_pos_0b = line_positions[i] or (skip_line_count + i - 1)
    if type(line.set_highlights) == "function" then line:set_highlights(ns_id, bufnr, line_pos_0b) end
    if type(line.bind_events) == "function" then
      local line_1b = line_pos_0b + 1
      pcall(line.bind_events, line, ns_id, bufnr, line_1b)
    end
  end

  vim.cmd("redraw")
  -- local diffs = get_lines_diff(old_lines, new_lines)
  -- if #diffs == 0 then return end
  -- for _, diff in ipairs(diffs) do
  --   local lines = diff.content
  --   local text_lines = vim.tbl_map(function(line) return tostring(line) end, lines)
  --   --- remove newlines from text_lines
  --   local cleaned_lines = {}
  --   for _, line in ipairs(text_lines) do
  --     local lines_ = vim.split(line, "\n")
  --     cleaned_lines = vim.list_extend(cleaned_lines, lines_)
  --   end
  --   vim.api.nvim_buf_set_lines(
  --     bufnr,
  --     skip_line_count + diff.start_line - 1,
  --     skip_line_count + diff.end_line - 1,
  --     false,
  --     cleaned_lines
  --   )
  --   for i, line in ipairs(lines) do
  --     line:set_highlights(ns_id, bufnr, skip_line_count + diff.start_line + i - 2)
  --   end
  --   vim.cmd("redraw")
  -- end
end

function M.uniform_path(path)
  if type(path) ~= "string" then path = tostring(path) end
  if not M.file.is_in_project(path) then return path end
  local project_root = M.get_project_root()
  local abs_path = M.is_absolute_path(path) and path or M.join_paths(project_root, path)
  local relative_path = M.make_relative_path(abs_path, project_root)
  return relative_path
end

function M.is_same_file(filepath_a, filepath_b) return M.uniform_path(filepath_a) == M.uniform_path(filepath_b) end

---Removes <think> tags, returning only text between them
---@param content string
---@return string
function M.trim_think_content(content) return (content:gsub("^<think>.-</think>", "", 1)) end

local _filetype_lru_cache = LRUCache:new(60)

function M.get_filetype(filepath)
  local cached_filetype = _filetype_lru_cache:get(filepath)
  if cached_filetype then return cached_filetype end
  -- Some files are sometimes not detected correctly when buffer is not included
  -- https://github.com/neovim/neovim/issues/27265

  local buf = vim.api.nvim_create_buf(false, true)
  local filetype = vim.filetype.match({ filename = filepath, buf = buf }) or ""
  vim.api.nvim_buf_delete(buf, { force = true })
  -- Parse the first filetype from a multifiltype file
  filetype = filetype:gsub("%..*$", "")
  _filetype_lru_cache:set(filepath, filetype)
  return filetype
end

---@param filepath string
---@return string[]|nil lines
---@return string|nil error
---@return string|nil errname
function M.read_file_from_buf_or_disk(filepath)
  local abs_path = filepath:sub(1, 7) == "term://" and filepath or M.join_paths(M.get_project_root(), filepath)
  --- Lookup if the file is loaded in a buffer
  local ok, bufnr = pcall(vim.fn.bufnr, abs_path)
  if ok then
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      -- If buffer exists and is loaded, get buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return lines, nil, nil
    end
  end

  local stat, stat_err, stat_errname = vim.uv.fs_stat(abs_path)
  if not stat then return {}, stat_err, stat_errname end
  if stat.type == "directory" then return {}, "Cannot read a directory as file" .. filepath, nil end

  -- Fallback: read file from disk
  local file, open_err = io.open(abs_path, "r")
  if file then
    local content = file:read("*all")
    file:close()
    content = content:gsub("\r\n", "\n")
    return vim.split(content, "\n"), nil, nil
  else
    return {}, open_err, nil
  end
end

---Check if an icon plugin is installed
---@return boolean
function M.icons_enabled() return M.has("nvim-web-devicons") or M.has("mini.icons") or M.has("mini.nvim") end

---Display an string with icon, if an icon plugin is available.
---Dev icons are an optional install for avante, this function prevents ugly chars
---being displayed by displaying fallback options or nothing at all.
---@param string_with_icon string
---@param utf8_fallback string|nil
---@return string
function M.icon(string_with_icon, utf8_fallback)
  if M.icons_enabled() then
    return string_with_icon
  else
    return utf8_fallback or ""
  end
end

function M.deep_extend_with_metatable(behavior, ...)
  local tables = { ... }
  local base = tables[1]
  if behavior == "keep" then base = tables[#tables] end
  local mt = getmetatable(base)

  local result = vim.tbl_deep_extend(behavior, ...)

  if mt then setmetatable(result, mt) end

  return result
end

function M.utc_now()
  local utc_date = os.date("!*t")
  ---@diagnostic disable-next-line: param-type-mismatch
  local utc_time = os.time(utc_date)
  return os.date("%Y-%m-%d %H:%M:%S", utc_time)
end

---@param dt1 string
---@param dt2 string
---@return integer delta_seconds
function M.datetime_diff(dt1, dt2)
  local pattern = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
  local y1, m1, d1, h1, min1, s1 = dt1:match(pattern)
  local y2, m2, d2, h2, min2, s2 = dt2:match(pattern)

  local time1 = os.time({ year = y1, month = m1, day = d1, hour = h1, min = min1, sec = s1 })
  local time2 = os.time({ year = y2, month = m2, day = d2, hour = h2, min = min2, sec = s2 })

  local delta_seconds = os.difftime(time2, time1)
  return delta_seconds
end

---@param iso_str string
---@return string|nil
---@return string|nil error
function M.parse_iso8601_date(iso_str)
  local year, month, day, hour, min, sec = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not year then return nil, "Invalid ISO 8601 format" end

  local time_table = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  }

  local timestamp = os.time(time_table)

  return tostring(os.date("%Y-%m-%d %H:%M:%S", timestamp)), nil
end

function M.random_string(length)
  local charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local result = {}
  for _ = 1, length do
    local rand = math.random(1, #charset)
    table.insert(result, charset:sub(rand, rand))
  end
  return table.concat(result)
end

function M.is_left_adjacent(win_a, win_b)
  if not vim.api.nvim_win_is_valid(win_a) or not vim.api.nvim_win_is_valid(win_b) then return false end

  local _, col_a = unpack(vim.fn.win_screenpos(win_a))
  local _, col_b = unpack(vim.fn.win_screenpos(win_b))
  local width_a = vim.api.nvim_win_get_width(win_a)

  local right_edge_a = col_a + width_a

  return right_edge_a + 1 == col_b
end

function M.is_top_adjacent(win_a, win_b)
  local row_a, _ = unpack(vim.fn.win_screenpos(win_a))
  local row_b, _ = unpack(vim.fn.win_screenpos(win_b))
  local height_a = vim.api.nvim_win_get_height(win_a)
  return row_a + height_a + 1 == row_b
end

function M.should_hidden_border(win_a, win_b)
  return M.is_left_adjacent(win_a, win_b) or M.is_top_adjacent(win_a, win_b)
end

---@param fields AvanteLLMToolParamField[]
---@return table[] properties
---@return string[] required
function M.llm_tool_param_fields_to_json_schema(fields)
  local properties = {}
  local required = {}
  for _, field in ipairs(fields) do
    if field.type == "object" and field.fields then
      local properties_, required_ = M.llm_tool_param_fields_to_json_schema(field.fields)
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
        properties = properties_,
        required = required_,
      }
    elseif field.type == "array" and field.items then
      local properties_ = M.llm_tool_param_fields_to_json_schema({ field.items })
      local _, obj = next(properties_)
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
        items = obj,
      }
    else
      properties[field.name] = {
        type = field.type,
        description = field.get_description and field.get_description() or field.description,
      }
      if field.choices then properties[field.name].enum = field.choices end
    end
    if not field.optional then table.insert(required, field.name) end
  end
  if vim.tbl_isempty(properties) then properties = vim.empty_dict() end
  return properties, required
end

--- Build todos summary text from chat history
---@param history avante.ChatHistory|nil
---@return string|nil
function M.plan_build_todos_text(history)
  if not history or not history.todos or #history.todos == 0 then return nil end
  local todos = history.todos

  local pending_todos = {}
  local in_progress_todos = {}
  local completed_todos = {}

  for _, todo in ipairs(todos) do
    if todo.status == "pending" or todo.status == "todo" then
      table.insert(pending_todos, todo)
    elseif todo.status == "in_progress" or todo.status == "doing" then
      table.insert(in_progress_todos, todo)
    elseif todo.status == "completed" or todo.status == "done" then
      table.insert(completed_todos, todo)
    end
  end

  local text = "**Current Plan**\n\n"

  if #in_progress_todos > 0 then
    text = text .. "**In Progress:**\n"
    for _, todo in ipairs(in_progress_todos) do
      text = text .. "- 🔄 " .. todo.content .. "\n"
    end
    text = text .. "\n"
  end

  if #pending_todos > 0 then
    text = text .. "**Pending:**\n"
    for _, todo in ipairs(pending_todos) do
      text = text .. "- ⏳ " .. todo.content .. "\n"
    end
    text = text .. "\n"
  end

  if #completed_todos > 0 then
    text = text .. "**Completed:**\n"
    for _, todo in ipairs(completed_todos) do
      text = text .. "- ✅ " .. todo.content .. "\n"
    end
    text = text .. "\n"
  end

  text = text .. string.format("\n**Progress:** %d/%d tasks completed", #completed_todos, #todos)
  return text
end

--- Find plan file path from chat history messages
--- Claude Code writes plans to ~/.claude/plans/*.md via the Write tool
---@param history avante.ChatHistory|nil
---@return string|nil
function M.plan_find_file_path(history)
  if not history then return nil end
  local ok, History = pcall(require, "avante.history")
  if not ok then return nil end
  local messages = History.get_history_messages(history)
  if not messages then return nil end

  local plan_file_path = nil
  for i = #messages, 1, -1 do
    local msg = messages[i]
    local content = msg.message and msg.message.content
    if type(content) == "table" then
      for _, item in ipairs(content) do
        if item.type == "tool_use" then
          local input = item.input or {}
          local path = input.file_path or input.path or ""
          if path:match("%.claude/plans/") and path:match("%.md$") then
            plan_file_path = path
            break
          end
        end
      end
    end
    if not plan_file_path and msg.acp_tool_call then
      local tc = msg.acp_tool_call
      local title = tc.title or ""
      if title:match("Write") or title:match("write") then
        local raw = tc.rawInput or {}
        local path = raw.file_path or raw.path or ""
        if path:match("%.claude/plans/") and path:match("%.md$") then
          plan_file_path = path
        end
      end
    end
    if plan_file_path then break end
  end
  return plan_file_path
end

--- Read a plan file from disk, expanding ~ paths
---@param plan_file_path string|nil
---@return string|nil
function M.plan_read_file(plan_file_path)
  if not plan_file_path then return nil end
  local expanded = plan_file_path:gsub("^~", vim.fn.expand("~"))
  expanded = vim.fn.fnamemodify(expanded, ":p")
  local file = io.open(expanded, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

---@return AvanteSlashCommand[]
function M.get_commands()
  local Config = require("avante.config")

  ---@param items_ {name: string, description: string, shorthelp?: string}[]
  ---@return string
  local function get_help_text(items_)
    local help_text = ""
    for _, item in ipairs(items_) do
      help_text = help_text .. "- " .. item.name .. ": " .. (item.shorthelp or item.description) .. "\n"
    end
    return help_text
  end

  local builtin_items = {
    { description = "Show help message", name = "help" },
    { description = "Init AGENTS.md based on the current project", name = "init" },
    { description = "Clear chat history", name = "clear" },
    { description = "New chat", name = "new" },
    { description = "Compact history messages to save tokens", name = "compact" },
    {
      shorthelp = "Ask a question about specific lines",
      description = "/lines <start>-<end> <question>",
      name = "lines",
    },
    { description = "Commit the changes", name = "commit" },
    { description = "Show project context summary", name = "context" },
    { description = "Show conversation memory summary", name = "memory" },
    { 
      shorthelp = "Add a directory to file selector",
      description = "/dir [path] - Add directory to context",
      name = "dir"
    },
    { description = "Show current plan progress and file", name = "plan" },
    { description = "Show plan file in chat window", name = "view-plan" },
    { description = "Open plan file in a buffer", name = "open-plan" },
    { description = "Toggle full-screen mode", name = "toggle-full-screen" },
    { description = "Switch avante mode (plan, one-shot, review, etc.)", name = "avante-modes" },
    { description = "Toggle follow agent edits", name = "toggle-follow" },
    {
      shorthelp = "Paste image from clipboard",
      description = "/paste-image - Paste an image from clipboard into the chat",
      name = "paste-image"
    },
    {
      shorthelp = "Select prompt from history",
      description = "/prompt - Open telescope picker to select and reuse a prompt from history",
      name = "prompt"
    },
    { description = "Fork the current thread", name = "fork" },
    { description = "Show files changed in this session", name = "files" },
    { description = "Pin the current thread", name = "pin" },
    { description = "Unpin the current thread", name = "unpin" },
  }

  ---@type {[AvanteSlashCommandBuiltInName]: AvanteSlashCommandCallback}
  local builtin_cbs = {
    help = function(sidebar, args, cb)
      local help_text = get_help_text(builtin_items)
      sidebar:update_content(help_text, { focus = false, scroll = false })
      if cb then cb(args) end
    end,
    clear = function(sidebar, args, cb) sidebar:clear_history(args, cb) end,
    new = function(sidebar, args, cb) sidebar:new_chat(args, cb) end,
    compact = function(sidebar, args, cb) sidebar:compact_history_messages(args, cb) end,
    init = function(sidebar, args, cb) sidebar:init_current_project(args, cb) end,
    lines = function(_, args, cb)
      if cb then cb(args) end
    end,
    commit = function(_, _, cb)
      local question = "Please commit the changes"
      if cb then cb(question) end
    end,
    context = function(sidebar, args, cb)
      -- Show current project context information
      local selected_files = sidebar.file_selector and sidebar.file_selector.selected_filepaths or {}
      local project_root = M.get_project_root()
      local working_dir = vim.fn.getcwd()
      
      local context_text = string.format(
        [[**Project Context**

**Project Root:** %s
**Working Directory:** %s

**Selected Files (%d):**
%s

**Recent Files:**
%s

Use `/dir <path>` to add directories to context.
Use `@` or the file selector to add individual files.]],
        project_root,
        working_dir,
        #selected_files,
        #selected_files > 0 and table.concat(vim.iter(selected_files):map(function(f) 
          return "- " .. M.relative_path(f) 
        end):totable(), "\n") or "(none)",
        table.concat(vim.iter(vim.v.oldfiles):take(10):map(function(f)
          return "- " .. M.relative_path(f)
        end):totable(), "\n")
      )
      
      sidebar:update_content(context_text, { focus = false, scroll = false })
      if cb then cb(args) end
    end,
    memory = function(sidebar, args, cb)
      -- Show conversation memory summary
      local history = sidebar.chat_history
      if not history or not history.memory then
        sidebar:update_content("No conversation memory available.\n\nMemory is created after compacting history with `/compact`.", { focus = false, scroll = false })
        if cb then cb(args) end
        return
      end
      
      local memory = history.memory
      local memory_text = string.format(
        [[**Conversation Memory**

**Last Summarized:** %s
**Last Message ID:** %s

**Summary:**
%s

---

This is the compressed memory of earlier conversation turns.
Use `/compact` to update the memory with recent messages.]],
        memory.last_summarized_timestamp or "unknown",
        memory.last_message_uuid or "unknown",
        memory.content or "(empty)"
      )
      
      sidebar:update_content(memory_text, { focus = false, scroll = false })
      if cb then cb(args) end
    end,
    dir = function(sidebar, args, cb)
      -- Add a directory to the file selector
      local path = args and M.trim_spaces(args) or ""
      
      if path == "" then
        -- If no path provided, open directory picker
        local function on_select(selected_paths)
          if selected_paths and #selected_paths > 0 then
            for _, selected_path in ipairs(selected_paths) do
              if vim.fn.isdirectory(selected_path) == 1 then
                sidebar.file_selector:process_directory(selected_path)
                sidebar:update_content(
                  "Added directory: " .. M.relative_path(selected_path),
                  { focus = false, scroll = false }
                )
              end
            end
          end
        end
        
        -- Use file selector to pick directory
        if sidebar.file_selector then
          sidebar.file_selector:open(on_select)
        end
        if cb then cb("") end
        return
      end
      
      -- Add the specified directory
      local abs_path = M.to_absolute_path(path)
      if vim.fn.isdirectory(abs_path) == 0 then
        sidebar:update_content(
          "Error: '" .. path .. "' is not a directory",
          { focus = false, scroll = false }
        )
        if cb then cb(args) end
        return
      end
      
      if sidebar.file_selector then
        sidebar.file_selector:process_directory(abs_path)
        local files = M.scan_directory({ directory = abs_path, add_dirs = false })
        sidebar:update_content(
          string.format("Added directory: %s (%d files)", M.relative_path(abs_path), #files),
          { focus = false, scroll = false }
        )
      end
      
      if cb then cb(args) end
    end,
    plan = function(sidebar, args, cb)
      M.debug("/plan command called")
      if not sidebar.chat_history then sidebar:reload_chat_history() end

      local history = sidebar.chat_history
      local todos_text = M.plan_build_todos_text(history)
      local plan_file_path = M.plan_find_file_path(history)
      local plan_file_content = M.plan_read_file(plan_file_path)

      if todos_text and plan_file_content then
        sidebar:update_content(todos_text .. "\n\n---\n\n" .. plan_file_content, { focus = false, scroll = false })
      elseif todos_text then
        sidebar:update_content(todos_text, { focus = false, scroll = false })
      elseif plan_file_content then
        sidebar:update_content(plan_file_content, { focus = false, scroll = false })
      else
        sidebar:update_content("No plan available.\n\nPlans will appear here when the agent creates a plan via plan mode.", { focus = false, scroll = false })
      end
      if cb then cb(args) end
    end,
    ["view-plan"] = function(sidebar, args, cb)
      if not sidebar.chat_history then sidebar:reload_chat_history() end
      local plan_file_path = M.plan_find_file_path(sidebar.chat_history)
      local content = M.plan_read_file(plan_file_path)
      if content then
        sidebar:update_content(content, { focus = false, scroll = false })
      else
        sidebar:update_content("No plan file found in this conversation.", { focus = false, scroll = false })
      end
      if cb then cb(args) end
    end,
    ["open-plan"] = function(sidebar, args, cb)
      if not sidebar.chat_history then sidebar:reload_chat_history() end
      local plan_file_path = M.plan_find_file_path(sidebar.chat_history)
      if plan_file_path then
        local expanded = plan_file_path:gsub("^~", vim.fn.expand("~"))
        expanded = vim.fn.fnamemodify(expanded, ":p")
        if vim.fn.filereadable(expanded) == 1 then
          -- Open in the code window (sidebar windows have winfixbuf)
          if sidebar.code and vim.api.nvim_win_is_valid(sidebar.code.winid) then
            vim.api.nvim_set_current_win(sidebar.code.winid)
          end
          vim.cmd("edit " .. vim.fn.fnameescape(expanded))
        else
          M.warn("Plan file not found on disk: " .. expanded)
        end
      else
        M.warn("No plan file found in this conversation.")
      end
      if cb then cb(args) end
    end,
    ["toggle-full-screen"] = function(sidebar, args, cb)
      -- Toggle full-screen mode for the result window
      sidebar:toggle_fullscreen_edit()
      if cb then cb(args) end
    end,
    ["avante-modes"] = function(sidebar, args, cb)
      local Config = require("avante.config")
      local Path = require("avante.path")
      local modes = Config.avante_modes or {}
      if #modes == 0 then
        sidebar:update_content("No avante modes configured.", { focus = false, scroll = false })
        return
      end

      -- Build selection list: modes + "none"
      local items = { { name = "none", description = "Disable avante mode" } }
      for _, m in ipairs(modes) do
        table.insert(items, m)
      end

      vim.ui.select(items, {
        prompt = "Select avante mode:",
        format_item = function(item)
          local current = sidebar.current_avante_mode
          local marker = (item.name == (current or "none")) and " (current)" or ""
          if item.name == "none" then return "No mode" .. marker end
          return item.name .. " — " .. item.description .. marker
        end,
      }, function(choice)
        if not choice then return end
        local old_mode = sidebar.current_avante_mode
        local new_mode = choice.name == "none" and nil or choice.name

        if old_mode ~= new_mode then
          sidebar._pending_mode_transition = {
            from = old_mode or "none",
            to = new_mode or "none",
          }
        end

        sidebar.current_avante_mode = new_mode
        if sidebar.chat_history then
          sidebar.chat_history.avante_mode = new_mode
          Path.history.save(sidebar.code.bufnr, sidebar.chat_history)
        end

        sidebar:render_result()
        sidebar:show_input_hint()

        local display = new_mode and new_mode:upper() or "NONE"
        M.info("Avante mode: " .. display)
        if cb then cb(args) end
      end)
    end,
    ["toggle-follow"] = function(sidebar, args, cb)
      -- Toggle follow agent locations mode
      local Config = require("avante.config")
      Config.behaviour.acp_follow_agent_locations = not Config.behaviour.acp_follow_agent_locations
      local status = Config.behaviour.acp_follow_agent_locations and "enabled" or "disabled"
      
      sidebar:update_content(
        string.format("**Follow Mode %s**\n\nFollow mode is now %s.\n\n%s", 
          status:upper(), 
          status,
          Config.behaviour.acp_follow_agent_locations 
            and "The editor will automatically navigate to files and locations as the agent edits them, with visual indicators showing where changes are being made." 
            or "The editor will not automatically follow agent edits. You can still see changes in the chat, but navigation is manual."
        ),
        { focus = false, scroll = false }
      )
      
      -- Update the status line to reflect the new following mode
      sidebar:show_input_hint()
      
      if cb then cb(args) end
    end,
    ["paste-image"] = function(sidebar, args, cb)
      -- Check if img-clip.nvim is available
      local Config = require("avante.config")
      if not Config.support_paste_image() then
        sidebar:update_content(
          "**Image pasting not available**\n\nImage pasting requires img-clip.nvim plugin.\n\nPlease install it with your package manager:\n- lazy.nvim: `{ 'HakonHarnes/img-clip.nvim', opts = {} }`",
          { focus = false, scroll = false }
        )
        if cb then cb(args) end
        return
      end

      -- Get the input buffer
      if not sidebar.containers.input then
        sidebar:update_content("Error: Input buffer not available", { focus = false, scroll = false })
        if cb then cb(args) end
        return
      end

      local input_bufnr = sidebar.containers.input.bufnr
      if not vim.api.nvim_buf_is_valid(input_bufnr) then
        sidebar:update_content("Error: Input buffer is not valid", { focus = false, scroll = false })
        if cb then cb(args) end
        return
      end

      -- Attempt to paste the image
      local Clipboard = require("avante.clipboard")
      local ok = Clipboard.paste_image(nil)
      
      if ok then
        -- Success - the image path has been inserted into the input buffer
        -- Move cursor to end of buffer
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(input_bufnr) then
            local last_line = vim.api.nvim_buf_line_count(input_bufnr)
            local last_line_content = vim.api.nvim_buf_get_lines(input_bufnr, last_line - 1, last_line, false)[1] or ""
            -- Try to set cursor in the input window
            local input_winid = sidebar.containers.input.winid
            if input_winid and vim.api.nvim_win_is_valid(input_winid) then
              vim.api.nvim_win_set_cursor(input_winid, { last_line, #last_line_content })
            end
          end
        end)
      else
        -- Failed - likely no image in clipboard
        sidebar:update_content(
          "**No image in clipboard**\n\nCould not paste image. Please ensure you have an image copied to your clipboard.\n\nSupported sources:\n- Screenshot tools\n- Image files copied from file managers\n- Images copied from web browsers",
          { focus = false, scroll = false }
        )
      end
      
      if cb then cb(args) end
    end,
    prompt = function(sidebar, args, cb)
      -- Open prompt selector to choose from history
      require("avante.prompt_selector").open()
      if cb then cb(args) end
    end,
    fork = function(sidebar, args, cb)
      sidebar:fork_thread()
      if cb then cb(args) end
    end,
    files = function(sidebar, args, cb)
      require("avante.changed_files").open()
      if cb then cb(args) end
    end,
    pin = function(sidebar, args, cb)
      if not sidebar.chat_history then
        M.warn("No active thread to pin")
      else
        sidebar.chat_history.pinned = true
        local Path = require("avante.path")
        Path.history.save(sidebar.code.bufnr, sidebar.chat_history)
        M.info("Pinned: " .. (sidebar.chat_history.title or "current thread"))
      end
      if cb then cb(args) end
    end,
    unpin = function(sidebar, args, cb)
      if not sidebar.chat_history then
        M.warn("No active thread to unpin")
      else
        sidebar.chat_history.pinned = false
        local Path = require("avante.path")
        Path.history.save(sidebar.code.bufnr, sidebar.chat_history)
        M.info("Unpinned: " .. (sidebar.chat_history.title or "current thread"))
      end
      if cb then cb(args) end
    end,
  }

  local builtin_commands = vim
    .iter(builtin_items)
    :map(
      ---@param item AvanteSlashCommand
      function(item)
        return {
          name = item.name,
          description = item.description,
          callback = builtin_cbs[item.name],
          details = item.shorthelp and table.concat({ item.shorthelp, item.description }, "\n") or item.description,
          source = "builtin",
        }
      end
    )
    :totable()

  local commands = {}
  local seen = {}
  for _, command in ipairs(Config.slash_commands) do
    if not seen[command.name] then
      table.insert(commands, command)
      seen[command.name] = true
    end
  end
  for _, command in ipairs(builtin_commands) do
    if not seen[command.name] then
      table.insert(commands, command)
      seen[command.name] = true
    end
  end

  return commands
end

--- Register ACP-sourced commands into Config.slash_commands and refresh the cmp source.
--- This is the single source of truth for handling available_commands_update from ACP.
---@param commands avante.acp.AvailableCommand[]
function M.register_acp_commands(commands)
  local Config = require("avante.config")
  for _, command in ipairs(commands) do
    local exists = false
    for _, command_ in ipairs(Config.slash_commands) do
      if command_.name == command.name then
        command_.source = "acp"
        command_.description = command.description
        command_.details = command.description
        exists = true
        break
      end
    end
    if not exists then
      table.insert(Config.slash_commands, {
        name = command.name,
        description = command.description,
        details = command.description,
        source = "acp",
      })
    end
  end

  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp then
    local slash_commands_id = require("avante").slash_commands_id
    if slash_commands_id ~= nil then cmp.unregister_source(slash_commands_id) end
    local avante = require("avante")
    avante.slash_commands_id = cmp.register_source("avante_commands", require("cmp_avante.commands"):new())
  end
end

function M.get_timestamp() return tostring(os.date("%Y-%m-%d %H:%M:%S")) end

function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

---Parse command arguments (fargs) into a structured format
---@param fargs string[] Command arguments
---@param options? {collect_remaining?: boolean, boolean_keys?: string[]} Options for parsing
---@return table parsed_args Key-value pairs from arguments
---@return string|nil remaining_text Concatenated remaining arguments (if collect_remaining is true)
function M.parse_args(fargs, options)
  options = options or {}
  local parsed_args = {}
  local remaining_parts = {}
  local boolean_keys = options.boolean_keys or {}

  -- Create a lookup table for boolean keys for faster access
  local boolean_keys_lookup = {}
  for _, key in ipairs(boolean_keys) do
    boolean_keys_lookup[key] = true
  end

  for _, arg in ipairs(fargs) do
    local key, value = arg:match("([%w_]+)=(.+)")

    if key and value then
      -- Convert "true"/"false" string values to boolean for specified keys
      if boolean_keys_lookup[key] or value == "true" or value == "false" then
        parsed_args[key] = (value == "true")
      else
        parsed_args[key] = value
      end
    elseif options.collect_remaining then
      table.insert(remaining_parts, arg)
    end
  end

  -- Return the parsed arguments and optionally the concatenated remaining text
  if options.collect_remaining and #remaining_parts > 0 then return parsed_args, table.concat(remaining_parts, " ") end

  return parsed_args
end

---@param tool_use AvanteLLMToolUse
function M.tool_use_to_xml(tool_use)
  local tool_use_json = vim.json.encode({
    name = tool_use.name,
    input = tool_use.input,
  })
  local xml = string.format("<tool_use>%s</tool_use>", tool_use_json)
  return xml
end

---@param tool_use AvanteLLMToolUse
function M.is_edit_tool_use(tool_use)
  return tool_use.name == "str_replace"
    or tool_use.name == "edit_file"
    or (tool_use.name == "str_replace_editor" and tool_use.input.command == "str_replace")
    or (tool_use.name == "str_replace_based_edit_tool" and tool_use.input.command == "str_replace")
end

---Counts number of strings in text, accounting for possibility of a trailing newline
---@param str string | nil
---@return integer
function M.count_lines(str)
  if not str or str == "" then return 0 end

  local _, count = str:gsub("\n", "\n")
  -- Number of lines is one more than number of newlines unless we have a trailing newline
  return str:sub(-1) ~= "\n" and count + 1 or count
end

function M.tbl_override(value, override)
  override = override or {}
  if type(override) == "function" then return override(value) or value end
  return vim.tbl_extend("force", value, override)
end

function M.call_once(func)
  local called = false
  return function(...)
    if called then return end
    called = true
    return func(...)
  end
end

--- Some models (e.g., gpt-4o) cannot correctly return diff content and often miss the SEARCH line, so this needs to be manually fixed in such cases.
---@param diff string
---@return string
function M.fix_diff(diff)
  diff = diff2search_replace(diff)
  -- Normalize block headers to the expected ones (fix for some LLMs output)
  diff = diff:gsub("<<<<<<<%s*SEARCH", "------- SEARCH")
  diff = diff:gsub(">>>>>>>%s*REPLACE", "+++++++ REPLACE")
  diff = diff:gsub("-------%s*REPLACE", "+++++++ REPLACE")
  diff = diff:gsub("-------  ", "------- SEARCH\n")
  diff = diff:gsub("=======  ", "=======\n")

  local fixed_diff_lines = {}
  local lines = vim.split(diff, "\n")
  local first_line = lines[1]
  if first_line and first_line:match("^%s*```") then
    table.insert(fixed_diff_lines, first_line)
    table.insert(fixed_diff_lines, "------- SEARCH")
    fixed_diff_lines = vim.list_extend(fixed_diff_lines, lines, 2)
  else
    table.insert(fixed_diff_lines, "------- SEARCH")
    if first_line:match("------- SEARCH") then
      fixed_diff_lines = vim.list_extend(fixed_diff_lines, lines, 2)
    else
      fixed_diff_lines = vim.list_extend(fixed_diff_lines, lines, 1)
    end
  end
  local the_final_diff_lines = {}
  local has_split_line = false
  local replace_block_closed = false
  local should_delete_following_lines = false
  for _, line in ipairs(fixed_diff_lines) do
    if should_delete_following_lines then goto continue end
    if line:match("^-------%s*SEARCH") then has_split_line = false end
    if line:match("^=======") then
      if has_split_line then
        should_delete_following_lines = true
        goto continue
      end
      has_split_line = true
    end
    if line:match("^+++++++%s*REPLACE") then
      if not has_split_line then
        table.insert(the_final_diff_lines, "=======")
        has_split_line = true
        goto continue
      else
        replace_block_closed = true
      end
    end
    table.insert(the_final_diff_lines, line)
    ::continue::
  end
  if not replace_block_closed then table.insert(the_final_diff_lines, "+++++++ REPLACE") end
  return table.concat(the_final_diff_lines, "\n")
end

function M.get_unified_diff(text1, text2, opts)
  opts = opts or {}
  opts.result_type = "unified"
  opts.ctxlen = opts.ctxlen or 3

  return vim.diff(text1, text2, opts)
end

function M.is_floating_window(win_id)
  win_id = win_id or 0
  if not vim.api.nvim_win_is_valid(win_id) then return false end
  local config = vim.api.nvim_win_get_config(win_id)
  return config.relative ~= ""
end

return M