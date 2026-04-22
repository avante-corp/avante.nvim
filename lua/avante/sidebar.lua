local api = vim.api
local fn = vim.fn

local Split = require("nui.split")
local event = require("nui.utils.autocmd").event

local PPath = require("plenary.path")
local Providers = require("avante.providers")
local Path = require("avante.path")
local Config = require("avante.config")
local Diff = require("avante.diff")
local Llm = require("avante.llm")
local Utils = require("avante.utils")
local PromptLogger = require("avante.utils.promptLogger")
local Highlights = require("avante.highlights")
local RepoMap = require("avante.repo_map")
local FileSelector = require("avante.file_selector")
local LLMTools = require("avante.llm_tools")
local History = require("avante.history")
local Render = require("avante.history.render")
local Line = require("avante.ui.line")
local LRUCache = require("avante.utils.lru_cache")
local logo = require("avante.utils.logo")
local ButtonGroupLine = require("avante.ui.button_group_line")

local RESULT_BUF_NAME = "AVANTE_RESULT"
local VIEW_BUFFER_UPDATED_PATTERN = "AvanteViewBufferUpdated"
local CODEBLOCK_KEYBINDING_NAMESPACE = api.nvim_create_namespace("AVANTE_CODEBLOCK_KEYBINDING")
local TOOL_MESSAGE_KEYBINDING_NAMESPACE = api.nvim_create_namespace("AVANTE_TOOL_MESSAGE_KEYBINDING")
local USER_REQUEST_BLOCK_KEYBINDING_NAMESPACE = api.nvim_create_namespace("AVANTE_USER_REQUEST_BLOCK_KEYBINDING")
local SELECTED_FILES_HINT_NAMESPACE = api.nvim_create_namespace("AVANTE_SELECTED_FILES_HINT")
local SELECTED_FILES_ICON_NAMESPACE = api.nvim_create_namespace("AVANTE_SELECTED_FILES_ICON")
local INPUT_HINT_NAMESPACE = api.nvim_create_namespace("AVANTE_INPUT_HINT")
local STATE_NAMESPACE = api.nvim_create_namespace("AVANTE_STATE")
local RESULT_BUF_HL_NAMESPACE = api.nvim_create_namespace("AVANTE_RESULT_BUF_HL")

local PRIORITY = (vim.hl or vim.highlight).priorities.user

local RESP_SEPARATOR = "-------"

---This is a list of known sidebar containers or sub-windows. They are listed in
---the order they appear in the sidebar, from top to bottom.
local SIDEBAR_CONTAINERS = {
  "result",
  "selected_code",
  "selected_files",
  "plan",
  "input",
}

---@class avante.Sidebar
local Sidebar = {}
Sidebar.__index = Sidebar

---@class avante.CodeState
---@field winid integer
---@field bufnr integer
---@field selection avante.SelectionResult | nil
---@field old_winhl string | nil
---@field win_width integer | nil

---@class avante.Sidebar
---@field id integer
---@field augroup integer
---@field code avante.CodeState
---@field containers { result?: NuiSplit, plan?: NuiSplit, selected_code?: NuiSplit, selected_files?: NuiSplit, input?: NuiSplit }
---@field file_selector FileSelector
---@field chat_history avante.ChatHistory | nil
---@field current_state avante.GenerateState | nil
---@field state_timer table | nil
---@field state_spinner_chars string[]
---@field thinking_spinner_chars string[]
---@field state_spinner_idx integer
---@field state_extmark_id integer | nil
---@field scroll boolean
---@field input_hint_window integer | nil
---@field old_result_lines avante.ui.Line[]
---@field token_count integer | nil
---@field acp_client avante.acp.ACPClient | nil
---@field post_render? fun(sidebar: avante.Sidebar)
---@field permission_handler fun(id: string) | nil
---@field permission_button_options ({ id: string, icon: string|nil, name: string }[]) | nil
---@field permission_question_text string | nil
---@field expanded_message_uuids table<string, boolean>
---@field tool_message_positions table<string, [integer, integer]>
---@field skip_line_count integer | nil
---@field current_tool_use_extmark_id integer | nil
---@field private win_size_store table<integer, {width: integer, height: integer}>
---@field is_in_full_view boolean
---@field current_mode_id string | nil
---@field available_modes string[]
---@field acp_thread avante.AcpThread | nil
---@field _context_panel_visible boolean
---@field _plan_bufnr integer | nil  -- deprecated: plan now uses containers.plan
---@field _plan_path string | nil

---@param id integer the tabpage id retrieved from api.nvim_get_current_tabpage()
function Sidebar:new(id)
  return setmetatable({
    id = id,
    code = { bufnr = 0, winid = 0, selection = nil, old_winhl = nil },
    winids = {
      result_container = 0,
      todos_container = 0,
      selected_files_container = 0,
      selected_code_container = 0,
      input_container = 0,
    },
    containers = {},
    file_selector = FileSelector:new(id),
    is_generating = false,
    chat_history = nil,
    current_state = nil,
    state_timer = nil,
    state_spinner_chars = (Config.windows and Config.windows.spinner and Config.windows.spinner.generating) or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    thinking_spinner_chars = (Config.windows and Config.windows.spinner and Config.windows.spinner.thinking) or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    state_spinner_idx = 1,
    state_extmark_id = nil,
    scroll = true,
    input_hint_window = nil,
    old_result_lines = {},
    token_count = nil,
    -- Cache-related fields
    _cached_history_lines = nil,
    _history_cache_invalidated = true,
    post_render = nil,
    tool_message_positions = {},
    expanded_message_ids = {},
    current_tool_use_extmark_id = nil,
    win_width_store = {},
    is_in_full_view = false,
    is_in_fullscreen_edit = false,
    is_input_fullscreen = false,
    current_mode_id = nil,
    available_modes = {},
    acp_thread = nil,
    current_avante_mode = nil,
    _pending_mode_transition = nil,
    _context_panel_visible = false,
    _plan_bufnr = nil,
    _plan_path = nil,
    follow_mode = Config.behaviour.acp_follow_agent_locations,
    _plan_visible = true,
    _current_session_ctx = nil,
  }, Sidebar)
end

function Sidebar:delete_autocmds()
  if self.augroup then api.nvim_del_augroup_by_id(self.augroup) end
  self.augroup = nil
end

function Sidebar:delete_containers()
  for _, container in pairs(self.containers) do
    container:unmount()
  end
  self.containers = {}
end

function Sidebar:reset()
  -- clean up event handlers
  if self.augroup then
    api.nvim_del_augroup_by_id(self.augroup)
    self.augroup = nil
  end

  -- clean up keymaps
  self:unbind_apply_key()
  self:unbind_sidebar_keys()

  -- clean up file selector events
  if self.file_selector then self.file_selector:off("update") end

  self:delete_containers()

  self.code = { bufnr = 0, winid = 0, selection = nil }
  self.scroll = true
  self.old_result_lines = {}
  self.token_count = nil
  self.tool_message_positions = {}
  self.expanded_message_uuids = {}
  self.current_tool_use_extmark_id = nil
  self.win_size_store = {}
  self.is_in_full_view = false
  self.is_in_fullscreen_edit = false
  self.is_input_fullscreen = false
end

---@class SidebarOpenOptions: AskOptions
---@field selection? avante.SelectionResult
---@field new_chat? boolean

---@param opts SidebarOpenOptions
function Sidebar:open(opts)
  opts = opts or {}
  self.show_logo = opts.show_logo
  self._skip_history_load = opts.new_chat == true
  -- Set an empty placeholder history so render() never sees old todos/messages
  -- and create_input_container() won't reload old history (it reloads when chat_history is nil)
  if opts.new_chat then
    self.chat_history = {
      title = "untitled",
      timestamp = "",
      entries = {},
      messages = {},
      todos = {},
      tags = {},
      filename = "",
      acp_session_id = nil,
    }
    self.current_avante_mode = nil
    -- Clear thread state early so nothing leaks from a prior session
    -- into the brief window before new_thread() runs
    self.acp_thread = nil
    self.current_mode_id = nil
    self.available_modes = {}
    self._pending_mode_transition = nil
    self._current_session_ctx = nil
  end
  local in_visual_mode = Utils.in_visual_mode() and self:in_code_win()
  if not self:is_open() then
    self:reset()
    self:initialize()
    self._skip_history_load = false
    if opts.selection then self.code.selection = opts.selection end
    self:render(opts)
    self:focus()
  else
    if in_visual_mode or opts.selection then
      self:close()
      self:reset()
      self:initialize()
      self._skip_history_load = false
      if opts.selection then self.code.selection = opts.selection end
      self:render(opts)
      return self
    end
    self:focus()
  end

  if not vim.g.avante_login or vim.g.avante_login == false then
    api.nvim_exec_autocmds("User", { pattern = Providers.env.REQUEST_LOGIN_PATTERN })
    vim.g.avante_login = true
  end

  -- Auto-restore last thread's session info (working dir, selected files)
  if not opts.skip_session_restore then
    local last_session = Path.history.load_last_session(self.code.bufnr)
    if last_session then
      if last_session.working_directory and vim.fn.isdirectory(last_session.working_directory) == 1 then
        vim.cmd("cd " .. vim.fn.fnameescape(last_session.working_directory))
      end
      if last_session.selected_files and self.file_selector then
        for _, filepath in ipairs(last_session.selected_files) do
          self.file_selector:add_selected_file(filepath)
        end
      end
    end
  end

  -- Connect to ACP agent — uses chat_history.acp_session_id to load or create
  if not opts.skip_acp_connect then
    self:connect_acp()
  end

  return self
end

function Sidebar:setup_colors()
  self:set_code_winhl()
  vim.api.nvim_create_autocmd("WinNew", {
    group = self.augroup,
    callback = function(env)
      if Utils.is_floating_window(env.id) then
        Utils.debug("WinNew ignore floating window")
        return
      end
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(self.id)) do
        if not vim.api.nvim_win_is_valid(winid) or self:is_sidebar_winid(winid) then goto continue end
        local winhl = vim.wo[winid].winhl
        if
          winhl:find("WinSeparator:" .. Highlights.AVANTE_SIDEBAR_WIN_SEPARATOR)
          and not (vim.api.nvim_win_is_valid(self.code.winid) and Utils.should_hidden_border(self.code.winid, winid))
        then
          vim.wo[winid].winhl = self.code.old_winhl or ""
        end
        ::continue::
      end
      self:set_code_winhl()
    end,
  })
end

function Sidebar:set_code_winhl()
  if not self.code.winid or not api.nvim_win_is_valid(self.code.winid) then return end
  if not Utils.is_valid_container(self.containers.result, true) then return end

  if Utils.should_hidden_border(self.code.winid, self.containers.result.winid) then
    local old_winhl = vim.wo[self.code.winid].winhl
    if self.code.old_winhl == nil then
      self.code.old_winhl = old_winhl
    else
      old_winhl = self.code.old_winhl
    end
    local pieces = vim.split(old_winhl or "", ",")
    local new_pieces = {}
    for _, piece in ipairs(pieces) do
      if not piece:find("WinSeparator:") and piece ~= "" then table.insert(new_pieces, piece) end
    end
    table.insert(new_pieces, "WinSeparator:" .. Highlights.AVANTE_SIDEBAR_WIN_SEPARATOR)
    local new_winhl = table.concat(new_pieces, ",")
    vim.wo[self.code.winid].winhl = new_winhl
  end
end

function Sidebar:recover_code_winhl()
  if self.code.old_winhl ~= nil then
    if self.code.winid and api.nvim_win_is_valid(self.code.winid) then
      vim.wo[self.code.winid].winhl = self.code.old_winhl
    end
    self.code.old_winhl = nil
  end
end

---@class SidebarCloseOptions
---@field goto_code_win? boolean

---@param opts? SidebarCloseOptions
function Sidebar:close(opts)
  opts = vim.tbl_extend("force", { goto_code_win = true }, opts or {})

  -- If sidebar was maximized make it normal size so that other windows
  -- will not be left minimized.
  if self.is_in_full_view then self:toggle_code_window() end

  self:delete_autocmds()
  self:delete_containers()

  self.old_result_lines = {}
  if opts.goto_code_win and self.code and self.code.winid and api.nvim_win_is_valid(self.code.winid) then
    fn.win_gotoid(self.code.winid)
  end

  self:recover_code_winhl()
  self:close_input_hint()
end

function Sidebar:shutdown()
  Llm.cancel_inflight_request()
  self:close()
  vim.cmd("noautocmd stopinsert")
end

---@return boolean
function Sidebar:focus()
  if self:is_open() then
    fn.win_gotoid(self.containers.result.winid)
    return true
  end
  return false
end

function Sidebar:focus_input()
  if Utils.is_valid_container(self.containers.input, true) then
    api.nvim_set_current_win(self.containers.input.winid)
    self:show_input_hint()
  end
end

function Sidebar:is_open() return Utils.is_valid_container(self.containers.result, true) end

function Sidebar:in_code_win() return self.code.winid == api.nvim_get_current_win() end

---Extract task summary from chat history
---@return string
function Sidebar:_extract_task_summary()
  local messages = self.chat_history.messages or {}
  
  -- Find most recent user message
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == "user" and msg.content then
      local content = msg.content
      local Config = require("avante.config")
      local max_len = Config.notifications.max_summary_length
      if #content > max_len then
        return content:sub(1, max_len) .. "..."
      end
      return content
    end
  end
  
  return "Agent task"
end

---@param opts AskOptions
function Sidebar:toggle(opts)
  local in_visual_mode = Utils.in_visual_mode() and self:in_code_win()
  if self:is_open() and not in_visual_mode then
    self:close()
    return false
  else
    ---@cast opts SidebarOpenOptions
    self:open(opts)
    return true
  end
end

---Initialize available modes from ACP client (no fallback)
---@param opts? { skip_set_default_mode?: boolean }
function Sidebar:initialize_modes(opts)
  opts = opts or {}
  if self.acp_client and self.acp_client:has_modes() then
    -- Server provides modes
    self.available_modes = vim.tbl_map(function(m) return m.id end, self.acp_client:all_modes())
    self.current_mode_id = self.acp_client:current_mode()

    -- Setup mode change callback — routes through acp_thread if available
    -- Capture generation to drop stale callbacks from old sessions
    local mode_gen = self._acp_session_generation or 0
    self.acp_client.on_mode_changed = function(mode_id)
      vim.schedule(function()
        if (self._acp_session_generation or 0) ~= mode_gen then return end
        self.current_mode_id = mode_id
        if self.acp_thread then
          self.acp_thread.current_mode_id = mode_id
        end
        self:render_result()
        self:show_input_hint()
        local mode = self.acp_client:mode_by_id(mode_id)
        local mode_name = mode and mode.name or mode_id
        Utils.info("Mode: " .. mode_name)
      end)
    end

    Utils.debug("Initialized " .. #self.available_modes .. " modes from agent: " .. table.concat(self.available_modes, ", "))
    Utils.debug("Current mode from ACP: " .. tostring(self.current_mode_id))

    -- Sync to acp_thread if available
    if self.acp_thread then
      self.acp_thread:initialize_modes(self.acp_client:all_modes(), self.current_mode_id)
    end

    -- Set default mode if configured and available (like Zed does after session/new)
    -- Skip for loaded sessions — the session already has its own mode
    local default_mode = Config.behaviour.acp_default_mode
    Utils.debug("acp_default_mode config: " .. tostring(default_mode))
    if default_mode and self.chat_history.acp_session_id and not opts.skip_set_default_mode then
      local has_mode = vim.tbl_contains(self.available_modes, default_mode)
      if has_mode then
        -- Only set if not already in the desired mode
        if self.current_mode_id ~= default_mode then
          Utils.debug("Setting default ACP mode: " .. default_mode .. " for session: " .. self.chat_history.acp_session_id)
          self.acp_client:set_mode(self.chat_history.acp_session_id, default_mode, function(result, err)
            vim.schedule(function()
              if err then
                Utils.warn("Failed to set default mode: " .. vim.inspect(err))
              else
                Utils.debug("set_mode succeeded, result: " .. vim.inspect(result))
                -- Update local state immediately (server will also send current_mode_update)
                self.current_mode_id = default_mode
                if self.acp_thread then
                  self.acp_thread.current_mode_id = default_mode
                end
                self:render_result()
                self:show_input_hint()
              end
            end)
          end)
        end
      else
        local available = table.concat(self.available_modes, ", ")
        Utils.warn("Default mode '" .. default_mode .. "' not available. Available: " .. available)
      end
    end
  else
    -- No modes available from agent - this is OK, some agents don't support modes
    self.available_modes = {}
    self.current_mode_id = nil
    if self.acp_thread then
      self.acp_thread.available_modes = {}
      self.acp_thread.current_mode_id = nil
    end
    Utils.debug("Agent does not provide session modes")
  end
end

--- Create or update the AcpThread for this sidebar.
--- This bridges the new abstraction with the existing sidebar state.
--- Call after a session is created/loaded and acp_client is available.
function Sidebar:ensure_acp_thread()
  local AcpThread = require("avante.acp_thread")

  if not self.acp_thread then
    self.acp_thread = AcpThread:new({
      session_id = self.chat_history and self.chat_history.acp_session_id or nil,
      title = self.chat_history and self.chat_history.title or nil,
      tags = self.chat_history and self.chat_history.tags or {},
    })
  end

  -- Sync session_id
  if self.chat_history and self.chat_history.acp_session_id then
    self.acp_thread.session_id = self.chat_history.acp_session_id
  end

  -- Sync mode state
  self.acp_thread.current_mode_id = self.current_mode_id
  self.acp_thread.available_modes = {}
  if self.acp_client and self.acp_client:has_modes() then
    self.acp_thread.available_modes = self.acp_client:all_modes()
  end

  -- Sync config options
  if self.acp_client and self.acp_client:has_config_options() then
    self.acp_thread.config_options = self.acp_client:all_config_options()
  end

  -- Capture current generation so callbacks from stale sessions are dropped
  local cb_generation = self._acp_session_generation or 0
  local function is_stale() return (self._acp_session_generation or 0) ~= cb_generation end

  -- Wire up callbacks that update the sidebar
  self.acp_thread:set_callbacks({
    on_state_change = function(new_state, _old_state)
      vim.schedule(function()
        if is_stale() then return end
        self:show_input_hint()
      end)
    end,
    on_mode_change = function(mode_id, mode_name)
      vim.schedule(function()
        if is_stale() then return end
        self.current_mode_id = mode_id
        self:render_result()
        self:show_input_hint()
      end)
    end,
    on_plan_update = function(todos)
      vim.schedule(function()
        if is_stale() then return end
        self:update_plan(todos)
        self:show_input_hint() -- refresh plan progress in status line
      end)
    end,
    on_config_options_change = function(config_options)
      vim.schedule(function()
        if is_stale() then return end
        self:render_result()
        self:show_input_hint()
      end)
    end,
  })

  return self.acp_thread
end

--- Connect to ACP agent and either load an existing session or create a new one.
--- This is the single entry point for all ACP session lifecycle management.
---@param opts? { on_ready?: fun(), force_new?: boolean }
function Sidebar:connect_acp(opts)
  opts = opts or {}
  local acp_provider = Config.acp_providers[Config.provider]
  if not acp_provider then
    if opts.on_ready then opts.on_ready() end
    return
  end

  local ACPClient = require("avante.libs.acp_client")
  local EnvUtils = require("avante.utils.environment")

  -- Bump session generation to invalidate any in-flight callbacks from prior session
  self._acp_session_generation = (self._acp_session_generation or 0) + 1
  local my_generation = self._acp_session_generation

  -- Stop and unregister existing client if switching sessions
  if self.acp_client then
    -- Unregister from global registry before stopping
    local ok, Avante = pcall(require, "avante")
    if ok and Avante.unregister_acp_client then
      -- Find and remove our client from the registry
      for client_id, client in pairs(Avante.acp_clients or {}) do
        if client == self.acp_client then
          Avante.unregister_acp_client(client_id)
          break
        end
      end
    end
    pcall(function() self.acp_client:stop() end)
  end
  self.acp_client = nil
  self.acp_thread = nil

  -- Placeholder handlers — will be replaced by llm.lua before sending prompts
  local handlers = {
    on_session_update = function(update)
      if update.sessionUpdate == "available_commands_update" and update.availableCommands then
        Utils.register_acp_commands(update.availableCommands)
      end
    end,
    on_request_permission = function(_tool_call, _options, _callback) end,
    on_read_file = function(path, _line, _limit, callback, error_callback)
      local abs_path = Utils.to_absolute_path(path)
      local lines, err, errname = Utils.read_file_from_buf_or_disk(abs_path)
      if err then
        if error_callback then
          local code = errname == "ENOENT" and ACPClient.ERROR_CODES.RESOURCE_NOT_FOUND or nil
          error_callback(err, code)
        end
        return
      end
      callback(table.concat(lines or {}, "\n"))
    end,
    on_write_file = function(path, content, callback)
      local abs_path = Utils.to_absolute_path(path)
      local file = io.open(abs_path, "w")
      if file then
        file:write(content)
        file:close()
        callback(nil)
      else
        callback("Failed to write file: " .. abs_path)
      end
    end,
  }

  local cwd = vim.fn.getcwd()
  local resolved_env = EnvUtils.merge_env_with_overrides(
    acp_provider.env or {},
    acp_provider.envOverrides,
    cwd
  )

  local acp_config = vim.tbl_deep_extend("force", acp_provider, {
    handlers = handlers,
    env = resolved_env,
  })
  local acp_client = ACPClient:new(acp_config)

  acp_client:connect(function(conn_err)
    -- Guard against stale callbacks
    if (self._acp_session_generation or 0) ~= my_generation then return end

    if conn_err then
      Utils.error("ACP connect failed: " .. tostring(conn_err))
      return
    end

    -- Register for global cleanup on exit
    local client_id = "acp_" .. tostring(acp_client) .. "_" .. os.time()
    local ok, Avante = pcall(require, "avante")
    if ok and Avante.register_acp_client then Avante.register_acp_client(client_id, acp_client) end

    self.acp_client = acp_client

    local existing_session_id = self.chat_history and self.chat_history.acp_session_id
    local has_existing = existing_session_id and not opts.force_new

    if has_existing then
      -- We have an existing session ID — try to resume it
      local can_load = acp_client.agent_capabilities and acp_client.agent_capabilities.loadSession

      if can_load then
        -- Use the session's working_directory for cwd so the ACP wrapper can find
        -- the session file under the correct project path in ~/.claude/projects/
        local session_cwd = (self.chat_history and self.chat_history.working_directory) or Utils.root.get()
        Utils.debug("Attempting session/load for: " .. existing_session_id .. " cwd: " .. session_cwd)
        acp_client:load_session(existing_session_id, session_cwd, {}, function(result, err)
          if (self._acp_session_generation or 0) ~= my_generation then return end
          if err then
            -- session/load failed — the new process cannot restore this session.
            -- Create a new session immediately rather than keeping a stale ID that
            -- will fail on the first prompt with "Session not found".
            Utils.debug("session/load failed (code=" .. tostring(err.code) .. "), creating new session")
            self:_create_acp_session(acp_client, my_generation, opts)
            return
          end

          -- Update session ID if the agent returned a different one
          local loaded_session_id = result and result.sessionId or existing_session_id
          if self.chat_history then
            self.chat_history.acp_session_id = loaded_session_id
            Path.history.save(self.code.bufnr, self.chat_history)
          end

          Utils.info("ACP session resumed: " .. loaded_session_id)
          vim.schedule(function()
            if (self._acp_session_generation or 0) ~= my_generation then return end
            self:initialize_modes({ skip_set_default_mode = true })
            self:ensure_acp_thread()
            self:render_result()
            self:show_input_hint()
            if opts.on_ready then opts.on_ready() end
          end)
        end)
      else
        -- Agent doesn't support session/load — the new process has no way to
        -- restore the old session. Create a new session immediately.
        Utils.debug("Agent does not support session/load, creating new session")
        self:_create_acp_session(acp_client, my_generation, opts)
      end
    else
      -- No existing session or force_new — create a new one
      self:_create_acp_session(acp_client, my_generation, opts)
    end
  end)
end

--- Internal: create a new ACP session after client is connected
---@param acp_client avante.acp.ACPClient
---@param generation number
---@param opts { on_ready?: fun(), force_new?: boolean }
function Sidebar:_create_acp_session(acp_client, generation, opts)
  local project_root = Utils.root.get()
  acp_client:create_session(project_root, {}, function(session_id, err)
    if (self._acp_session_generation or 0) ~= generation then return end
    if err then
      Utils.error("Failed to create ACP session: " .. tostring(err))
      return
    end
    if not session_id then
      Utils.error("Failed to create ACP session: no session ID returned")
      return
    end

    -- Save session ID to chat history
    if self.chat_history then
      self.chat_history.acp_session_id = session_id
      -- Auto-tag with provider info on first session creation
      if not self.chat_history.tags or #self.chat_history.tags == 0 then
        self.chat_history.tags = {}
        local provider = Config.provider or "unknown"
        table.insert(self.chat_history.tags, provider)
        local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
        if cwd and cwd ~= "" then
          table.insert(self.chat_history.tags, cwd)
        end
      end
      Path.history.save(self.code.bufnr, self.chat_history)
    end

    vim.schedule(function()
      if (self._acp_session_generation or 0) ~= generation then return end
      self:initialize_modes()
      self:ensure_acp_thread()
      self:render_result()
      self:show_input_hint()
      if opts.on_ready then opts.on_ready() end
    end)
  end)
end

--- Create a new thread, resetting the sidebar for a fresh conversation.
--- Auto-tags the thread with provider and project info.
--- Connects ACP with force_new to create a fresh session.
---@param opts? { avante_mode?: string }
function Sidebar:new_thread(opts)
  opts = opts or {}

  -- Reset sidebar state
  self.acp_thread = nil
  self.current_mode_id = nil
  self.available_modes = {}
  self._pending_mode_transition = nil

  -- Set avante mode
  self.current_avante_mode = opts.avante_mode or nil

  -- Reset file selector to clean state
  if self.file_selector then
    self.file_selector:reset()
    if Config.behaviour.auto_add_current_file and self.code.bufnr and api.nvim_buf_is_valid(self.code.bufnr) then
      local buf_path = api.nvim_buf_get_name(self.code.bufnr)
      if buf_path ~= "" and not buf_path:match("^%w+://") then
        local filepath = Utils.file.is_in_project(buf_path) and Utils.relative_path(buf_path) or buf_path
        local stat = vim.uv.fs_stat(filepath)
        if stat == nil or stat.type == "file" then self.file_selector:add_selected_file(filepath) end
      end
    end
  end

  -- Create fresh history (no acp_session_id — connect_acp will create new)
  self.chat_history = Path.history.new(self.code.bufnr)
  self.chat_history.avante_mode = self.current_avante_mode

  -- Auto-tag with provider info
  local provider = Config.provider or "unknown"
  self.chat_history.tags = { provider }
  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  if cwd and cwd ~= "" then
    table.insert(self.chat_history.tags, cwd)
  end

  Path.history.save(self.code.bufnr, self.chat_history)

  -- Clear UI and all session state
  self.current_state = nil
  self.expanded_message_uuids = {}
  self.tool_message_positions = {}
  self.current_tool_use_extmark_id = nil
  self._current_session_ctx = nil
  self._history_cache_invalidated = true

  -- Clear changed files tracking from prior session
  require("avante.changed_files").clear()

  -- Clear stale ACP slash commands from previous session
  Config.slash_commands = vim.tbl_filter(function(c) return c.source ~= "acp" end, Config.slash_commands)

  -- Update display with the fresh (empty) history — don't call
  -- update_content_with_history() as that reloads from disk and overwrites
  -- the fresh chat_history we just created above.
  self:update_content("")
  self:render_result()
  self:show_input_hint()

  -- Refresh plan container to clear stale todos
  vim.schedule(function() self:create_plan_container() end)

  -- Connect ACP — force_new since this is a brand new thread
  self:connect_acp({ force_new = true })

  Utils.debug("Created new thread: " .. self.chat_history.filename)
end

--- Load an existing thread by session_id or filename.
--- Connects ACP to load or create session based on thread's acp_session_id.
---@param opts { session_id?: string, filename?: string }
function Sidebar:load_thread(opts)
  if opts.filename then
    self.chat_history = Path.history.load(self.code.bufnr, opts.filename)
  elseif opts.session_id then
    -- Find the history file with this session_id
    local all = Path.history.list(self.code.bufnr)
    local found = nil
    for _, h in ipairs(all) do
      if h.acp_session_id == opts.session_id then
        found = h
        break
      end
    end
    if found then
      self.chat_history = found
    else
      Utils.warn("No thread found with session_id: " .. opts.session_id)
      return
    end
  end

  -- Reset thread state — will be re-created by connect_acp
  self.acp_thread = nil
  self.current_mode_id = nil
  self.available_modes = {}
  self._pending_mode_transition = nil
  self.current_state = nil
  self.expanded_message_uuids = {}
  self.tool_message_positions = {}
  self.current_tool_use_extmark_id = nil
  self._current_session_ctx = nil

  -- Clear prior session's changed files and slash commands
  require("avante.changed_files").clear()
  Config.slash_commands = vim.tbl_filter(function(c) return c.source ~= "acp" end, Config.slash_commands)

  -- Restore avante mode from history
  self.current_avante_mode = self.chat_history and self.chat_history.avante_mode or nil

  -- Update UI
  self:render_result()
  self:show_input_hint()
  vim.schedule(function() self:create_plan_container() end)

  -- Connect ACP — will load existing session if acp_session_id present
  self:connect_acp()

  Utils.debug("Loaded thread: " .. (self.chat_history.filename or "unknown"))
end

--- Fork the current thread, creating a new conversation branching from the current messages.
--- After forking, prompts the user for what they want to do with the fork.
function Sidebar:fork_thread()
  if not self.chat_history then
    Utils.warn("No active thread to fork")
    return
  end

  local Path = require("avante.path")

  -- Create a new history with a copy of current messages
  local forked = Path.history.new(self.code.bufnr)
  forked.title = (self.chat_history.title or "untitled") .. " (fork)"
  forked.tags = vim.deepcopy(self.chat_history.tags or {})
  table.insert(forked.tags, "fork")
  forked.parent_thread_id = self.chat_history.acp_session_id or self.chat_history.filename
  forked.messages = vim.deepcopy(self.chat_history.messages)
  forked.entries = vim.deepcopy(self.chat_history.entries)
  forked.working_directory = self.chat_history.working_directory

  -- Save the forked history
  Path.history.save(self.code.bufnr, forked)

  -- Fork the AcpThread so the new session gets full conversation context (both roles)
  local forked_acp_thread = nil
  if self.acp_thread then
    forked_acp_thread = self.acp_thread:fork()
    forked_acp_thread.session_id = nil -- will get a new ACP session on first submit
  end

  -- Switch to the forked thread
  self.chat_history = forked
  self.acp_thread = forked_acp_thread
  self.current_mode_id = nil
  self.available_modes = {}

  -- Update UI
  self:render_result()
  self:show_input_hint()

  Utils.info("Forked thread: " .. forked.filename)

  -- Connect ACP — fork has no session_id, force_new creates a fresh session
  self:connect_acp({
    force_new = true,
    on_ready = function()
      -- Prompt user for what to do with this fork
      vim.schedule(function()
        vim.ui.input({ prompt = "What would you like to do with this fork? " }, function(input)
          if not input or input == "" then return end
          if self.containers and self.containers.input and vim.api.nvim_buf_is_valid(self.containers.input.bufnr) then
            vim.api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, vim.split(input, "\n"))
            self:handle_submit(input)
          end
        end)
      end)
    end,
  })
end

--- Rename the current thread.
---@param new_title string
function Sidebar:rename_thread(new_title)
  if not self.chat_history then
    Utils.warn("No active thread to rename")
    return
  end
  self.chat_history.title = new_title
  if self.acp_thread then
    self.acp_thread.title = new_title
  end
  local Path = require("avante.path")
  Path.history.save(self.code.bufnr, self.chat_history)
  self:show_input_hint()
  Utils.info("Thread renamed to: " .. new_title)
end

---Cycle to next session mode
function Sidebar:cycle_mode()
  if not self.acp_client or not self.acp_client:has_modes() then
    Utils.info("Mode cycling not supported by this agent")
    return
  end
  
  local all_modes = self.acp_client:all_modes()
  if #all_modes == 0 then
    Utils.info("Mode cycling not supported by this agent")
    return
  end
  
  -- Find current index
  local current_mode_id = self.acp_client:current_mode()
  local current_idx = 1
  for i, mode in ipairs(all_modes) do
    if mode.id == current_mode_id then
      current_idx = i
      break
    end
  end
  
  -- Cycle to next (wrap around)
  local next_idx = (current_idx % #all_modes) + 1
  local next_mode = all_modes[next_idx]
  local next_mode_id = next_mode.id
  
  -- Update immediately for responsive UI
  self.current_mode_id = next_mode_id
  -- Also update the ACP client's internal state for consistent current_mode() calls
  if self.acp_client.session_modes then
    self.acp_client.session_modes.current_mode_id = next_mode_id
  end
  -- Sync to acp_thread
  if self.acp_thread then
    self.acp_thread.current_mode_id = next_mode_id
  end
  self:render_result()
  self:show_input_hint()

  -- Notify server (some agents don't support mode switching - that's OK)
  local session_id = self.chat_history and self.chat_history.acp_session_id
  if session_id then
    self.acp_client:set_mode(session_id, next_mode_id, function(result, err)
      if err then
        -- Check if this is a "method not found" error - agent doesn't support mode switching
        if err.message and err.message:match("Method not found") then
          Utils.debug("Agent does not support mode switching: " .. tostring(err.message))
          -- Keep the local mode change for UI purposes
          Utils.info("Mode: " .. next_mode.name .. " (local only)")
        else
          Utils.warn("Failed to set mode: " .. tostring(err.message))
          -- Revert on other errors
          self.current_mode_id = current_mode_id
          if self.acp_client.session_modes then
            self.acp_client.session_modes.current_mode_id = current_mode_id
          end
          if self.acp_thread then
            self.acp_thread.current_mode_id = current_mode_id
          end
          vim.schedule(function()
            self:render_result()
            self:show_input_hint()
          end)
        end
      else
        Utils.info("Mode: " .. next_mode.name)
      end
    end)
  else
    Utils.info("Mode: " .. next_mode.name)
  end
end

---@class AvanteReplacementResult
---@field content string
---@field current_filepath string
---@field is_searching boolean
---@field is_replacing boolean
---@field is_thinking boolean
---@field waiting_for_breakline boolean
---@field last_search_tag_start_line integer
---@field last_replace_tag_start_line integer
---@field last_think_tag_start_line integer
---@field last_think_tag_end_line integer

---@param result_content string
---@param prev_filepath string
---@return AvanteReplacementResult
local function transform_result_content(result_content, prev_filepath)
  local transformed_lines = {}

  local result_lines = vim.split(result_content, "\n")

  local is_searching = false
  local is_replacing = false
  local is_thinking = false
  local last_search_tag_start_line = 0
  local last_replace_tag_start_line = 0
  local last_think_tag_start_line = 0
  local last_think_tag_end_line = 0

  local search_start = 0

  local current_filepath

  local waiting_for_breakline = false
  local i = 1
  while true do
    if i > #result_lines then break end
    local line_content = result_lines[i]
    local matched_filepath =
      line_content:match("<[Ff][Ii][Ll][Ee][Pp][Aa][Tt][Hh]>(.+)</[Ff][Ii][Ll][Ee][Pp][Aa][Tt][Hh]>")
    if matched_filepath then
      if i > 1 then
        local prev_line = result_lines[i - 1]
        if prev_line and prev_line:match("^%s*```%w+$") then
          transformed_lines = vim.list_slice(transformed_lines, 1, #transformed_lines - 1)
        end
      end
      current_filepath = matched_filepath
      table.insert(transformed_lines, string.format("Filepath: %s", matched_filepath))
      goto continue
    end
    if line_content:match("^%s*<[Ss][Ee][Aa][Rr][Cc][Hh]>") then
      is_searching = true

      if not line_content:match("^%s*<[Ss][Ee][Aa][Rr][Cc][Hh]>%s*$") then
        local search_start_line = line_content:match("<[Ss][Ee][Aa][Rr][Cc][Hh]>(.+)$")
        line_content = "<SEARCH>"
        result_lines[i] = line_content
        if search_start_line and search_start_line ~= "" then table.insert(result_lines, i + 1, search_start_line) end
      end
      line_content = "<SEARCH>"

      local prev_line = result_lines[i - 1]
      if
        prev_line
        and prev_filepath
        and not prev_line:match("Filepath:.+")
        and not prev_line:match("<[Ff][Ii][Ll][Ee][Pp][Aa][Tt][Hh]>.+</[Ff][Ii][Ll][Ee][Pp][Aa][Tt][Hh]>")
      then
        table.insert(transformed_lines, string.format("Filepath: %s", prev_filepath))
      end
      local next_line = result_lines[i + 1]
      if next_line and next_line:match("^%s*```%w+$") then i = i + 1 end
      search_start = i + 1
      last_search_tag_start_line = i
    elseif line_content:match("</[Ss][Ee][Aa][Rr][Cc][Hh]>%s*$") then
      if is_replacing then
        result_lines[i] = line_content:gsub("</[Ss][Ee][Aa][Rr][Cc][Hh]>", "</REPLACE>")
        goto continue_without_increment
      end

      -- Handle case where </SEARCH> is a suffix
      if not line_content:match("^%s*</[Ss][Ee][Aa][Rr][Cc][Hh]>%s*$") then
        local search_end_line = line_content:match("^(.+)</[Ss][Ee][Aa][Rr][Cc][Hh]>")
        line_content = "</SEARCH>"
        result_lines[i] = line_content
        if search_end_line and search_end_line ~= "" then
          table.insert(result_lines, i, search_end_line)
          goto continue_without_increment
        end
      end

      is_searching = false

      local search_end = i

      local prev_line = result_lines[i - 1]
      if prev_line and prev_line:match("^%s*```$") then search_end = i - 1 end

      local match_filetype = nil
      local filepath = current_filepath or prev_filepath or ""

      if filepath == "" then goto continue end

      local file_content_lines = Utils.read_file_from_buf_or_disk(filepath) or {}
      local file_type = Utils.get_filetype(filepath)
      local search_lines = vim.list_slice(result_lines, search_start, search_end - 1)
      local start_line, end_line = Utils.fuzzy_match(file_content_lines, search_lines)

      if start_line ~= nil and end_line ~= nil then
        match_filetype = file_type
      else
        start_line = 0
        end_line = 0
      end

      -- when the filetype isn't detected, fallback to matching based on filepath.
      -- can happen if the llm tries to edit or create a file outside of it's context.
      if not match_filetype then
        local snippet_file_path = current_filepath or prev_filepath
        match_filetype = Utils.get_filetype(snippet_file_path)
      end

      local search_start_tag_idx_in_transformed_lines = 0
      for j = 1, #transformed_lines do
        if transformed_lines[j] == "<SEARCH>" then
          search_start_tag_idx_in_transformed_lines = j
          break
        end
      end
      if search_start_tag_idx_in_transformed_lines > 0 then
        transformed_lines = vim.list_slice(transformed_lines, 1, search_start_tag_idx_in_transformed_lines - 1)
      end
      waiting_for_breakline = true
      vim.list_extend(transformed_lines, {
        string.format("Replace lines: %d-%d", start_line, end_line),
        string.format("```%s", match_filetype),
      })
      goto continue
    elseif line_content:match("^%s*<[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>") then
      is_replacing = true
      if not line_content:match("^%s*<[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>%s*$") then
        local replace_first_line = line_content:match("<[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>(.+)$")
        line_content = "<REPLACE>"
        result_lines[i] = line_content
        if replace_first_line and replace_first_line ~= "" then
          table.insert(result_lines, i + 1, replace_first_line)
        end
      end
      local next_line = result_lines[i + 1]
      if next_line and next_line:match("^%s*```%w+$") then i = i + 1 end
      last_replace_tag_start_line = i
      goto continue
    elseif line_content:match("</[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>%s*$") then
      -- Handle case where </REPLACE> is a suffix
      if not line_content:match("^%s*</[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>%s*$") then
        local replace_end_line = line_content:match("^(.+)</[Rr][Ee][Pp][Ll][Aa][Cc][Ee]>")
        line_content = "</REPLACE>"
        result_lines[i] = line_content
        if replace_end_line and replace_end_line ~= "" then
          table.insert(result_lines, i, replace_end_line)
          goto continue_without_increment
        end
      end
      is_replacing = false
      local prev_line = result_lines[i - 1]
      if not (prev_line and prev_line:match("^%s*```$")) then table.insert(transformed_lines, "```") end
      local next_line = result_lines[i + 1]
      if next_line and next_line:match("^%s*```%s*$") then i = i + 1 end
      goto continue
    elseif line_content == "<think>" then
      is_thinking = true
      last_think_tag_start_line = i
      last_think_tag_end_line = 0
    elseif line_content == "</think>" then
      is_thinking = false
      last_think_tag_end_line = i
    elseif line_content:match("^%s*```%s*$") then
      local prev_line = result_lines[i - 1]
      if prev_line and prev_line:match("^%s*```$") then goto continue end
    end
    waiting_for_breakline = false
    table.insert(transformed_lines, line_content)
    ::continue::
    i = i + 1
    ::continue_without_increment::
  end

  return {
    current_filepath = current_filepath,
    content = table.concat(transformed_lines, "\n"),
    waiting_for_breakline = waiting_for_breakline,
    is_searching = is_searching,
    is_replacing = is_replacing,
    is_thinking = is_thinking,
    last_search_tag_start_line = last_search_tag_start_line,
    last_replace_tag_start_line = last_replace_tag_start_line,
    last_think_tag_start_line = last_think_tag_start_line,
    last_think_tag_end_line = last_think_tag_end_line,
  }
end

---@param replacement AvanteReplacementResult
---@return string
local function generate_display_content(replacement)
  if replacement.is_searching then
    return table.concat(
      vim.list_slice(vim.split(replacement.content, "\n"), 1, replacement.last_search_tag_start_line - 1),
      "\n"
    )
  end
  if replacement.last_think_tag_start_line > 0 then
    local lines = vim.split(replacement.content, "\n")
    local last_think_tag_end_line = replacement.last_think_tag_end_line
    if last_think_tag_end_line == 0 then last_think_tag_end_line = #lines + 1 end
    local thinking_content_lines =
      vim.list_slice(lines, replacement.last_think_tag_start_line + 2, last_think_tag_end_line - 1)
    local formatted_thinking_content_lines = vim
      .iter(thinking_content_lines)
      :map(function(line)
        if Utils.trim_spaces(line) == "" then return line end
        return string.format("  > %s", line)
      end)
      :totable()
    local result_lines = vim.list_extend(
      vim.list_slice(lines, 1, replacement.last_search_tag_start_line),
      { Utils.icon("🤔 ") .. "Thought content:" }
    )
    result_lines = vim.list_extend(result_lines, formatted_thinking_content_lines)
    result_lines = vim.list_extend(result_lines, vim.list_slice(lines, last_think_tag_end_line + 1))
    return table.concat(result_lines, "\n")
  end
  return replacement.content
end

---@class AvanteCodeSnippet
---@field range integer[]
---@field content string
---@field lang string
---@field explanation string
---@field start_line_in_response_buf integer
---@field end_line_in_response_buf integer
---@field filepath string

---@param source string|integer
---@return TSNode[]
local function tree_sitter_markdown_parse_code_blocks(source)
  local query = require("vim.treesitter.query")
  local parser
  if type(source) == "string" then
    parser = vim.treesitter.get_string_parser(source, "markdown")
  else
    parser = vim.treesitter.get_parser(source, "markdown")
  end
  if parser == nil then
    Utils.warn("Failed to get markdown parser")
    return {}
  end
  local tree = parser:parse()[1]
  local root = tree:root()
  local code_block_query = query.parse(
    "markdown",
    [[ (fenced_code_block
      (info_string
        (language) @language)?
      (block_continuation) @code_start
      (fenced_code_block_delimiter) @code_end) ]]
  )
  local nodes = {}
  for _, node in code_block_query:iter_captures(root, source) do
    table.insert(nodes, node)
  end
  return nodes
end

---@param response_content string
---@return table<string, AvanteCodeSnippet[]>
local function extract_code_snippets_map(response_content)
  local snippets = {}
  local lines = vim.split(response_content, "\n")

  -- use tree-sitter-markdown to parse all code blocks in response_content
  local lang = "text"
  local start_line, end_line
  local start_line_in_response_buf, end_line_in_response_buf
  local explanation_start_line = 0
  for _, node in ipairs(tree_sitter_markdown_parse_code_blocks(response_content)) do
    if node:type() == "language" then
      lang = vim.treesitter.get_node_text(node, response_content)
    elseif node:type() == "block_continuation" and node:start() > 1 then
      start_line_in_response_buf = node:start()
      local number_line = lines[start_line_in_response_buf - 1]

      local _, start_line_str, end_line_str =
        number_line:match("^%s*(%d*)[%.%)%s]*[Aa]?n?d?%s*[Rr]eplace%s+[Ll]ines:?%s*(%d+)%-(%d+)")
      if start_line_str ~= nil and end_line_str ~= nil then
        start_line = tonumber(start_line_str)
        end_line = tonumber(end_line_str)
      else
        _, start_line_str = number_line:match("^%s*(%d*)[%.%)%s]*[Aa]?n?d?%s*[Rr]eplace%s+[Ll]ine:?%s*(%d+)")
        if start_line_str ~= nil then
          start_line = tonumber(start_line_str)
          end_line = tonumber(start_line_str)
        else
          start_line_str = number_line:match("[Aa]fter%s+[Ll]ine:?%s*(%d+)")
          if start_line_str ~= nil then
            start_line = tonumber(start_line_str) + 1
            end_line = tonumber(start_line_str) + 1
          end
        end
      end
    elseif
      node:type() == "fenced_code_block_delimiter"
      and start_line_in_response_buf ~= nil
      and node:start() >= start_line_in_response_buf
    then
      end_line_in_response_buf, _ = node:start()
      if start_line ~= nil and end_line ~= nil then
        local filepath = lines[start_line_in_response_buf - 2]
        if filepath:match("^[Ff]ilepath:") then filepath = filepath:match("^[Ff]ilepath:%s*(.+)") end
        local content =
          table.concat(vim.list_slice(lines, start_line_in_response_buf + 1, end_line_in_response_buf), "\n")
        local explanation = ""
        if start_line_in_response_buf > explanation_start_line + 2 then
          explanation =
            table.concat(vim.list_slice(lines, explanation_start_line, start_line_in_response_buf - 3), "\n")
        end
        local snippet = {
          range = { start_line, end_line },
          content = content,
          lang = lang,
          explanation = explanation,
          start_line_in_response_buf = start_line_in_response_buf,
          end_line_in_response_buf = end_line_in_response_buf + 1,
          filepath = filepath,
        }
        table.insert(snippets, snippet)
      end
      lang = "text"
      explanation_start_line = end_line_in_response_buf + 2
    end
  end

  local snippets_map = {}
  for _, snippet in ipairs(snippets) do
    if snippet.filepath == "" then goto continue end
    snippets_map[snippet.filepath] = snippets_map[snippet.filepath] or {}
    table.insert(snippets_map[snippet.filepath], snippet)
    ::continue::
  end

  return snippets_map
end

local function insert_conflict_contents(bufnr, snippets)
  -- sort snippets by start_line
  table.sort(snippets, function(a, b) return a.range[1] < b.range[1] end)

  local lines = Utils.get_buf_lines(0, -1, bufnr)

  local offset = 0

  for _, snippet in ipairs(snippets) do
    local start_line, end_line = unpack(snippet.range)

    local first_line_content = lines[start_line]
    local old_first_line_indentation = ""

    if first_line_content then old_first_line_indentation = Utils.get_indentation(first_line_content) end

    local result = {}
    table.insert(result, "<<<<<<< HEAD")
    for i = start_line, end_line do
      table.insert(result, lines[i])
    end
    table.insert(result, "=======")

    local snippet_lines = vim.split(snippet.content, "\n")

    if #snippet_lines > 0 then
      local new_first_line_indentation = Utils.get_indentation(snippet_lines[1])
      if #old_first_line_indentation > #new_first_line_indentation then
        local line_indentation = old_first_line_indentation:sub(#new_first_line_indentation + 1)
        snippet_lines = vim.iter(snippet_lines):map(function(line) return line_indentation .. line end):totable()
      end
    end

    vim.list_extend(result, snippet_lines)

    table.insert(result, ">>>>>>> Snippet")

    api.nvim_buf_set_lines(bufnr, offset + start_line - 1, offset + end_line, false, result)
    offset = offset + #snippet_lines + 3
  end
end

---@param codeblocks table<integer, any>
local function is_cursor_in_codeblock(codeblocks)
  local cursor_line, _ = Utils.get_cursor_pos()

  for _, block in ipairs(codeblocks) do
    if cursor_line >= block.start_line and cursor_line <= block.end_line then return block end
  end

  return nil
end

---@class AvanteRespUserRequestBlock
---@field start_line number 1-indexed
---@field end_line number 1-indexed
---@field content string

---@param position? integer
---@return AvanteRespUserRequestBlock | nil
function Sidebar:get_current_user_request_block(position)
  local current_resp_content, current_resp_start_line = self:get_content_between_separators(position)
  if current_resp_content == nil then return nil end
  if current_resp_content == "" then return nil end
  local lines = vim.split(current_resp_content, "\n")
  local start_line = nil
  local end_line = nil
  local content_lines = {}
  for i = 1, #lines do
    local line = lines[i]
    local m = line:match("^>%s+(.+)$")
    if m then
      if start_line == nil then start_line = i end
      table.insert(content_lines, m)
      end_line = i
    elseif start_line ~= nil then
      break
    end
  end
  if start_line == nil then return nil end
  content_lines = vim.list_slice(content_lines, 1, #content_lines - 1)
  local content = table.concat(content_lines, "\n")
  return {
    start_line = current_resp_start_line + start_line - 1,
    end_line = current_resp_start_line + end_line - 1,
    content = content,
  }
end

function Sidebar:is_cursor_in_user_request_block()
  local block = self:get_current_user_request_block()
  if block == nil then return false end
  local cursor_line = api.nvim_win_get_cursor(self.containers.result.winid)[1]
  return cursor_line >= block.start_line and cursor_line <= block.end_line
end

function Sidebar:get_current_tool_use_message_uuid()
  local skip_line_count = self.skip_line_count or 0
  local cursor_line = api.nvim_win_get_cursor(self.containers.result.winid)[1]
  for message_uuid, positions in pairs(self.tool_message_positions) do
    if skip_line_count + positions[1] + 1 <= cursor_line and cursor_line <= skip_line_count + positions[2] then
      return message_uuid, positions
    end
  end
end

---@class AvanteCodeblock
---@field start_line integer 1-indexed
---@field end_line integer 1-indexed
---@field lang string

---@param buf integer
---@return AvanteCodeblock[]
local function parse_codeblocks(buf)
  local codeblocks = {}
  local lines = Utils.get_buf_lines(0, -1, buf)
  local lang, start_line, valid
  for _, node in ipairs(tree_sitter_markdown_parse_code_blocks(buf)) do
    if node:type() == "language" then
      lang = vim.treesitter.get_node_text(node, buf)
    elseif node:type() == "block_continuation" then
      start_line, _ = node:start()
    elseif node:type() == "fenced_code_block_delimiter" and start_line ~= nil and node:start() >= start_line then
      local end_line, _ = node:start()
      valid = lines[start_line - 1]:match("^%s*(%d*)[%.%)%s]*[Aa]?n?d?%s*[Rr]eplace%s+[Ll]ines:?%s*(%d+)%-(%d+)")
        ~= nil
      if valid then table.insert(codeblocks, { start_line = start_line, end_line = end_line + 1, lang = lang }) end
    end
  end

  return codeblocks
end

---@param original_lines string[]
---@param snippet AvanteCodeSnippet
---@return AvanteCodeSnippet[]
local function minimize_snippet(original_lines, snippet)
  local start_line = snippet.range[1]
  local end_line = snippet.range[2]
  local original_snippet_lines = vim.list_slice(original_lines, start_line, end_line)
  local original_snippet_content = table.concat(original_snippet_lines, "\n")
  local snippet_content = snippet.content
  local snippet_lines = vim.split(snippet_content, "\n")
  ---@diagnostic disable-next-line: assign-type-mismatch
  local patch = vim.diff( ---@type integer[][]
    original_snippet_content,
    snippet_content,
    ---@diagnostic disable-next-line: missing-fields
    { algorithm = "histogram", result_type = "indices", ctxlen = vim.o.scrolloff }
  )
  ---@type AvanteCodeSnippet[]
  local new_snippets = {}
  for _, hunk in ipairs(patch) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    ---@type AvanteCodeSnippet
    local new_snippet = {
      range = {
        count_a > 0 and start_line + start_a - 1 or start_line + start_a,
        start_line + start_a + math.max(count_a, 1) - 2,
      },
      content = table.concat(vim.list_slice(snippet_lines, start_b, start_b + count_b - 1), "\n"),
      lang = snippet.lang,
      explanation = snippet.explanation,
      start_line_in_response_buf = snippet.start_line_in_response_buf,
      end_line_in_response_buf = snippet.end_line_in_response_buf,
      filepath = snippet.filepath,
    }
    table.insert(new_snippets, new_snippet)
  end
  return new_snippets
end

---@param filepath string
---@param snippets AvanteCodeSnippet[]
---@return table<string, AvanteCodeSnippet[]>
function Sidebar:minimize_snippets(filepath, snippets)
  local original_lines = {}

  local original_lines_ = Utils.read_file_from_buf_or_disk(filepath)
  if original_lines_ then original_lines = original_lines_ end

  local results = {}

  for _, snippet in ipairs(snippets) do
    local new_snippets = minimize_snippet(original_lines, snippet)
    if new_snippets then
      for _, new_snippet in ipairs(new_snippets) do
        table.insert(results, new_snippet)
      end
    end
  end

  return results
end

function Sidebar:retry_user_request()
  local block = self:get_current_user_request_block()
  if not block then return end
  self:handle_submit(block.content)
end

--- Clear the input buffer
function Sidebar:clear_input()
  if not Utils.is_valid_container(self.containers.input) then return end
  api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, {})
  api.nvim_win_set_cursor(self.containers.input.winid, { 1, 0 })
end

function Sidebar:handle_expand_message(message_uuid, expanded)
  Utils.debug("handle_expand_message", message_uuid, expanded)
  self.expanded_message_uuids[message_uuid] = expanded
  self._history_cache_invalidated = true
  local old_scroll = self.scroll
  self.scroll = false
  self:update_content("")
  self.scroll = old_scroll
  vim.defer_fn(function()
    local cursor_line = api.nvim_win_get_cursor(self.containers.result.winid)[1]
    local positions = self.tool_message_positions[message_uuid]
    if positions then
      local skip_line_count = self.skip_line_count or 0
      if cursor_line > positions[2] + skip_line_count then
        api.nvim_win_set_cursor(self.containers.result.winid, { positions[2] + skip_line_count, 0 })
      end
    end
  end, 100)
end

function Sidebar:edit_user_request()
  local block = self:get_current_user_request_block()
  if not block then return end

  if Utils.is_valid_container(self.containers.input) then
    local lines = vim.split(block.content, "\n")
    api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, lines)
    api.nvim_set_current_win(self.containers.input.winid)
    api.nvim_win_set_cursor(self.containers.input.winid, { 1, #lines > 0 and #lines[1] or 0 })
  end
end

---@param current_cursor boolean
function Sidebar:apply(current_cursor)
  local response, response_start_line = self:get_content_between_separators()
  local all_snippets_map = extract_code_snippets_map(response)
  local selected_snippets_map = {}
  if current_cursor then
    if self.containers.result and self.containers.result.winid then
      local cursor_line = Utils.get_cursor_pos(self.containers.result.winid)
      for filepath, snippets in pairs(all_snippets_map) do
        for _, snippet in ipairs(snippets) do
          if
            cursor_line >= snippet.start_line_in_response_buf + response_start_line - 1
            and cursor_line <= snippet.end_line_in_response_buf + response_start_line - 1
          then
            selected_snippets_map[filepath] = { snippet }
            break
          end
        end
      end
    end
  else
    selected_snippets_map = all_snippets_map
  end

  vim.defer_fn(function()
    api.nvim_set_current_win(self.code.winid)
    for filepath, snippets in pairs(selected_snippets_map) do
      if Config.behaviour.minimize_diff then snippets = self:minimize_snippets(filepath, snippets) end
      local bufnr = Utils.open_buffer(filepath)
      local path_ = PPath:new(Utils.is_win() and filepath:gsub("/", "\\") or filepath)
      path_:parent():mkdir({ parents = true, exists_ok = true })
      insert_conflict_contents(bufnr, snippets)
      local function process(winid)
        api.nvim_set_current_win(winid)
        vim.cmd("noautocmd stopinsert")
        Diff.add_visited_buffer(bufnr)
        Diff.process(bufnr)
        api.nvim_win_set_cursor(winid, { 1, 0 })
        vim.defer_fn(function()
          Diff.find_next(Config.windows.ask.focus_on_apply)
          vim.cmd("normal! zz")
        end, 100)
      end
      local winid = Utils.get_winid(bufnr)
      if winid then
        process(winid)
      else
        api.nvim_create_autocmd("BufWinEnter", {
          group = self.augroup,
          buffer = bufnr,
          once = true,
          callback = function()
            local winid_ = Utils.get_winid(bufnr)
            if winid_ then process(winid_) end
          end,
        })
      end
    end
  end, 10)
end

local buf_options = {
  modifiable = false,
  swapfile = false,
  buftype = "nofile",
}

local base_win_options = {
  winfixbuf = true,
  spell = false,
  signcolumn = "no",
  foldcolumn = "0",
  number = false,
  relativenumber = false,
  winfixwidth = true,
  list = false,
  linebreak = true,
  breakindent = true,
  wrap = false,
  cursorline = false,
  fillchars = "eob: ",
  winhighlight = "CursorLine:Normal,CursorColumn:Normal,WinSeparator:"
    .. Highlights.AVANTE_SIDEBAR_WIN_SEPARATOR
    .. ",Normal:"
    .. Highlights.AVANTE_SIDEBAR_NORMAL,
  winbar = "",
  statusline = vim.o.laststatus == 0 and " " or "",
}

function Sidebar:render_header(winid, bufnr, header_text, hl, reverse_hl)
  if not Config.windows.sidebar_header.enabled then return end
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  local function format_segment(text, highlight) return "%#" .. highlight .. "#" .. text end

  if Config.windows.sidebar_header.rounded then
    header_text = format_segment(Utils.icon("", "『"), reverse_hl)
      .. format_segment(header_text, hl)
      .. format_segment(Utils.icon("", "』"), reverse_hl)
  else
    header_text = format_segment(" " .. header_text .. " ", hl)
  end

  local winbar_text
  if Config.windows.sidebar_header.align == "left" then
    winbar_text = header_text .. "%=" .. format_segment("", Highlights.AVANTE_SIDEBAR_WIN_HORIZONTAL_SEPARATOR)
  elseif Config.windows.sidebar_header.align == "center" then
    winbar_text = format_segment("%=", Highlights.AVANTE_SIDEBAR_WIN_HORIZONTAL_SEPARATOR)
      .. header_text
      .. format_segment("%=", Highlights.AVANTE_SIDEBAR_WIN_HORIZONTAL_SEPARATOR)
  elseif Config.windows.sidebar_header.align == "right" then
    winbar_text = format_segment("%=", Highlights.AVANTE_SIDEBAR_WIN_HORIZONTAL_SEPARATOR) .. header_text
  end

  api.nvim_set_option_value("winbar", winbar_text, { win = winid })
end

function Sidebar:render_result()
  if not Utils.is_valid_container(self.containers.result) then return end

  -- Use thread title if available, otherwise default to "Avante"
  local title = "Avante"
  if self.chat_history and self.chat_history.title and self.chat_history.title ~= "" and self.chat_history.title ~= "untitled" then
    title = self.chat_history.title
  end

  local header_text = Utils.icon("󰭻 ") .. title

  -- Add mode indicator (prefer configOptions over legacy modes)
  local mode_display = nil
  if self.acp_client and self.acp_client:has_config_options() then
    local config_opts = self.acp_client:all_config_options()
    local mode_opt = vim.iter(config_opts):find(function(o) return o.category == "mode" end)
    if mode_opt then
      mode_display = mode_opt.currentValue:upper()
      for _, val in ipairs(mode_opt.options) do
        if val.value == mode_opt.currentValue then
          mode_display = val.name
          break
        end
      end
    end
  end
  if not mode_display and self.current_mode_id then
    mode_display = self.current_mode_id:upper()
    if self.acp_client then
      local mode = self.acp_client:mode_by_id(self.current_mode_id)
      if mode then mode_display = mode.name end
    end
  end
  if mode_display then
    header_text = header_text .. " " .. Utils.icon("") .. "[" .. mode_display .. "]"
  end

  self:render_header(
    self.containers.result.winid,
    self.containers.result.bufnr,
    header_text,
    Highlights.TITLE,
    Highlights.REVERSED_TITLE
  )
end

---@param ask? boolean
function Sidebar:render_input(ask)
  if ask == nil then ask = true end
  if not Utils.is_valid_container(self.containers.input) then return end

  local header_text = string.format(
    "%s%s (" .. Config.mappings.sidebar.switch_windows .. ": switch focus)",
    Utils.icon("󱜸 "),
    ask and "Ask" or "Chat with"
  )

  if self.code.selection ~= nil then
    header_text = string.format(
      "%s%s (%d:%d) (%s: switch focus)",
      Utils.icon("󱜸 "),
      ask and "Ask" or "Chat with",
      self.code.selection.range.start.lnum,
      self.code.selection.range.finish.lnum,
      Config.mappings.sidebar.switch_windows
    )
  end

  self:render_header(
    self.containers.input.winid,
    self.containers.input.bufnr,
    header_text,
    Highlights.THIRD_TITLE,
    Highlights.REVERSED_THIRD_TITLE
  )
end

function Sidebar:render_selected_code()
  if not self.code.selection then return end
  if not Utils.is_valid_container(self.containers.selected_code) then return end

  local count = Utils.count_lines(self.code.selection.content)
  local max_shown = api.nvim_win_get_height(self.containers.selected_code.winid)
  if Config.windows.sidebar_header.enabled then max_shown = max_shown - 1 end

  local header_text = Utils.icon(" ") .. "Selected Code"
  if max_shown < count then header_text = string.format("%s (%d/%d lines)", header_text, max_shown, count) end

  self:render_header(
    self.containers.selected_code.winid,
    self.containers.selected_code.bufnr,
    header_text,
    Highlights.SUBTITLE,
    Highlights.REVERSED_SUBTITLE
  )
end

function Sidebar:bind_apply_key()
  if self.containers.result then
    vim.keymap.set(
      "n",
      Config.mappings.sidebar.apply_cursor,
      function() self:apply(true) end,
      { buffer = self.containers.result.bufnr, noremap = true, silent = true }
    )
  end
end

function Sidebar:unbind_apply_key()
  if self.containers.result then
    pcall(vim.keymap.del, "n", Config.mappings.sidebar.apply_cursor, { buffer = self.containers.result.bufnr })
  end
end

function Sidebar:bind_retry_user_request_key()
  if self.containers.result then
    vim.keymap.set(
      "n",
      Config.mappings.sidebar.retry_user_request,
      function() self:retry_user_request() end,
      { buffer = self.containers.result.bufnr, noremap = true, silent = true }
    )
  end
end

function Sidebar:unbind_retry_user_request_key()
  if self.containers.result then
    pcall(vim.keymap.del, "n", Config.mappings.sidebar.retry_user_request, { buffer = self.containers.result.bufnr })
  end
end

function Sidebar:bind_expand_tool_use_key(message_uuid)
  if self.containers.result then
    local expanded = self.expanded_message_uuids[message_uuid]
    vim.keymap.set(
      "n",
      Config.mappings.sidebar.expand_tool_use,
      function() self:handle_expand_message(message_uuid, not expanded) end,
      { buffer = self.containers.result.bufnr, noremap = true, silent = true }
    )
  end
end

function Sidebar:unbind_expand_tool_use_key()
  if self.containers.result then
    pcall(vim.keymap.del, "n", Config.mappings.sidebar.expand_tool_use, { buffer = self.containers.result.bufnr })
  end
end

function Sidebar:bind_edit_user_request_key()
  if self.containers.result then
    vim.keymap.set(
      "n",
      Config.mappings.sidebar.edit_user_request,
      function() self:edit_user_request() end,
      { buffer = self.containers.result.bufnr, noremap = true, silent = true }
    )
  end
end

function Sidebar:unbind_edit_user_request_key()
  if self.containers.result then
    pcall(vim.keymap.del, "n", Config.mappings.sidebar.edit_user_request, { buffer = self.containers.result.bufnr })
  end
end

function Sidebar:render_tool_use_control_buttons()
  local function show_current_tool_use_control_buttons()
    if self.current_tool_use_extmark_id then
      api.nvim_buf_del_extmark(
        self.containers.result.bufnr,
        TOOL_MESSAGE_KEYBINDING_NAMESPACE,
        self.current_tool_use_extmark_id
      )
    end

    local message_uuid, positions = self:get_current_tool_use_message_uuid()
    if not message_uuid then return end

    local expanded = self.expanded_message_uuids[message_uuid]
    local skip_line_count = self.skip_line_count or 0

    self.current_tool_use_extmark_id = api.nvim_buf_set_extmark(
      self.containers.result.bufnr,
      TOOL_MESSAGE_KEYBINDING_NAMESPACE,
      skip_line_count + positions[1] + 2,
      -1,
      {
        virt_text = {
          {
            string.format(" [%s: %s] ", Config.mappings.sidebar.expand_tool_use, expanded and "Collapse" or "Expand"),
            "AvanteInlineHint",
          },
        },
        virt_text_pos = "right_align",
        hl_group = "AvanteInlineHint",
        priority = PRIORITY,
      }
    )
  end
  local current_tool_use_message_uuid = self:get_current_tool_use_message_uuid()
  if current_tool_use_message_uuid then
    show_current_tool_use_control_buttons()
    self:bind_expand_tool_use_key(current_tool_use_message_uuid)
  else
    api.nvim_buf_clear_namespace(self.containers.result.bufnr, TOOL_MESSAGE_KEYBINDING_NAMESPACE, 0, -1)
    self:unbind_expand_tool_use_key()
  end
end

function Sidebar:bind_sidebar_keys(codeblocks)
  ---@param direction "next" | "prev"
  local function jump_to_codeblock(direction)
    local cursor_line = api.nvim_win_get_cursor(self.containers.result.winid)[1]
    ---@type AvanteCodeblock
    local target_block

    if direction == "next" then
      for _, block in ipairs(codeblocks) do
        if block.start_line > cursor_line then
          target_block = block
          break
        end
      end
      if not target_block and #codeblocks > 0 then target_block = codeblocks[1] end
    elseif direction == "prev" then
      for i = #codeblocks, 1, -1 do
        if codeblocks[i].end_line < cursor_line then
          target_block = codeblocks[i]
          break
        end
      end
      if not target_block and #codeblocks > 0 then target_block = codeblocks[#codeblocks] end
    end

    if target_block then
      api.nvim_win_set_cursor(self.containers.result.winid, { target_block.start_line, 0 })
      vim.cmd("normal! zz")
    else
      Utils.error("No codeblock found")
    end
  end

  ---@param direction "next" | "prev"
  local function jump_to_prompt(direction)
    local current_request_block = self:get_current_user_request_block()
    local current_line = Utils.get_cursor_pos(self.containers.result.winid)
    if not current_request_block then
      Utils.error("No prompt found")
      return
    end
    if
      (current_request_block.start_line > current_line and direction == "next")
      or (current_request_block.end_line < current_line and direction == "prev")
    then
      api.nvim_win_set_cursor(self.containers.result.winid, { current_request_block.start_line, 0 })
      return
    end
    local start_search_line = current_line
    local result_lines = Utils.get_buf_lines(0, -1, self.containers.result.bufnr)
    local end_search_line = direction == "next" and #result_lines or 1
    local step = direction == "next" and 1 or -1
    local query_pos ---@type integer|nil
    for i = start_search_line, end_search_line, step do
      local result_line = result_lines[i]
      if result_line == RESP_SEPARATOR then
        query_pos = direction == "next" and i + 1 or i - 1
        break
      end
    end
    if not query_pos then
      Utils.error("No other prompt found " .. (direction == "next" and "below" or "above"))
      return
    end
    current_request_block = self:get_current_user_request_block(query_pos)
    if not current_request_block then
      Utils.error("No prompt found")
      return
    end
    api.nvim_win_set_cursor(self.containers.result.winid, { current_request_block.start_line, 0 })
  end

  vim.keymap.set(
    "n",
    Config.mappings.sidebar.apply_all,
    function() self:apply(false) end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true }
  )
  vim.keymap.set(
    "n",
    Config.mappings.jump.next,
    function() jump_to_codeblock("next") end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true }
  )
  vim.keymap.set(
    "n",
    Config.mappings.jump.prev,
    function() jump_to_codeblock("prev") end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true }
  )
  vim.keymap.set(
    "n",
    Config.mappings.sidebar.next_prompt,
    function() jump_to_prompt("next") end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true }
  )
  vim.keymap.set(
    "n",
    Config.mappings.sidebar.prev_prompt,
    function() jump_to_prompt("prev") end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true }
  )
  vim.keymap.set(
    "n",
    Config.mappings.sidebar.cycle_mode,
    function() self:cycle_mode() end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true, desc = "avante: cycle session mode" }
  )
  vim.keymap.set(
    "n",
    "O",
    function() require("avante.config_option_selector").open() end,
    { buffer = self.containers.result.bufnr, noremap = true, silent = true, desc = "avante: open config options selector" }
  )
  -- Toggle plan container (Cmd-t) — bind in both normal and insert mode for result buffer
  local toggle_plan_key = Config.mappings.sidebar.toggle_plan
  if toggle_plan_key then
    vim.keymap.set(
      { "n", "i" },
      toggle_plan_key,
      function() self:toggle_plan_container() end,
      { buffer = self.containers.result.bufnr, noremap = true, silent = true, desc = "avante: toggle plan/tasks panel" }
    )
  end
end

function Sidebar:unbind_sidebar_keys()
  if Utils.is_valid_container(self.containers.result) then
    pcall(vim.keymap.del, "n", Config.mappings.sidebar.apply_all, { buffer = self.containers.result.bufnr })
    pcall(vim.keymap.del, "n", Config.mappings.jump.next, { buffer = self.containers.result.bufnr })
    pcall(vim.keymap.del, "n", Config.mappings.jump.prev, { buffer = self.containers.result.bufnr })
  end
end

---@param opts AskOptions
function Sidebar:on_mount(opts)
  self:setup_window_navigation(self.containers.result)

  -- Add keymap to add current buffer while sidebar is open
  if Config.behaviour.auto_set_keymaps and Config.mappings.files and Config.mappings.files.add_current then
    vim.keymap.set("n", Config.mappings.files.add_current, function()
      if self:is_open() and self.file_selector:add_current_buffer() then
        vim.notify("Added current buffer to file selector", vim.log.levels.DEBUG, { title = "Avante" })
      else
        vim.notify("Failed to add current buffer", vim.log.levels.WARN, { title = "Avante" })
      end
    end, {
      desc = "avante: add current buffer to file selector",
      noremap = true,
      silent = true,
    })
  end

  api.nvim_set_option_value("wrap", Config.windows.wrap, { win = self.containers.result.winid })

  local current_apply_extmark_id = nil

  ---@param block AvanteCodeblock
  local function show_apply_button(block)
    if current_apply_extmark_id then
      api.nvim_buf_del_extmark(self.containers.result.bufnr, CODEBLOCK_KEYBINDING_NAMESPACE, current_apply_extmark_id)
    end

    current_apply_extmark_id = api.nvim_buf_set_extmark(
      self.containers.result.bufnr,
      CODEBLOCK_KEYBINDING_NAMESPACE,
      block.start_line - 1,
      -1,
      {
        virt_text = {
          {
            string.format(
              " [<%s>: apply this, <%s>: apply all] ",
              Config.mappings.sidebar.apply_cursor,
              Config.mappings.sidebar.apply_all
            ),
            "AvanteInlineHint",
          },
        },
        virt_text_pos = "right_align",
        hl_group = "AvanteInlineHint",
        priority = PRIORITY,
      }
    )
  end

  local current_user_request_block_extmark_id = nil

  local function show_user_request_block_control_buttons()
    if current_user_request_block_extmark_id then
      api.nvim_buf_del_extmark(
        self.containers.result.bufnr,
        USER_REQUEST_BLOCK_KEYBINDING_NAMESPACE,
        current_user_request_block_extmark_id
      )
    end

    local block = self:get_current_user_request_block()
    if not block then return end

    current_user_request_block_extmark_id = api.nvim_buf_set_extmark(
      self.containers.result.bufnr,
      USER_REQUEST_BLOCK_KEYBINDING_NAMESPACE,
      block.start_line - 1,
      -1,
      {
        virt_text = {
          {
            string.format(
              " [<%s>: retry, <%s>: edit] ",
              Config.mappings.sidebar.retry_user_request,
              Config.mappings.sidebar.edit_user_request
            ),
            "AvanteInlineHint",
          },
        },
        virt_text_pos = "right_align",
        hl_group = "AvanteInlineHint",
        priority = PRIORITY,
      }
    )
  end

  ---@type AvanteCodeblock[]
  local codeblocks = {}

  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = self.augroup,
    buffer = self.containers.result.bufnr,
    callback = function(ev)
      self:render_tool_use_control_buttons()

      local in_codeblock = is_cursor_in_codeblock(codeblocks)

      if in_codeblock then
        show_apply_button(in_codeblock)
        self:bind_apply_key()
      else
        api.nvim_buf_clear_namespace(ev.buf, CODEBLOCK_KEYBINDING_NAMESPACE, 0, -1)
        self:unbind_apply_key()
      end

      local in_user_request_block = self:is_cursor_in_user_request_block()
      if in_user_request_block then
        show_user_request_block_control_buttons()
        self:bind_retry_user_request_key()
        self:bind_edit_user_request_key()
      else
        api.nvim_buf_clear_namespace(ev.buf, USER_REQUEST_BLOCK_KEYBINDING_NAMESPACE, 0, -1)
        self:unbind_retry_user_request_key()
        self:unbind_edit_user_request_key()
      end
    end,
  })

  if self.code.bufnr and api.nvim_buf_is_valid(self.code.bufnr) then
    api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
      group = self.augroup,
      buffer = self.containers.result.bufnr,
      callback = function(ev)
        codeblocks = parse_codeblocks(ev.buf)
        self:bind_sidebar_keys(codeblocks)
      end,
    })

    api.nvim_create_autocmd("User", {
      group = self.augroup,
      pattern = VIEW_BUFFER_UPDATED_PATTERN,
      callback = function()
        if not Utils.is_valid_container(self.containers.result) then return end
        codeblocks = parse_codeblocks(self.containers.result.bufnr)
        self:bind_sidebar_keys(codeblocks)
      end,
    })
  end

  api.nvim_create_autocmd("BufLeave", {
    group = self.augroup,
    buffer = self.containers.result.bufnr,
    callback = function() self:unbind_sidebar_keys() end,
  })

  self:render_result()
  self:render_input(opts.ask)
  self:render_selected_code()

  if self.containers.selected_code ~= nil then
    local selected_code_buf = self.containers.selected_code.bufnr
    if selected_code_buf ~= nil then
      if self.code.selection ~= nil then
        Utils.unlock_buf(selected_code_buf)
        local lines = vim.split(self.code.selection.content, "\n")
        api.nvim_buf_set_lines(selected_code_buf, 0, -1, false, lines)
        Utils.lock_buf(selected_code_buf)
      end
      if self.code.bufnr and api.nvim_buf_is_valid(self.code.bufnr) then
        local ts_ok, ts_highlighter = pcall(require, "vim.treesitter.highlighter")
        if ts_ok and ts_highlighter.active[self.code.bufnr] then
          -- Treesitter highlighting is active in the code buffer, activate it
          -- it in code selection buffer as well.
          local filetype = vim.bo[self.code.bufnr].filetype
          local lang = vim.treesitter.language.get_lang(filetype or "")
          if lang and lang ~= "" then vim.treesitter.start(selected_code_buf, lang) end
        end
        -- Try the old syntax highlighting
        local syntax = api.nvim_get_option_value("syntax", { buf = self.code.bufnr })
        if syntax and syntax ~= "" then api.nvim_set_option_value("syntax", syntax, { buf = selected_code_buf }) end
      end
    end
  end

  api.nvim_create_autocmd("BufEnter", {
    group = self.augroup,
    buffer = self.containers.result.bufnr,
    callback = function()
      if Config.behaviour.auto_focus_sidebar then
        self:focus()
        if Utils.is_valid_container(self.containers.input, true) then
          api.nvim_set_current_win(self.containers.input.winid)
          vim.defer_fn(function()
            if Config.windows.ask.start_insert then vim.cmd("noautocmd startinsert!") end
          end, 300)
        end
      end
      return true
    end,
  })

  for _, container in pairs(self.containers) do
    if container.mount and container.bufnr and api.nvim_buf_is_valid(container.bufnr) then
      Utils.mark_as_sidebar_buffer(container.bufnr)
    end
  end
end

--- Given a desired container name, returns the window ID of the first valid container
--- situated above it in the sidebar's order.
--- @param container_name string The name of the container to start searching from.
--- @return integer|nil The window ID of the previous valid container, or nil.
function Sidebar:get_split_candidate(container_name)
  local start_index = 0
  for i, name in ipairs(SIDEBAR_CONTAINERS) do
    if name == container_name then
      start_index = i
      break
    end
  end

  if start_index > 1 then
    for i = start_index - 1, 1, -1 do
      local container = self.containers[SIDEBAR_CONTAINERS[i]]
      if Utils.is_valid_container(container, true) then return container.winid end
    end
  end
  return nil
end

---Cycles focus over sidebar components.
---@param direction "next" | "previous"
function Sidebar:switch_window_focus(direction)
  local current_winid = vim.api.nvim_get_current_win()
  local current_index = nil
  local ordered_winids = {}

  for _, name in ipairs(SIDEBAR_CONTAINERS) do
    local container = self.containers[name]
    if container and container.winid then
      table.insert(ordered_winids, container.winid)
      if container.winid == current_winid then current_index = #ordered_winids end
    end
  end

  if current_index and #ordered_winids > 1 then
    local next_index
    if direction == "next" then
      next_index = (current_index % #ordered_winids) + 1
    elseif direction == "previous" then
      next_index = current_index - 1
      if next_index < 1 then next_index = #ordered_winids end
    else
      error("Invalid 'direction' parameter: " .. direction)
    end

    local target_winid = ordered_winids[next_index]
    if target_winid and vim.api.nvim_win_is_valid(target_winid) then
      vim.api.nvim_set_current_win(target_winid)
    end
  end
end

---Sets up focus switching shortcuts for a sidebar component
---@param container NuiSplit
function Sidebar:setup_window_navigation(container)
  local buf = api.nvim_win_get_buf(container.winid)
  Utils.safe_keymap_set(
    { "n", "i" },
    Config.mappings.sidebar.switch_windows,
    function() self:switch_window_focus("next") end,
    { buffer = buf, noremap = true, silent = true, nowait = true }
  )
  if Config.mappings.sidebar.reverse_switch_windows then
    Utils.safe_keymap_set(
      { "n", "i" },
      Config.mappings.sidebar.reverse_switch_windows,
      function() self:switch_window_focus("previous") end,
      { buffer = buf, noremap = true, silent = true, nowait = true }
    )
  end
end

function Sidebar:resize()
  for _, container in pairs(self.containers) do
    if container.winid and api.nvim_win_is_valid(container.winid) then
      if self.is_in_full_view then
        api.nvim_win_set_width(container.winid, vim.o.columns - 1)
      else
        api.nvim_win_set_width(container.winid, Config.get_window_width())
      end
    end
  end
  self:render_result()
  self:render_input()
  self:render_selected_code()
  vim.defer_fn(function() vim.cmd("AvanteRefresh") end, 200)
end

function Sidebar:render_logo()
  local logo_lines = vim.split(logo, "\n")
  local max_width = 30
  --- get editor width
  local editor_width = vim.api.nvim_win_get_width(self.containers.result.winid)
  local padding = math.floor((editor_width - max_width) / 2)
  Utils.unlock_buf(self.containers.result.bufnr)
  for i, line in ipairs(logo_lines) do
    --- center logo
    line = vim.trim(line)
    vim.api.nvim_buf_set_lines(self.containers.result.bufnr, i - 1, i, false, { string.rep(" ", padding) .. line })
    --- apply gradient color
    if line ~= "" then
      local hl_group = "AvanteLogoLine" .. i
      vim.api.nvim_buf_set_extmark(self.containers.result.bufnr, RESULT_BUF_HL_NAMESPACE, i - 1, padding, {
        end_col = padding + #line,
        hl_group = hl_group,
      })
    end
  end
  Utils.lock_buf(self.containers.result.bufnr)
  return #logo_lines
end

function Sidebar:toggle_code_window()
  -- Collect all windows that do not belong to the sidebar
  local winids = vim
    .iter(api.nvim_tabpage_list_wins(self.id))
    :filter(function(winid) return not self:is_sidebar_winid(winid) end)
    :totable()

  if self.is_in_full_view then
    -- Transitioning to normal view: restore sizes of all non-sidebar windows
    for _, winid in ipairs(winids) do
      local old_size = self.win_size_store[winid]
      if old_size then
        api.nvim_win_set_width(winid, old_size.width)
        api.nvim_win_set_height(winid, old_size.height)
      end
    end
  else
    -- Transitioning to full view: hide all non-sidebar windows
    -- We need do this in 2 phases: first phase is to collect window sizes
    -- and 2nd phase is to actually maximize the sidebar. If we attempt to do
    -- everything is one pass sizes of windows may change in the process and
    -- we'll end up with a mess.
    self.win_size_store = {}
    for _, winid in ipairs(winids) do
      if Utils.is_floating_window(winid) then
        api.nvim_win_close(winid, true)
      else
        self.win_size_store[winid] = { width = api.nvim_win_get_width(winid), height = api.nvim_win_get_height(winid) }
      end
    end

    if self:get_layout() == "vertical" then
      api.nvim_win_set_width(self.code.winid, 0)
      api.nvim_win_set_width(self.containers.result.winid, vim.o.columns - 1)
    else
      api.nvim_win_set_height(self.containers.result.winid, vim.o.lines)
    end
  end

  self.is_in_full_view = not self.is_in_full_view
end

--- Toggle full-screen mode for the currently focused container
function Sidebar:toggle_fullscreen_edit()
  -- Get the currently focused window
  local current_winid = api.nvim_get_current_win()
  local focused_container = self:get_sidebar_window(current_winid)

  if not focused_container then
    Utils.warn("No sidebar container is currently focused")
    return
  end

  if self.is_in_fullscreen_edit then
    -- Exit fullscreen mode: restore all hidden containers
    self.is_in_fullscreen_edit = false

    -- Restore all previously visible containers
    if self.fullscreen_hidden_containers then
      for container_name, container in pairs(self.fullscreen_hidden_containers) do
        if container and Utils.is_valid_container(container) then
          -- Remount the container
          container:mount()
        elseif container_name == "selected_code" then
          self:create_selected_code_container()
        elseif container_name == "selected_files" then
          self:create_selected_files_container()
        elseif container_name == "plan" then
          self:create_plan_container()
        end
      end
      self.fullscreen_hidden_containers = nil
    end

    self:adjust_layout()
    Utils.info("Exited fullscreen mode")
  else
    -- Enter fullscreen mode: hide all other containers
    self.is_in_fullscreen_edit = true
    self.fullscreen_hidden_containers = {}

    -- Hide all containers except the focused one
    for container_name, container in pairs(self.containers) do
      if container ~= focused_container and Utils.is_valid_container(container, true) then
        -- Store the container before hiding it
        self.fullscreen_hidden_containers[container_name] = container
        -- Unmount (hide) the container
        container:unmount()
      end
    end

    self:adjust_layout()
    Utils.info("Entered fullscreen mode - Run /toggle-full-screen again to exit")
  end
end

function Sidebar:toggle_input_fullscreen()
  if not Utils.is_valid_container(self.containers.input, true) then
    Utils.warn("Input container not available")
    return
  end

  local input_winid = self.containers.input.winid
  
  if self.is_input_fullscreen then
    -- Exit fullscreen mode: restore saved height
    self.is_input_fullscreen = false
    
    -- Restore the saved height
    local saved_height = self._input_height_before_fullscreen
    if saved_height and saved_height > 0 then
      api.nvim_win_set_height(input_winid, saved_height)
    else
      -- Fallback to config height if saved height is invalid
      api.nvim_win_set_height(input_winid, Config.windows.input.height)
    end
    self._input_height_before_fullscreen = nil
    
    -- Adjust layout to restore other containers
    self:adjust_layout()
    Utils.info("Input: normal size")
  else
    -- Save current height before going fullscreen
    self._input_height_before_fullscreen = api.nvim_win_get_height(input_winid)
    
    -- Enter fullscreen mode: maximize input height
    self.is_input_fullscreen = true
    
    -- Calculate and set fullscreen height
    if self:get_layout() == "vertical" then
      local available_height = vim.o.lines
      local new_height = math.floor(available_height * 0.8)
      api.nvim_win_set_height(input_winid, new_height)
    else
      -- In horizontal layout, take most of the result window height
      if Utils.is_valid_container(self.containers.result, true) then
        local result_height = api.nvim_win_get_height(self.containers.result.winid)
        local new_height = math.floor(result_height * 0.9)
        api.nvim_win_set_height(input_winid, new_height)
      end
    end
    
    -- Don't call adjust_layout() when entering fullscreen - it would override our height
    Utils.info("Input: fullscreen mode (<C-f> to exit)")
  end
end

--- Initialize the sidebar instance.
--- @return avante.Sidebar The Sidebar instance.
function Sidebar:initialize()
  self.code.winid = api.nvim_get_current_win()
  self.code.bufnr = api.nvim_get_current_buf()
  self.code.selection = Utils.get_visual_selection_and_range()

  if not self.code.bufnr or not api.nvim_buf_is_valid(self.code.bufnr) then return self end

  -- check if the filetype of self.code.bufnr is disabled
  local buf_ft = api.nvim_get_option_value("filetype", { buf = self.code.bufnr })
  if vim.list_contains(Config.selector.exclude_auto_select, buf_ft) then return self end

  self.file_selector:reset()

  -- Only auto-add current file if configured to do so
  if Config.behaviour.auto_add_current_file then
    local buf_path = api.nvim_buf_get_name(self.code.bufnr)
    -- Skip virtual/special buffer schemes (fern://, fugitive://, oil://, etc.)
    if buf_path ~= "" and not buf_path:match("^%w+://") then
      -- if the filepath is outside of the current working directory then we want the absolute path
      local filepath = Utils.file.is_in_project(buf_path) and Utils.relative_path(buf_path) or buf_path
      Utils.debug("Sidebar:initialize adding buffer to file selector", buf_path)

      local stat = vim.uv.fs_stat(filepath)
      if stat == nil or stat.type == "file" then self.file_selector:add_selected_file(filepath) end
    end
  end

  -- Skip loading old history when we're about to create a new thread — new_thread() handles it
  if not self._skip_history_load then
    self:reload_chat_history()

    -- Restore avante mode from persisted chat history
    self.current_avante_mode = self.chat_history and self.chat_history.avante_mode or nil
  end

  return self
end

function Sidebar:is_focused_on_result()
  return self:is_open() and self.containers.result and self.containers.result.winid == api.nvim_get_current_win()
end

---Locates container object by its window ID
---@param winid integer
---@return NuiSplit|nil
function Sidebar:get_sidebar_window(winid)
  for _, container in pairs(self.containers) do
    if container.winid == winid then return container end
  end
end

---Checks if a window with given ID belongs to the sidebar
---@param winid integer
---@return boolean
function Sidebar:is_sidebar_winid(winid) return self:get_sidebar_window(winid) ~= nil end

---@return boolean
function Sidebar:should_auto_scroll()
  if not self.containers.result or not self.containers.result.winid then return false end
  if not api.nvim_win_is_valid(self.containers.result.winid) then return false end

  local win_height = api.nvim_win_get_height(self.containers.result.winid)
  local total_lines = api.nvim_buf_line_count(self.containers.result.bufnr)

  local topline = vim.fn.line("w0", self.containers.result.winid)

  local last_visible_line = topline + win_height - 1

  local is_scrolled_to_bottom = last_visible_line >= total_lines - 1

  return is_scrolled_to_bottom
end

Sidebar.throttled_update_content = Utils.throttle(function(self, ...)
  local args = { ... }
  self:update_content(unpack(args))
end, 50)

---@param content string concatenated content of the buffer
---@param opts? {focus?: boolean, scroll?: boolean, backspace?: integer, callback?: fun(): nil} whether to focus the result view
function Sidebar:update_content(content, opts)
  if not Utils.is_valid_container(self.containers.result) then return end

  local should_auto_scroll = self:should_auto_scroll()

  opts = vim.tbl_deep_extend(
    "force",
    { focus = false, scroll = should_auto_scroll and self.scroll, callback = nil },
    opts or {}
  )

  local history_lines
  local tool_message_positions
  if not self._cached_history_lines or self._history_cache_invalidated then
    history_lines, tool_message_positions = self:get_history_lines(self.chat_history, self.show_logo)
    self.tool_message_positions = tool_message_positions
    self._cached_history_lines = history_lines
    self._history_cache_invalidated = false
  else
    history_lines = vim.deepcopy(self._cached_history_lines)
  end

  if content ~= nil and content ~= "" then
    table.insert(history_lines, Line:new({ { "" } }))
    for _, line in ipairs(vim.split(content, "\n")) do
      table.insert(history_lines, Line:new({ { line } }))
    end
  end

  if not Utils.is_valid_container(self.containers.result) then return end

  self:clear_state()

  local skip_line_count = 0
  if self.show_logo then
    skip_line_count = self:render_logo()
    self.skip_line_count = skip_line_count
  end

  local bufnr = self.containers.result.bufnr
  Utils.unlock_buf(bufnr)

  Utils.update_buffer_lines(RESULT_BUF_HL_NAMESPACE, bufnr, self.old_result_lines, history_lines, skip_line_count)

  self.old_result_lines = history_lines

  api.nvim_set_option_value("filetype", "Avante", { buf = bufnr })
  Utils.lock_buf(bufnr)

  vim.defer_fn(function()
    if self.permission_button_options and self.permission_handler then
      local cur_winid = api.nvim_get_current_win()
      if cur_winid == self.containers.result.winid then
        local line_count = api.nvim_buf_line_count(bufnr)
        api.nvim_win_set_cursor(cur_winid, { line_count - 3, 0 })
      end
    end
  end, 100)

  if opts.focus and not self:is_focused_on_result() then
    xpcall(function() api.nvim_set_current_win(self.containers.result.winid) end, function(err)
      Utils.debug("Failed to set current win:", err)
      return err
    end)
  end

  if opts.scroll then Utils.buf_scroll_to_end(bufnr) end

  if opts.callback then vim.schedule(opts.callback) end

  vim.schedule(function()
    self:render_state()
    self:render_tool_use_control_buttons()
    vim.defer_fn(function() vim.cmd("redraw") end, 10)
  end)

  return self
end

---@param timestamp string|osdate
---@param provider string
---@param model string
---@param request string
---@param selected_filepaths string[]
---@param selected_code AvanteSelectedCode?
---@return string
local function render_chat_record_prefix(timestamp, provider, model, request, selected_filepaths, selected_code)
  local res
  local acp_provider = Config.acp_providers[provider]
  if acp_provider then
    res = "- Datetime: " .. timestamp .. "\n" .. "- ACP:      " .. provider
  else
    provider = provider or "unknown"
    model = model or "unknown"
    res = "- Datetime: " .. timestamp .. "\n" .. "- Model:    " .. provider .. "/" .. model
  end
  if selected_filepaths ~= nil and #selected_filepaths > 0 then
    res = res .. "\n- Selected files:"
    for _, path in ipairs(selected_filepaths) do
      res = res .. "\n  - " .. path
    end
  end
  if selected_code ~= nil then
    res = res
      .. "\n\n- Selected code: "
      .. "\n\n```"
      .. (selected_code.file_type or "")
      .. (selected_code.path and " " .. selected_code.path or "")
      .. "\n"
      .. selected_code.content
      .. "\n```"
  end

  return res .. "\n\n> " .. request:gsub("\n", "\n> "):gsub("([%w-_]+)%b[]", "`%0`")
end

local function calculate_config_window_position()
  local position = Config.windows.position
  if position == "smart" then
    -- get editor width
    local editor_width = vim.o.columns
    -- get editor height
    local editor_height = vim.o.lines * 3

    if editor_width > editor_height then
      position = "right"
    else
      position = "bottom"
    end
  end

  ---@cast position -"smart", -string
  return position
end

function Sidebar:get_layout()
  return vim.tbl_contains({ "left", "right" }, calculate_config_window_position()) and "vertical" or "horizontal"
end

---@param ctx table
---@param message avante.HistoryMessage
---@param messages avante.HistoryMessage[]
---@param ignore_record_prefix boolean | nil
---@return avante.ui.Line[]
function Sidebar:_get_message_lines(ctx, message, messages, ignore_record_prefix)
  local expanded = self.expanded_message_uuids[message.uuid]
  -- Default: tool calls that are still generating are expanded; completed ones are collapsed
  if expanded == nil and message.message and message.message.role == "assistant" then
    local content = message.message.content
    if type(content) == "table" and content.type == "tool_use" then
      expanded = (message.is_calling == true)
    end
  end
  if message.visible == false then return {} end
  local lines = Render.message_to_lines(message, messages, expanded)
  if message.is_user_submission and not ignore_record_prefix then
    ctx.selected_filepaths = message.selected_filepaths
    local text = table.concat(vim.tbl_map(function(line) return tostring(line) end, lines), "\n")
    local prefix = render_chat_record_prefix(
      message.timestamp,
      message.provider,
      message.model,
      text,
      message.selected_filepaths,
      message.selected_code
    )
    local res = {}
    for _, line_ in ipairs(vim.split(prefix, "\n")) do
      table.insert(res, Line:new({ { line_ } }))
    end
    return res
  end
  if message.message.role == "user" then
    local res = {}
    for _, line_ in ipairs(lines) do
      local sections = { { "> " } }
      sections = vim.list_extend(sections, line_.sections)
      table.insert(res, Line:new(sections))
    end
    return res
  end
  if message.message.role == "assistant" then
    if History.Helpers.is_tool_use_message(message) then return lines end
    local text = table.concat(vim.tbl_map(function(line) return tostring(line) end, lines), "\n")
    local transformed = transform_result_content(text, ctx.prev_filepath)
    ctx.prev_filepath = transformed.current_filepath
    local displayed_content = generate_display_content(transformed)
    local res = {}
    for _, line_ in ipairs(vim.split(displayed_content, "\n")) do
      table.insert(res, Line:new({ { line_ } }))
    end
    return res
  end
  return lines
end

local _message_to_lines_lru_cache = LRUCache:new(100)

---@param ctx table
---@param message avante.HistoryMessage
---@param messages avante.HistoryMessage[]
---@param ignore_record_prefix boolean | nil
---@return avante.ui.Line[]
function Sidebar:get_message_lines(ctx, message, messages, ignore_record_prefix)
  local expanded = self.expanded_message_uuids[message.uuid]
  if message.state == "generating" or message.is_calling then
    local lines = self:_get_message_lines(ctx, message, messages, ignore_record_prefix)
    if self.permission_handler and self.permission_button_options then
      -- Show question text if this is an AskUserQuestion permission request
      if self.permission_question_text then
        table.insert(lines, Line:new({ { "" } }))
        table.insert(
          lines,
          Line:new({ { Utils.icon("❓ ") .. "Question", Highlights.AVANTE_THINKING } })
        )
        table.insert(lines, Line:new({ { "" } }))
        for _, q_line in ipairs(vim.split(self.permission_question_text, "\n")) do
          table.insert(lines, Line:new({ { "  " .. q_line } }))
        end
      end
      local group_label = self.permission_question_text and "Answer: " or "Waiting for Confirmation... "
      local button_group_line = ButtonGroupLine:new(self.permission_button_options, {
        on_click = self.permission_handler,
        group_label = group_label,
      })
      table.insert(lines, Line:new({ { "" } }))
      table.insert(lines, button_group_line)
    end
    return lines
  end
  local text_len = 0
  local content = message.message.content
  if type(content) == "table" then
    for _, item in ipairs(content) do
      if type(item) == "string" then
        text_len = text_len + #item
      else
        for _, subitem in pairs(item) do
          if type(subitem) == "string" then text_len = text_len + #subitem end
        end
      end
    end
  elseif type(content) == "string" then
    text_len = #content
  end
  local cache_key = message.uuid
    .. ":"
    .. message.state
    .. ":"
    .. tostring(text_len)
    .. ":"
    .. tostring(expanded == true)
  local cached_lines = _message_to_lines_lru_cache:get(cache_key)
  if cached_lines then return cached_lines end
  local lines = self:_get_message_lines(ctx, message, messages, ignore_record_prefix)
  --- trim suffix empty lines
  while #lines > 0 and tostring(lines[#lines]) == "" do
    table.remove(lines)
  end
  _message_to_lines_lru_cache:set(cache_key, lines)
  return lines
end

---@param history avante.ChatHistory
---@param ignore_record_prefix boolean | nil
---@return avante.ui.Line[] history_lines
---@return table<string, [integer, integer]> tool_message_positions
function Sidebar:get_history_lines(history, ignore_record_prefix)
  local history_messages = History.get_history_messages(history)
  local ctx = {}
  ---@type avante.ui.Line[]
  local res = {}
  local tool_message_positions = {}
  local is_first_user_submission = true
  for _, message in ipairs(history_messages) do
    local lines = self:get_message_lines(ctx, message, history_messages, ignore_record_prefix)
    if #lines == 0 then goto continue end
    if message.is_user_submission then
      if not is_first_user_submission then
        if ignore_record_prefix then
          res = vim.list_extend(res, { Line:new({ { "" } }), Line:new({ { "" } }) })
        else
          res = vim.list_extend(res, { Line:new({ { "" } }), Line:new({ { RESP_SEPARATOR } }), Line:new({ { "" } }) })
        end
      end
      is_first_user_submission = false
    end
    if message.message.role == "assistant" and not message.just_for_display and tostring(lines[1]) ~= "" then
      table.insert(lines, 1, Line:new({ { "" } }))
      table.insert(lines, 1, Line:new({ { "" } }))
    end
    if History.Helpers.is_tool_use_message(message) then
      tool_message_positions[message.uuid] = { #res, #res + #lines }
    end
    res = vim.list_extend(res, lines)
    ::continue::
  end
  table.insert(res, Line:new({ { "" } }))
  table.insert(res, Line:new({ { "" } }))
  table.insert(res, Line:new({ { "" } }))
  return res, tool_message_positions
end

---@param message avante.HistoryMessage
---@param messages avante.HistoryMessage[]
---@param ctx table
---@return string | nil
local function render_message(message, messages, ctx)
  if message.visible == false then return nil end
  local text = Render.message_to_text(message, messages)
  if text == "" then return nil end
  if message.is_user_submission then
    ctx.selected_filepaths = message.selected_filepaths
    local prefix = render_chat_record_prefix(
      message.timestamp,
      message.provider,
      message.model,
      text,
      message.selected_filepaths,
      message.selected_code
    )
    return prefix
  end
  if message.message.role == "user" then
    local lines = vim.split(text, "\n")
    lines = vim.iter(lines):map(function(line) return "> " .. line end):totable()
    text = table.concat(lines, "\n")
    return text
  end
  if message.message.role == "assistant" then
    local transformed = transform_result_content(text, ctx.prev_filepath)
    ctx.prev_filepath = transformed.current_filepath
    local displayed_content = generate_display_content(transformed)
    return displayed_content
  end
  return ""
end

---@param history avante.ChatHistory
---@return string
function Sidebar.render_history_content(history)
  local history_messages = History.get_history_messages(history)
  local ctx = {}
  local group = {}
  for _, message in ipairs(history_messages) do
    local text = render_message(message, history_messages, ctx)
    if text == nil then goto continue end
    if message.is_user_submission then table.insert(group, {}) end
    local last_item = group[#group]
    if last_item == nil then
      table.insert(group, {})
      last_item = group[#group]
    end
    if message.message.role == "assistant" and not message.just_for_display and text:sub(1, 2) ~= "\n\n" then
      text = "\n\n" .. text
    end
    table.insert(last_item, text)
    ::continue::
  end
  local pieces = {}
  for _, item in ipairs(group) do
    table.insert(pieces, table.concat(item, ""))
  end
  return table.concat(pieces, "\n\n" .. RESP_SEPARATOR .. "\n\n") .. "\n\n"
end

function Sidebar:update_content_with_history()
  self:reload_chat_history()
  self:update_content("")
end

---@param position? integer
---@return string, integer
function Sidebar:get_content_between_separators(position)
  local separator = RESP_SEPARATOR
  local cursor_line = position or Utils.get_cursor_pos()
  local lines = Utils.get_buf_lines(0, -1, self.containers.result.bufnr)
  local start_line, end_line

  for i = cursor_line, 1, -1 do
    if lines[i] == separator then
      start_line = i + 1
      break
    end
  end
  start_line = start_line or 1

  for i = cursor_line, #lines do
    if lines[i] == separator then
      end_line = i - 1
      break
    end
  end
  end_line = end_line or #lines

  if lines[cursor_line] == separator then
    if cursor_line > 1 and lines[cursor_line - 1] ~= separator then
      end_line = cursor_line - 1
    elseif cursor_line < #lines and lines[cursor_line + 1] ~= separator then
      start_line = cursor_line + 1
    end
  end

  local content = table.concat(vim.list_slice(lines, start_line, end_line), "\n")
  return content, start_line
end

function Sidebar:clear_history(args, cb)
  self.current_state = nil
  if next(self.chat_history) ~= nil then
    self.chat_history.messages = {}
    self.chat_history.entries = {}
    Path.history.save(self.code.bufnr, self.chat_history)
    self._history_cache_invalidated = true
    self:reload_chat_history()
    self:update_content_with_history()
    self:update_content(
      "Chat history cleared",
      { focus = false, scroll = false, callback = function() self:focus_input() end }
    )
    if cb then cb(args) end
  else
    self:update_content(
      "Chat history is already empty",
      { focus = false, scroll = false, callback = function() self:focus_input() end }
    )
  end
end

function Sidebar:clear_state()
  if self.state_extmark_id and self.containers.result then
    pcall(api.nvim_buf_del_extmark, self.containers.result.bufnr, STATE_NAMESPACE, self.state_extmark_id)
  end
  self.state_extmark_id = nil
  self.state_spinner_idx = 1
  if self.state_timer then self.state_timer:stop() end
end

function Sidebar:render_state()
  if not Utils.is_valid_container(self.containers.result) then return end
  if not self.current_state then return end
  local lines = vim.api.nvim_buf_get_lines(self.containers.result.bufnr, 0, -1, false)
  if self.state_extmark_id then
    api.nvim_buf_del_extmark(self.containers.result.bufnr, STATE_NAMESPACE, self.state_extmark_id)
  end
  local spinner_chars = self.state_spinner_chars
  if self.current_state == "thinking" then spinner_chars = self.thinking_spinner_chars end
  local hl = "AvanteStateSpinnerGenerating"
  if self.current_state == "tool calling" then hl = "AvanteStateSpinnerToolCalling" end
  if self.current_state == "failed" then hl = "AvanteStateSpinnerFailed" end
  if self.current_state == "succeeded" then hl = "AvanteStateSpinnerSucceeded" end
  if self.current_state == "searching" then hl = "AvanteStateSpinnerSearching" end
  if self.current_state == "thinking" then hl = "AvanteStateSpinnerThinking" end
  if self.current_state == "compacting" then hl = "AvanteStateSpinnerCompacting" end
  local spinner_char = spinner_chars[self.state_spinner_idx]
  if not spinner_char then spinner_char = spinner_chars[1] end
  self.state_spinner_idx = (self.state_spinner_idx % #spinner_chars) + 1
  if
    self.current_state ~= "generating"
    and self.current_state ~= "tool calling"
    and self.current_state ~= "thinking"
    and self.current_state ~= "compacting"
  then
    spinner_char = ""
  end
  local virt_line
  if spinner_char == "" then
    virt_line = " " .. self.current_state .. " "
  else
    virt_line = " " .. spinner_char .. " " .. self.current_state .. " "
  end

  local win_width = api.nvim_win_get_width(self.containers.result.winid)
  local padding = math.floor((win_width - vim.fn.strdisplaywidth(virt_line)) / 2)
  local centered_virt_lines = {
    { { string.rep(" ", padding) }, { virt_line, hl } },
  }

  local line_num = math.max(0, #lines - 2)
  self.state_extmark_id = api.nvim_buf_set_extmark(self.containers.result.bufnr, STATE_NAMESPACE, line_num, 0, {
    virt_lines = centered_virt_lines,
    hl_eol = true,
    hl_mode = "combine",
  })
  self.state_timer = vim.defer_fn(function() self:render_state() end, 160)
end

function Sidebar:init_current_project(args, cb)
  local user_input = [[
You are a responsible senior development engineer, and you are about to leave your position. Please carefully analyze the entire project and generate a handover document to be stored in the AGENTS.md file, so that subsequent developers can quickly get up to speed. The requirements are as follows:
- If there is an AGENTS.md file in the project root directory, combine it with the existing AGENTS.md content to generate a new AGENTS.md.
- If the existing AGENTS.md content conflicts with the newly generated content, replace the conflicting old parts with the new content.
- If there is no AGENTS.md file in the project root directory, create a new AGENTS.md file and write the new content in it.]]
  self:new_chat(args, cb)
  self.code.selection = nil
  self.file_selector:reset()
  if self.containers.selected_files then self.containers.selected_files:unmount() end
  vim.api.nvim_exec_autocmds("User", { pattern = "AvanteInputSubmitted", data = { request = user_input } })
end

function Sidebar:compact_history_messages(args, cb)
  local history_memory = self.chat_history.memory
  local messages = History.get_history_messages(self.chat_history)
  self.current_state = "compacting"
  self:render_state()
  self:update_content(
    "compacting history messsages",
    { focus = false, scroll = true, callback = function() self:focus_input() end }
  )
  Llm.summarize_memory(history_memory and history_memory.content, messages, function(memory)
    if memory then
      self.chat_history.memory = memory
      Path.history.save(self.code.bufnr, self.chat_history)
    end
    self:update_content("compacted!", { focus = false, scroll = true, callback = function() self:focus_input() end })
    self.current_state = "compacted"
    self:clear_state()
    if cb then cb(args) end
  end)
end

function Sidebar:new_chat(args, cb, opts)
  opts = opts or {}

  -- Reset mode state
  self.current_mode_id = nil
  self.available_modes = {}
  self.acp_thread = nil
  self._pending_mode_transition = nil
  self.current_avante_mode = opts.avante_mode or nil

  -- Reset file selector to clean state
  if self.file_selector then
    self.file_selector:reset()
    if Config.behaviour.auto_add_current_file and self.code.bufnr and api.nvim_buf_is_valid(self.code.bufnr) then
      local buf_path = api.nvim_buf_get_name(self.code.bufnr)
      if buf_path ~= "" and not buf_path:match("^%w+://") then
        local filepath = Utils.file.is_in_project(buf_path) and Utils.relative_path(buf_path) or buf_path
        local stat = vim.uv.fs_stat(filepath)
        if stat == nil or stat.type == "file" then self.file_selector:add_selected_file(filepath) end
      end
    end
  end

  local history = Path.history.new(self.code.bufnr)
  history.avante_mode = self.current_avante_mode
  -- Auto-detect worktree name if cwd is inside a git worktree
  local wd = history.working_directory or vim.fn.getcwd()
  local git_path = wd .. "/.git"
  if vim.fn.filereadable(git_path) == 1 and vim.fn.isdirectory(git_path) == 0 then
    local worktrees_root = Config.behaviour and Config.behaviour.worktrees_root
    if worktrees_root then
      local expanded_root = vim.fn.expand(worktrees_root)
      if wd:sub(1, #expanded_root) == expanded_root then
        local relative = wd:sub(#expanded_root + 2) -- skip trailing /
        if relative ~= "" then
          history.title = relative
        end
      end
    end
    -- Fallback: use the last path component as worktree name
    if history.title == "untitled" then
      history.title = vim.fn.fnamemodify(wd, ":t")
    end
  end
  Path.history.save(self.code.bufnr, history)
  self:reload_chat_history()
  self.current_state = nil
  self.expanded_message_uuids = {}
  self.tool_message_positions = {}
  self.current_tool_use_extmark_id = nil
  self._current_session_ctx = nil
  require("avante.changed_files").clear()
  -- Clear stale ACP commands from previous session
  Config.slash_commands = vim.tbl_filter(function(c) return c.source ~= "acp" end, Config.slash_commands)
  self:update_content("New chat", { focus = false, scroll = false, callback = function() self:focus_input() end })
  --- goto first line then go to last line
  vim.schedule(function()
    vim.api.nvim_win_call(self.containers.result.winid, function() vim.cmd("normal! ggG") end)
  end)
  -- Connect ACP for new chat — creates a fresh session
  self:connect_acp({ force_new = true })
  if cb then cb(args) end
  vim.schedule(function() self:create_plan_container() end)
end

local debounced_save_history = Utils.debounce(
  function(self)
    -- Update selected files before saving
    if self.file_selector then
      self.chat_history.selected_files = self.file_selector:get_selected_filepaths()
    end
    Path.history.save(self.code.bufnr, self.chat_history)
    -- Persist last-session info for auto-restore on next open
    Path.history.save_last_session(self.code.bufnr, {
      working_directory = vim.fn.getcwd(),
      selected_files = self.chat_history.selected_files or {},
    })
  end,
  1000
)

function Sidebar:save_history() debounced_save_history(self) end

---@param uuids string[]
function Sidebar:delete_history_messages(uuids)
  local history_messages = History.get_history_messages(self.chat_history)
  for _, msg in ipairs(history_messages) do
    if vim.list_contains(uuids, msg.uuid) then msg.is_deleted = true end
  end
  Path.history.save(self.code.bufnr, self.chat_history)
end

---@param todos avante.TODO[]
function Sidebar:update_plan(todos)
  Utils.debug("Sidebar:update_plan called with " .. #todos .. " entries")
  if self.chat_history == nil then
    Utils.debug("update_plan: reloading chat_history")
    self:reload_chat_history()
  end
  if self.chat_history == nil then
    Utils.debug("WARNING: chat_history is nil after reload, cannot save plan")
    return
  end
  self.chat_history.todos = todos
  Path.history.save(self.code.bufnr, self.chat_history)
  self:create_plan_container()
end

---@param messages avante.HistoryMessage | avante.HistoryMessage[]
---@param opts? {eager_update?: boolean}
function Sidebar:add_history_messages(messages, opts)
  local history_messages = History.get_history_messages(self.chat_history)
  messages = vim.islist(messages) and messages or { messages }
  for _, message in ipairs(messages) do
    if message.is_user_submission then
      message.provider = Config.provider
      if not Config.acp_providers[Config.provider] then
        message.model = Config.get_provider_config(Config.provider).model
      end
    end
    local idx = nil
    for idx_, message_ in ipairs(history_messages) do
      if message_.uuid == message.uuid then
        idx = idx_
        break
      end
    end
    if idx ~= nil then
      history_messages[idx] = message
    else
      table.insert(history_messages, message)
    end
  end
  self.chat_history.messages = history_messages
  self._history_cache_invalidated = true
  self:save_history()

  -- Update title from first user message if still untitled
  if self.chat_history.title == "untitled" and #messages > 0 then
    -- Find the first user message
    local first_user_msg = nil
    for _, msg in ipairs(messages) do
      if msg.message and msg.message.role == "user" and not msg.just_for_display then
        first_user_msg = msg
        break
      end
    end

    if first_user_msg then
      local first_msg_text = Render.message_to_text(first_user_msg, messages)
      local lines_ = vim.iter(vim.split(first_msg_text, "\n")):filter(function(line) return line ~= "" end):totable()
      if #lines_ > 0 then
        -- Extract just the text content, removing any template wrapper
        local title = lines_[1]
        -- Remove the template wrapper if present (e.g., "message (managed by avante)" -> extract "message")
        local template = require("avante.config").history.session_title_template
        if template and template:match("{{message}}") then
          -- Try to extract the message from the template
          local pattern = template:gsub("{{message}}", "(.+)")
          pattern = pattern:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") -- Escape special chars
          pattern = pattern:gsub("%%%(%%.%+%%%)", "(.+)") -- Unescape the capture group
          local extracted = title:match("^" .. pattern .. "$")
          if extracted then
            title = extracted
          end
        end
        self.chat_history.title = title
        self:save_history()
        -- Also trigger render_result to update the sidebar header
        vim.schedule(function()
          self:render_result()
        end)
      end
    end
  end
  local last_message = messages[#messages]
  if last_message then
    if History.Helpers.is_tool_use_message(last_message) then
      self.current_state = "tool calling"
    elseif History.Helpers.is_thinking_message(last_message) then
      self.current_state = "thinking"
    else
      self.current_state = "generating"
    end
  end
  if opts and opts.eager_update then
    pcall(function() self:update_content("") end)
    return
  end
  xpcall(function() self:throttled_update_content("") end, function(err)
    Utils.debug("Failed to update content:", err)
    return nil
  end)
end

-- FIXME: this is used by external plugin users
---@param messages AvanteLLMMessage | AvanteLLMMessage[]
---@param options {visible?: boolean}
function Sidebar:add_chat_history(messages, options)
  options = options or {}
  messages = vim.islist(messages) and messages or { messages }
  local is_first_user = true
  local history_messages = {}
  for _, message in ipairs(messages) do
    local role = message.role
    if role == "system" and type(message.content) == "string" then
      self.chat_history.system_prompt = message.content --[[@as string]]
    else
      ---@type AvanteLLMMessageContentItem
      local content = type(message.content) ~= "table" and message.content or message.content[1]
      local msg_opts = { visible = options.visible }
      if role == "user" and is_first_user then
        msg_opts.is_user_submission = true
        is_first_user = false
      end
      table.insert(history_messages, History.Message:new(role, content, msg_opts))
    end
  end
  self:add_history_messages(history_messages)
end

function Sidebar:create_selected_code_container()
  if self.containers.selected_code ~= nil then
    self.containers.selected_code:unmount()
    self.containers.selected_code = nil
  end

  local height = self:get_selected_code_container_height()

  if self.code.selection ~= nil then
    self.containers.selected_code = Split({
      enter = false,
      relative = {
        type = "win",
        winid = self:get_split_candidate("selected_code"),
      },
      buf_options = vim.tbl_deep_extend("force", buf_options, { filetype = "AvanteSelectedCode" }),
      win_options = vim.tbl_deep_extend("force", base_win_options, {}),
      size = {
        height = height,
      },
      position = "bottom",
    })
    self.containers.selected_code:mount()
    self:adjust_layout()
    self:setup_window_navigation(self.containers.selected_code)
  end
end

function Sidebar:close_input_hint()
  -- Close floating window if exists
  if self.input_hint_window and api.nvim_win_is_valid(self.input_hint_window) then
    local buf = api.nvim_win_get_buf(self.input_hint_window)
    if INPUT_HINT_NAMESPACE then api.nvim_buf_clear_namespace(buf, INPUT_HINT_NAMESPACE, 0, -1) end
    api.nvim_win_close(self.input_hint_window, true)
    api.nvim_buf_delete(buf, { force = true })
    self.input_hint_window = nil
  end
  
  -- Clear winbar/statusline if using those modes
  local config = Config.behaviour.status_line
  if config then
    local position = config.position
    if position == "winbar" and self.containers.input and api.nvim_win_is_valid(self.containers.input.winid) then
      pcall(api.nvim_set_option_value, "winbar", "", { win = self.containers.input.winid })
    elseif position == "statusline" and self.containers.input and api.nvim_win_is_valid(self.containers.input.winid) then
      pcall(api.nvim_set_option_value, "statusline", "", { win = self.containers.input.winid })
    end
  end
end

function Sidebar:get_input_float_window_row()
  local win_height = api.nvim_win_get_height(self.containers.input.winid)
  local winline = Utils.winline(self.containers.input.winid)
  if winline >= win_height - 1 then return 0 end
  return winline
end

-- Create a status display (hint window or winbar) with plan mode indicator
function Sidebar:show_input_hint()
  self:close_input_hint() -- Close the existing hint window

  local config = Config.behaviour.status_line
  if not config or not config.enabled then return end
  
  -- Safety check: ensure containers are initialized
  if not self.containers or not self.containers.input then return end
  if not self.containers.input.winid or not vim.api.nvim_win_is_valid(self.containers.input.winid) then return end
  if not self.containers.input.bufnr or not vim.api.nvim_buf_is_valid(self.containers.input.bufnr) then return end

  -- Build status line parts
  local parts = {}
  local plan_mode_text = nil

  -- 1. Mode indicator (prefer configOptions over legacy modes)
  if config.show_plan_mode then
    local got_mode = false
    -- Check configOptions first (ACP spec: supersedes modes)
    if self.acp_client and self.acp_client:has_config_options() then
      local config_opts = self.acp_client:all_config_options()
      local mode_opt = vim.iter(config_opts):find(function(o) return o.category == "mode" end)
      if mode_opt then
        -- Find the display name for current value
        local display = mode_opt.currentValue:upper()
        for _, val in ipairs(mode_opt.options) do
          if val.value == mode_opt.currentValue then
            display = val.name
            break
          end
        end
        plan_mode_text = " " .. display
        table.insert(parts, plan_mode_text)
        got_mode = true
      end
    end
    -- Fallback to legacy modes
    if not got_mode then
      if self.current_mode_id and self.acp_client then
        local mode = self.acp_client:mode_by_id(self.current_mode_id)
        local mode_name = mode and mode.name or self.current_mode_id:upper()
        plan_mode_text = " " .. mode_name
        table.insert(parts, plan_mode_text)
      elseif self.current_mode_id then
        plan_mode_text = " " .. self.current_mode_id:upper()
        table.insert(parts, plan_mode_text)
      else
        plan_mode_text = "⚡ EXEC"
        table.insert(parts, plan_mode_text)
      end
    end
  end

  -- Avante mode indicator
  if self.current_avante_mode then
    table.insert(parts, "[" .. self.current_avante_mode:upper() .. "]")
  end

  -- 2. Following status indicator
  if config.show_following_status then
    local is_following = self.follow_mode
    if is_following then
      table.insert(parts, "👁️  FOLLOW")
    else
      table.insert(parts, "🔕 MANUAL")
    end
  end

  -- 3. Token count
  if config.show_tokens and Config.behaviour.enable_token_counting then
    local input_value = table.concat(api.nvim_buf_get_lines(self.containers.input.bufnr, 0, -1, false), "\n")
    if self.token_count == nil then self:initialize_token_count() end
    local tokens = self.token_count + Utils.tokens.calculate_tokens(input_value)
    table.insert(parts, "Tokens: " .. tostring(tokens))
  end

  -- 4. Submit keybinding
  if config.show_submit_key then
    local submit_config = (fn.mode() ~= "i" and Config.mappings.submit.normal or Config.mappings.submit.insert)
    local key_display = type(submit_config) == "table" and submit_config.key or submit_config
    if type(submit_config) == "table" and submit_config.mode == "double_tap" then
      key_display = key_display .. key_display -- Show double key for double-tap mode
    end
    table.insert(parts, key_display .. ": submit")
  end

  -- 5. Session info (mode ID + session ID)
  if config.show_session_info then
    local session_parts = {}
    if self.current_mode_id then
      table.insert(session_parts, self.current_mode_id)
    end
    if self.chat_history and self.chat_history.acp_session_id then
      table.insert(session_parts, "S:" .. self.chat_history.acp_session_id:sub(1, 8))
    end
    if #session_parts > 0 then
      table.insert(parts, table.concat(session_parts, " "))
    end
  end

  -- 6. Working directory
  if config.show_working_directory then
    local wd = (self.chat_history and self.chat_history.working_directory) or vim.fn.getcwd()
    if wd then
      -- Show path with ~ for home directory
      local display_path = vim.fn.fnamemodify(wd, ":~")
      -- Detect if this is a git worktree (worktrees have a .git file, not a .git directory)
      local git_path = wd .. "/.git"
      local is_worktree = vim.fn.filereadable(git_path) == 1 and vim.fn.isdirectory(git_path) == 0
      if is_worktree then
        table.insert(parts, "Worktree: " .. display_path)
      else
        table.insert(parts, "Dir: " .. display_path)
      end
    end
  end

  -- 7. Plan progress
  if config.show_plan_progress ~= false then
    local plan_progress = nil
    if self.acp_thread then
      plan_progress = self.acp_thread:plan_progress_string()
    elseif self.chat_history and self.chat_history.todos and #self.chat_history.todos > 0 then
      local done = 0
      local total = #self.chat_history.todos
      for _, todo in ipairs(self.chat_history.todos) do
        if todo.status == "done" then done = done + 1 end
      end
      plan_progress = "Plan: " .. done .. "/" .. total
    end
    if plan_progress then
      table.insert(parts, plan_progress)
    end
  end

  -- Build final text
  local hint_text
  if config.format then
    -- Custom format string using named parts
    local named_parts = {}
    -- Rebuild named lookup from the parts we added
    -- (parts are added conditionally, so use named table instead of indices)
    hint_text = config.format
    -- Replace each placeholder; since parts are conditional, build a named map
    local part_names = {}
    local part_idx = 0
    if config.show_plan_mode then part_idx = part_idx + 1; part_names["plan_mode"] = parts[part_idx] end
    if config.show_following_status then part_idx = part_idx + 1; part_names["following_status"] = parts[part_idx] end
    if config.show_tokens and Config.behaviour.enable_token_counting then part_idx = part_idx + 1; part_names["tokens"] = parts[part_idx] end
    if config.show_submit_key then part_idx = part_idx + 1; part_names["submit_key"] = parts[part_idx] end
    if config.show_session_info then part_idx = part_idx + 1; part_names["session_info"] = parts[part_idx] end
    if config.show_working_directory then part_idx = part_idx + 1; part_names["working_directory"] = parts[part_idx] end
    if config.show_plan_progress ~= false then part_idx = part_idx + 1; part_names["plan_progress"] = parts[part_idx] end
    for name, val in pairs(part_names) do
      hint_text = hint_text:gsub("{" .. name .. "}", val or "")
    end
    -- Remove any unreplaced placeholders
    hint_text = hint_text:gsub("{%w+}", "")
  else
    -- Default: join with " | "
    hint_text = table.concat(parts, " | ")
  end

  -- Create status display based on position
  self:create_status_display(hint_text, plan_mode_text)
end

-- Create status display based on configured position
---@param text string The full status text
---@param plan_mode_text string|nil The plan mode indicator for highlighting
function Sidebar:create_status_display(text, plan_mode_text)
  local position = Config.behaviour.status_line.position
  
  if position == "winbar" then
    -- Primary mode: Winbar at top of input container
    if not self.containers.input or not api.nvim_win_is_valid(self.containers.input.winid) then
      return
    end
    
    -- Build winbar string with padding
    local winbar_str = " " .. text .. " "
    
    -- Set winbar for input window
    api.nvim_set_option_value("winbar", winbar_str, { 
      win = self.containers.input.winid 
    })
    
  elseif position == "floating" then
    -- Fallback: Floating window (original implementation)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    api.nvim_buf_set_extmark(buf, INPUT_HINT_NAMESPACE, 0, 0, { 
      hl_group = "AvantePopupHint", 
      end_col = #text 
    })
    
    local win_width = api.nvim_win_get_width(self.containers.input.winid)
    local width = #text
    
    self.input_hint_window = api.nvim_open_win(buf, false, {
      relative = "win",
      win = self.containers.input.winid,
      width = width,
      height = 1,
      row = self:get_input_float_window_row(),
      col = math.max(win_width - width, 0),
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 100,
    })
    
  elseif position == "statusline" then
    -- Use statusline at bottom of input window
    if not self.containers.input or not api.nvim_win_is_valid(self.containers.input.winid) then
      return
    end
    api.nvim_set_option_value("statusline", text, { 
      win = self.containers.input.winid 
    })
    
  elseif position == "top" then
    -- Floating window at very top of sidebar
    self:create_floating_status(text, "top")
    
  elseif position == "bottom" then
    -- Floating window at bottom (above input)
    self:create_floating_status(text, "bottom")
  end
end

-- Helper for floating status windows at top/bottom of sidebar
---@param text string
---@param location "top" | "bottom"
function Sidebar:create_floating_status(text, location)
  if not self.containers.result or not api.nvim_win_is_valid(self.containers.result.winid) then
    return
  end
  
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  
  local win_width = api.nvim_win_get_width(self.containers.result.winid)
  local width = #text
  
  local row
  if location == "top" then
    row = 0
  else
    row = api.nvim_win_get_height(self.containers.result.winid) - 1
  end
  
  self.input_hint_window = api.nvim_open_win(buf, false, {
    relative = "win",
    win = self.containers.result.winid,
    width = width,
    height = 1,
    row = row,
    col = math.floor((win_width - width) / 2),  -- Center
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 100,
  })
end

function Sidebar:close_selected_files_hint()
  if self.containers.selected_files and api.nvim_win_is_valid(self.containers.selected_files.winid) then
    pcall(api.nvim_buf_clear_namespace, self.containers.selected_files.bufnr, SELECTED_FILES_HINT_NAMESPACE, 0, -1)
  end
end

function Sidebar:show_selected_files_hint()
  self:close_selected_files_hint()

  local cursor_pos = api.nvim_win_get_cursor(self.containers.selected_files.winid)
  local line_number = cursor_pos[1]
  local col_number = cursor_pos[2]

  local selected_filepaths_ = self.file_selector:get_selected_filepaths()
  local hint
  if #selected_filepaths_ == 0 then
    hint = string.format(" [%s: add] ", Config.mappings.sidebar.add_file)
  else
    hint =
      string.format(" [%s: delete, %s: add] ", Config.mappings.sidebar.remove_file, Config.mappings.sidebar.add_file)
  end

  api.nvim_buf_set_extmark(
    self.containers.selected_files.bufnr,
    SELECTED_FILES_HINT_NAMESPACE,
    line_number - 1,
    col_number,
    {
      virt_text = { { hint, "AvanteInlineHint" } },
      virt_text_pos = "right_align",
      hl_group = "AvanteInlineHint",
      priority = PRIORITY,
    }
  )
end

function Sidebar:reload_chat_history()
  self.token_count = nil
  if self._skip_history_load then return end
  if not self.code.bufnr or not api.nvim_buf_is_valid(self.code.bufnr) then return end
  self.chat_history = Path.history.load(self.code.bufnr)
  self._history_cache_invalidated = true
end

---@param opts? {all?: boolean}
---@return avante.HistoryMessage[]
function Sidebar:get_history_messages_for_api(opts)
  opts = opts or {}
  local messages = History.get_history_messages(self.chat_history)

  -- Scan the initial set of messages, filtering out "uninteresting" ones, but also
  -- check if the last message mentioned in the chat memory is actually present.
  local last_message = self.chat_history.memory and self.chat_history.memory.last_message_uuid
  local last_message_present = false
  messages = vim
    .iter(messages)
    :filter(function(message)
      if message.just_for_display or message.is_compacted then return false end
      if not opts.all then
        if message.state == "generating" then return false end
        if last_message and message.uuid == last_message then last_message_present = true end
      end
      return true
    end)
    :totable()

  if not opts.all then
    if last_message and last_message_present then
      -- Drop all old messages preceding the "last" one from the memory
      local last_message_seen = false
      messages = vim
        .iter(messages)
        :filter(function(message)
          if not last_message_seen then
            if message.uuid == last_message then last_message_seen = true end
            return false
          end
          return true
        end)
        :totable()
    end

    if not Config.acp_providers[Config.provider] then
      local provider = Providers[Config.provider]
      local use_response_api = Providers.resolve_use_response_api(provider, nil)
      local tool_limit
      if provider.use_ReAct_prompt or use_response_api then
        tool_limit = nil
      else
        tool_limit = 25
      end
      messages = History.update_tool_invocation_history(messages, tool_limit, Config.behaviour.auto_check_diagnostics)
    end
  end

  return messages
end

---@param request string
---@param cb? fun(opts: AvanteGeneratePromptsOptions): nil
function Sidebar:get_generate_prompts_options(request, cb)
  local filetype = api.nvim_get_option_value("filetype", { buf = self.code.bufnr })
  local file_ext = nil

  -- Get file extension safely
  local buf_name = api.nvim_buf_get_name(self.code.bufnr)
  if buf_name and buf_name ~= "" then file_ext = vim.fn.fnamemodify(buf_name, ":e") end

  ---@type AvanteSelectedCode | nil
  local selected_code = nil
  if self.code.selection ~= nil then
    selected_code = {
      path = self.code.selection.filepath,
      file_type = self.code.selection.filetype,
      content = self.code.selection.content,
    }
  end

  local mentions = Utils.extract_mentions(request)
  request = mentions.new_content

  local project_context = mentions.enable_project_context and file_ext and RepoMap.get_repo_map(file_ext) or nil

  local diagnostics = nil
  if mentions.enable_diagnostics then
    if self.code ~= nil and self.code.bufnr ~= nil and self.code.selection ~= nil then
      diagnostics = Utils.lsp.get_current_selection_diagnostics(self.code.bufnr, self.code.selection)
    else
      diagnostics = Utils.lsp.get_diagnostics(self.code.bufnr)
    end
  end

  local history_messages = self:get_history_messages_for_api()

  local tools = vim.deepcopy(LLMTools.get_tools(request, history_messages))
  table.insert(tools, {
    name = "add_file_to_context",
    description = "Add a file to the context",
    ---@type AvanteLLMToolFunc<{ rel_path: string }>
    func = function(input)
      self.file_selector:add_selected_file(input.rel_path)
      return "Added file to context", nil
    end,
    param = {
      type = "table",
      fields = { { name = "rel_path", description = "Relative path to the file", type = "string" } },
    },
    returns = {},
  })

  table.insert(tools, {
    name = "remove_file_from_context",
    description = "Remove a file from the context",
    ---@type AvanteLLMToolFunc<{ rel_path: string }>
    func = function(input)
      self.file_selector:remove_selected_file(input.rel_path)
      return "Removed file from context", nil
    end,
    param = {
      type = "table",
      fields = { { name = "rel_path", description = "Relative path to the file", type = "string" } },
    },
    returns = {},
  })

  local selected_filepaths = self.file_selector.selected_filepaths or {}

  local ask = Config.ask_opts.ask
  if ask == nil then ask = true end

  ---@type AvanteGeneratePromptsOptions
  local prompts_opts = {
    ask = ask,
    project_context = vim.json.encode(project_context),
    selected_filepaths = selected_filepaths,
    recently_viewed_files = Utils.get_recent_filepaths(),
    diagnostics = vim.json.encode(diagnostics),
    history_messages = history_messages,
    code_lang = filetype,
    selected_code = selected_code,
    tools = tools,
  }

  if self.chat_history.system_prompt then
    prompts_opts.prompt_opts = {
      system_prompt = self.chat_history.system_prompt,
      messages = history_messages,
    }
  end

  if self.chat_history.memory then prompts_opts.memory = self.chat_history.memory.content end

  if Config.behaviour.enable_token_counting then self.token_count = Llm.calculate_tokens(prompts_opts) end

  if cb then cb(prompts_opts) end
end

---Collect metadata for prompt logging
---@return table
function Sidebar:collect_prompt_metadata()
  local metadata = {}
  
  -- Project and directory
  metadata.project_root = Utils.root.get({ buf = self.code.bufnr })
  metadata.working_directory = vim.fn.getcwd()
  
  -- Detect first prompt in this chat
  local History = require("avante.history")
  metadata.is_first_prompt = #History.get_history_messages(self.chat_history) == 0
  
  -- Current file info
  if self.code and self.code.bufnr then
    metadata.current_file = api.nvim_buf_get_name(self.code.bufnr)
    local ok, ft = pcall(api.nvim_get_option_value, "filetype", { buf = self.code.bufnr })
    metadata.filetype = ok and ft or "unknown"
  end
  
  -- Provider and model
  metadata.provider = Config.provider or "unknown"
  local ok, provider_config = pcall(Config.get_provider_config, Config.provider)
  if ok and provider_config then
    metadata.model = provider_config.model or "unknown"
  else
    metadata.model = "unknown"
  end
  
  -- Session and files
  metadata.chat_session_id = self.chat_history and self.chat_history.acp_session_id or nil
  metadata.selected_files = self.file_selector and self.file_selector:get_selected_filepaths() or {}
  metadata.current_mode_id = self.current_mode_id
  
  return metadata
end

function Sidebar:submit_input()
  if not vim.g.avante_login then
    Utils.warn("Sending message to fast!, API key is not yet set", { title = "Avante" })
    return
  end
  if not Utils.is_valid_container(self.containers.input) then return end
  local lines = api.nvim_buf_get_lines(self.containers.input.bufnr, 0, -1, false)
  local request = table.concat(lines, "\n")
  if request == "" then return end
  api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, {})
  api.nvim_win_set_cursor(self.containers.input.winid, { 1, 0 })
  self:handle_submit(request)
end

---@param request string
function Sidebar:handle_submit(request)
  -- Empty requests were previously used to trigger ACP connect — now handled by connect_acp()
  if request == "" then return end

  if Config.prompt_logger.enabled then
    local metadata = self:collect_prompt_metadata()
    PromptLogger.log_prompt_v2(request, metadata)
  end

  if self.is_generating then
    self:add_history_messages({ History.Message:new("user", request) })
    return
  end

  if request:match("@codebase") and not vim.fn.expand("%:e") then
    self:update_content("Please open a file first before using @codebase", { focus = false, scroll = false })
    return
  end

  -- Track if this is a slash command for later clearing
  local is_slash_command = request:sub(1, 1) == "/"

  if is_slash_command then
    local command, args = request:match("^/(%S+)%s*(.*)")
    if command == nil then
      self:update_content("Invalid command", { focus = false, scroll = false })
      return
    end
    local cmds = Utils.get_commands()
    ---@type AvanteSlashCommand
    local cmd = vim.iter(cmds):filter(function(cmd) return cmd.name == command end):totable()[1]
    if cmd then
      -- ACP-sourced commands fall through to the agent unless they're local-only
      local is_local_only = vim.tbl_contains(Config.local_only_commands, command)
      if cmd.callback and (cmd.source ~= "acp" or is_local_only) then
        if command == "lines" then
          cmd.callback(self, args, function(args_)
            local _, _, question = args_:match("(%d+)-(%d+)%s+(.*)")
            request = question
          end)
        elseif command == "commit" then
          cmd.callback(self, args, function(question) request = question end)
        else
          -- Execute local command and clear input if configured
          cmd.callback(self, args)
          if Config.auto_clear_slash_commands then
            self:clear_input()
          end
          return
        end
      end
    else
      -- Unknown command: check if we should pass to ACP agent
      if Config.enable_acp_command_passthrough then
        -- Don't return - let it fall through to ACP handling
        -- The slash command text will be preserved in the request
      else
        self:update_content("Unknown command: " .. command, { focus = false, scroll = false })
        return
      end
    end
  end

  -- Process shortcut replacements
  local new_content, has_shortcuts = Utils.extract_shortcuts(request)
  if has_shortcuts then
    Utils.debug("Shortcuts detected and replaced in request")
    request = new_content
  end

  local selected_filepaths = self.file_selector:get_selected_filepaths()

  ---@type AvanteSelectedCode | nil
  local selected_code = self.code.selection
    and {
      path = self.code.selection.filepath,
      file_type = self.code.selection.filetype,
      content = self.code.selection.content,
    }

  if request ~= "" then
    --- HACK: we need to set focus to true and scroll to false to
    --- prevent the cursor from jumping to the bottom of the
    --- buffer at the beginning
    self:update_content("", { focus = true, scroll = false })
  end

  ---stop scroll when user presses j/k keys
  local function on_j()
    self.scroll = false
    ---perform scroll
    vim.cmd("normal! j")
  end

  local function on_k()
    self.scroll = false
    ---perform scroll
    vim.cmd("normal! k")
  end

  local function on_G()
    self.scroll = true
    ---perform scroll
    vim.cmd("normal! G")
  end

  vim.keymap.set("n", "j", on_j, { buffer = self.containers.result.bufnr })
  vim.keymap.set("n", "k", on_k, { buffer = self.containers.result.bufnr })
  vim.keymap.set("n", "G", on_G, { buffer = self.containers.result.bufnr })

  ---@type AvanteLLMStartCallback
  local function on_start(_)
    -- Track agent start for notifications
    local Config = require("avante.config")
    if Config.notifications.enabled then
      local ok, Notifications = pcall(require, "avante.notifications")
      if ok then
        local session_id = self.chat_history.acp_session_id or "internal_" .. self.bufnr
        Notifications.on_agent_start(session_id)
      end
    end
  end

  ---@param messages avante.HistoryMessage[]
  local function on_messages_add(messages) self:add_history_messages(messages) end

  ---@param state avante.GenerateState
  local function on_state_change(state)
    self:clear_state()
    self.current_state = state
    self:render_state()
  end

  ---@param tool_id string
  ---@param tool_name string
  ---@param log string
  ---@param state AvanteLLMToolUseState
  local function on_tool_log(tool_id, tool_name, log, state)
    if state == "generating" then on_state_change("tool calling") end
    local tool_use_message = History.Helpers.get_tool_use_message(tool_id, self.chat_history.messages)
    if not tool_use_message then
      -- Utils.debug("tool_use message not found", tool_id, tool_name)
      return
    end

    local tool_use_logs = tool_use_message.tool_use_logs or {}
    local content = string.format("[%s]: %s", tool_name, log)
    table.insert(tool_use_logs, content)
    tool_use_message.tool_use_logs = tool_use_logs

    local orig_is_calling = tool_use_message.is_calling
    tool_use_message.is_calling = true
    self:update_content("")
    tool_use_message.is_calling = orig_is_calling
    self:save_history()
  end

  local function set_tool_use_store(tool_id, key, value)
    local tool_use_message = History.Helpers.get_tool_use_message(tool_id, self.chat_history.messages)
    if tool_use_message then
      local tool_use_store = tool_use_message.tool_use_store or {}
      tool_use_store[key] = value
      tool_use_message.tool_use_store = tool_use_store
      self:save_history()
    end
  end

  ---@type AvanteLLMStopCallback
  local function on_stop(stop_opts)
    self.is_generating = false

    pcall(function()
      ---remove keymaps
      vim.keymap.del("n", "j", { buffer = self.containers.result.bufnr })
      vim.keymap.del("n", "k", { buffer = self.containers.result.bufnr })
      vim.keymap.del("n", "G", { buffer = self.containers.result.bufnr })
    end)

    -- Send notifications for internal agent completion
    local Config = require("avante.config")
    if Config.notifications.enabled then
      local should_notify = (stop_opts.reason == "complete" and Config.notifications.notify_on_complete)
        or (stop_opts.error and stop_opts.error ~= vim.NIL and Config.notifications.notify_on_error)
        or (stop_opts.reason == "cancelled" and Config.notifications.notify_on_cancel)

      if should_notify then
        local ok, Notifications = pcall(require, "avante.notifications")
        if ok then
          local session_id = self.chat_history.acp_session_id or "internal_" .. self.bufnr
          local task_summary = self:_extract_task_summary()
          local thread_title = self.chat_history and self.chat_history.title or nil
          Notifications.on_agent_complete(session_id, stop_opts, task_summary, thread_title)
        end
      end
    end

    -- In-editor notification for pinned threads (visible even when on a different thread)
    if self.chat_history and self.chat_history.pinned then
      local thread_title = self.chat_history.title or "Pinned thread"
      if stop_opts.reason == "complete" or (not stop_opts.error and stop_opts.reason ~= "cancelled") then
        Utils.info("[Pinned] " .. thread_title .. " completed. Use :AvantePinnedThreads to view.")
      elseif stop_opts.error and stop_opts.error ~= vim.NIL then
        Utils.warn("[Pinned] " .. thread_title .. " failed. Use :AvantePinnedThreads to view.")
      end
    end

    if stop_opts.error ~= nil and stop_opts.error ~= vim.NIL then
      local msg_content = stop_opts.error
      if type(msg_content) ~= "string" then msg_content = vim.inspect(msg_content) end
      self:add_history_messages({
        History.Message:new("assistant", "\n\nError: " .. msg_content, {
          just_for_display = true,
        }),
      })
      on_state_change("failed")
      return
    end

    if stop_opts.reason == "cancelled" then
      on_state_change("cancelled")
    else
      on_state_change("succeeded")
    end

    self:update_content("", {
      callback = function() api.nvim_exec_autocmds("User", { pattern = VIEW_BUFFER_UPDATED_PATTERN }) end,
    })

    vim.defer_fn(function()
      if Utils.is_valid_container(self.containers.result, true) and Config.behaviour.jump_result_buffer_on_finish then
        api.nvim_set_current_win(self.containers.result.winid)
      end
      if Config.behaviour.auto_apply_diff_after_generation then self:apply(false) end
    end, 0)

    Path.history.save(self.code.bufnr, self.chat_history)
  end

  if request and request ~= "" then
    -- Auto-title from first user message
    if self.chat_history and (self.chat_history.title == "untitled" or self.chat_history.title == nil) then
      local title = request:sub(1, 60):gsub("\n", " "):gsub("%s+", " ")
      if #request > 60 then title = title .. "..." end
      self.chat_history.title = title
      if self.acp_thread then
        self.acp_thread.title = title
      end
    end

    self:add_history_messages({
      History.Message:new("user", request, {
        is_user_submission = true,
        selected_filepaths = selected_filepaths,
        selected_code = selected_code,
      }),
    })
  end

  self:get_generate_prompts_options(request, function(generate_prompts_options)
    ---@type AvanteLLMStreamOptions
    ---@diagnostic disable-next-line: assign-type-mismatch
    -- Initialize session_ctx for tracking file snapshots and edits
    if not self._current_session_ctx then
      self._current_session_ctx = { file_snapshots = {}, edited_files = {} }
      local ChangedFiles = require("avante.changed_files")
      self._current_session_ctx.on_file_edited = function(abs_path, tool_name)
        ChangedFiles.on_file_edited(abs_path, self._current_session_ctx, tool_name)
      end
    end

    -- Capture current generation so stale callbacks from prior sessions are ignored
    local session_generation = self._acp_session_generation or 0

    local stream_options = vim.tbl_deep_extend("force", generate_prompts_options, {
      on_start = on_start,
      on_stop = on_stop,
      on_tool_log = on_tool_log,
      on_messages_add = on_messages_add,
      on_state_change = on_state_change,
      sidebar = self,
      acp_client = self.acp_client,
      acp_session_id = self.chat_history.acp_session_id,
      set_tool_use_store = set_tool_use_store,
      get_history_messages = function(opts) return self:get_history_messages_for_api(opts) end,
      get_todos = function()
        local history = Path.history.load(self.code.bufnr)
        return history.todos
      end,
      update_todos = function(todos) self:update_plan(todos) end,
      session_ctx = self._current_session_ctx or { file_snapshots = {}, edited_files = {} },
      ---@param usage avante.LLMTokenUsage
      update_tokens_usage = function(usage)
        if not usage then return end
        if usage.completion_tokens == nil then return end
        if usage.prompt_tokens == nil then return end
        self.chat_history.tokens_usage = usage
        self:save_history()
      end,
      get_tokens_usage = function() return self.chat_history.tokens_usage end,
    })

    ---@param pending_compaction_history_messages avante.HistoryMessage[]
    local function on_memory_summarize(pending_compaction_history_messages)
      local history_memory = self.chat_history.memory
      Llm.summarize_memory(
        history_memory and history_memory.content,
        pending_compaction_history_messages,
        function(memory)
          if memory then
            self.chat_history.memory = memory
            Path.history.save(self.code.bufnr, self.chat_history)
            stream_options.memory = memory.content
          end
          stream_options.history_messages = self:get_history_messages_for_api()
          Llm.stream(stream_options)
        end
      )
    end

    stream_options.on_memory_summarize = on_memory_summarize

    if request ~= "" then on_state_change("generating") end
    Llm.stream(stream_options)
  end)
end

function Sidebar:initialize_token_count()
  if Config.behaviour.enable_token_counting then self:get_generate_prompts_options("") end
end

function Sidebar:create_input_container()
  if self.containers.input then self.containers.input:unmount() end

  if not self.code.bufnr or not api.nvim_buf_is_valid(self.code.bufnr) then return end

  -- Guard: result container must exist first
  if not self.containers.result or not self.containers.result.winid then return end

  if self.chat_history == nil then self:reload_chat_history() end

  local function get_position()
    if self:get_layout() == "vertical" then return "bottom" end
    return "right"
  end

  local function get_size()
    -- Handle fullscreen input mode
    if self.is_input_fullscreen then
      if self:get_layout() == "vertical" then
        -- In vertical layout, take up most of the sidebar height
        local available_height = vim.o.lines
        return {
          height = math.floor(available_height * 0.8),
        }
      else
        -- In horizontal layout, take up most of the result window height
        local result_height = api.nvim_win_get_height(self.containers.result.winid)
        return {
          width = "40%",
          height = math.floor(result_height * 0.9),
        }
      end
    end

    -- Normal sizing logic
    if self:get_layout() == "vertical" then return {
      height = Config.windows.input.height,
    } end

    local selected_code_container_height = self:get_selected_code_container_height()

    return {
      width = "40%",
      height = math.max(1, api.nvim_win_get_height(self.containers.result.winid) - selected_code_container_height),
    }
  end

  self.containers.input = Split({
    enter = false,
    relative = {
      type = "win",
      winid = self.containers.result.winid,
    },
    buf_options = {
      swapfile = false,
      buftype = "nofile",
    },
    win_options = vim.tbl_deep_extend("force", base_win_options, { signcolumn = "yes", wrap = Config.windows.wrap }),
    position = get_position(),
    size = get_size(),
  })

  local function on_submit() self:submit_input() end

  self.containers.input:mount()
  PromptLogger.init()

  local function place_sign_at_first_line(bufnr)
    local group = "avante_input_prompt_group"

    fn.sign_unplace(group, { buffer = bufnr })
    fn.sign_place(0, group, "AvanteInputPromptSign", bufnr, { lnum = 1 })
  end

  place_sign_at_first_line(self.containers.input.bufnr)

  if Utils.in_visual_mode() then
    -- Exit visual mode. Unfortunately there is no appropriate command
    -- so we have to simulate keystrokes.
    local esc_key = api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc_key, "n", false)
  end

  self:setup_window_navigation(self.containers.input)
  
  -- Setup submit keymaps with double-tap support
  local function create_submit_mapping(mode, submit_config)
    local key = type(submit_config) == "table" and submit_config.key or submit_config
    local handler
    local is_double_tap = type(submit_config) == "table" and submit_config.mode == "double_tap"
    
    if is_double_tap then
      handler = Utils.create_double_tap_handler(on_submit, submit_config.timeout, self.containers.input.bufnr)
    else
      handler = on_submit
    end
    
    -- For insert mode double-tap on <CR>, use expr mapping to suppress immediate newline
    local opts = { noremap = true, silent = true }
    if mode == "i" and is_double_tap and (key == "<CR>" or key == "<Enter>") then
      opts.expr = true
    end
    -- Pass true as 5th arg to force overwrite any existing mapping
    self.containers.input:map(mode, key, handler, opts, true)
  end
  
  create_submit_mapping("n", Config.mappings.submit.normal)
  create_submit_mapping("i", Config.mappings.submit.insert)
  self.containers.input:map("n", Config.mappings.sidebar.toggle_input_fullscreen, function() self:toggle_input_fullscreen() end)
  self.containers.input:map("i", Config.mappings.sidebar.toggle_input_fullscreen, function() self:toggle_input_fullscreen() end)
  if Config.prompt_logger.next_prompt.normal then
    self.containers.input:map("n", Config.prompt_logger.next_prompt.normal, PromptLogger.on_log_retrieve(-1))
  end
  if Config.prompt_logger.next_prompt.insert then
    self.containers.input:map("i", Config.prompt_logger.next_prompt.insert, PromptLogger.on_log_retrieve(-1))
  end
  if Config.prompt_logger.prev_prompt.normal then
    self.containers.input:map("n", Config.prompt_logger.prev_prompt.normal, PromptLogger.on_log_retrieve(1))
  end
  if Config.prompt_logger.prev_prompt.insert then
    self.containers.input:map("i", Config.prompt_logger.prev_prompt.insert, PromptLogger.on_log_retrieve(1))
  end

  if Config.mappings.sidebar.close_from_input ~= nil then
    if Config.mappings.sidebar.close_from_input.normal ~= nil then
      self.containers.input:map("n", Config.mappings.sidebar.close_from_input.normal, function() self:shutdown() end)
    end
    if Config.mappings.sidebar.close_from_input.insert ~= nil then
      self.containers.input:map("i", Config.mappings.sidebar.close_from_input.insert, function() self:shutdown() end)
    end
  end

  if Config.mappings.sidebar.toggle_code_window_from_input ~= nil then
    if Config.mappings.sidebar.toggle_code_window_from_input.normal ~= nil then
      self.containers.input:map(
        "n",
        Config.mappings.sidebar.toggle_code_window_from_input.normal,
        function() self:toggle_code_window() end
      )
    end
    if Config.mappings.sidebar.toggle_code_window_from_input.insert ~= nil then
      self.containers.input:map(
        "i",
        Config.mappings.sidebar.toggle_code_window_from_input.insert,
        function() self:toggle_code_window() end
      )
    end
  end

  -- Toggle plan container from input buffer (Cmd-t)
  if Config.mappings.sidebar.toggle_plan then
    self.containers.input:map("n", Config.mappings.sidebar.toggle_plan, function() self:toggle_plan_container() end)
    self.containers.input:map("i", Config.mappings.sidebar.toggle_plan, function() self:toggle_plan_container() end)
  end

  api.nvim_set_option_value("filetype", "AvanteInput", { buf = self.containers.input.bufnr })

  -- Setup completion
  api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    once = true,
    desc = "Setup the completion of helpers in the input buffer",
    callback = function() end,
  })

  local debounced_show_input_hint = Utils.debounce(function()
    if vim.api.nvim_win_is_valid(self.containers.input.winid) then self:show_input_hint() end
  end, 200)
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      debounced_show_input_hint()
      place_sign_at_first_line(self.containers.input.bufnr)
    end,
  })

  api.nvim_create_autocmd("QuitPre", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function() self:close_input_hint() end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.containers.input.winid),
    callback = function() self:close_input_hint() end,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      if Config.windows.ask.start_insert then vim.cmd("noautocmd startinsert!") end
    end,
  })

  api.nvim_create_autocmd("BufLeave", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      vim.cmd("noautocmd stopinsert")
    end,
  })

  -- Update hint on mode change as submit key sequence may be different
  api.nvim_create_autocmd("ModeChanged", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function() self:show_input_hint() end,
  })

  api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      local cur_win = api.nvim_get_current_win()
      if self.containers.input and cur_win == self.containers.input.winid then
        self:show_input_hint()
      end
    end,
  })
end

-- FIXME: this is used by external plugin users
---@param value string
function Sidebar:set_input_value(value)
  if not self.containers.input then return end
  if not value then return end
  api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, vim.split(value, "\n"))
end

---@return string
function Sidebar:get_input_value()
  if not self.containers.input then return "" end
  local lines = api.nvim_buf_get_lines(self.containers.input.bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

function Sidebar:get_selected_code_container_height()
  if not self.code.selection then return 0 end

  local max_height = 5

  local count = Utils.count_lines(self.code.selection.content)
  if Config.windows.sidebar_header.enabled then count = count + 1 end

  return math.min(count, max_height)
end

function Sidebar:get_plan_container_height()
  if not self._plan_visible then return 0 end
  local history = Path.history.load(self.code.bufnr)
  local todo_count = #history.todos
  if todo_count == 0 then return 0 end
  -- header line + entries, capped at 12
  return math.min(todo_count + 1, 12)
end

function Sidebar:get_result_container_height()
  local plan_container_height = self:get_plan_container_height()
  local selected_code_container_height = self:get_selected_code_container_height()
  local selected_files_container_height = self:get_selected_files_container_height()

  if self:get_layout() == "horizontal" then return math.floor(Config.windows.height / 100 * vim.o.lines) end

  return math.max(
    1,
    api.nvim_get_option_value("lines", {})
      - selected_files_container_height
      - selected_code_container_height
      - plan_container_height
      - Config.windows.input.height
  )
end

function Sidebar:get_result_container_width()
  if self:get_layout() == "vertical" then return math.floor(Config.windows.width / 100 * vim.o.columns) end

  return math.max(1, api.nvim_win_get_width(self.code.winid))
end

function Sidebar:adjust_result_container_layout()
  -- Guard: result container must exist
  if not self.containers.result or not self.containers.result.winid then return end

  local width = self:get_result_container_width()
  local height = self:get_result_container_height()

  if self.is_in_full_view then width = vim.o.columns - 1 end

  api.nvim_win_set_width(self.containers.result.winid, width)
  api.nvim_win_set_height(self.containers.result.winid, height)
end

---@param opts AskOptions
function Sidebar:render(opts)
  -- Guard: prevent re-entrant rendering
  if self._is_rendering then return end
  self._is_rendering = true

  opts = opts or {}
  self.augroup = api.nvim_create_augroup("avante_sidebar_" .. self.id, { clear = true })

  -- This autocommand needs to be registered first, before NuiSplit
  -- registers their own handlers for WinClosed events that will set
  -- container.winid to nil, which will cause Sidebar:get_sidebar_window()
  -- to fail.
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    callback = function(args)
      local closed_winid = tonumber(args.match)
      if closed_winid then
        local container = self:get_sidebar_window(closed_winid)
        -- Ignore closing selected files and todos windows because they can disappear during normal operation
        if container and container ~= self.containers.selected_files and container ~= self.containers.plan then
          self:close()
        end
      end
    end,
  })

  if opts.sidebar_pre_render then opts.sidebar_pre_render(self) end

  local function get_position()
    return (opts and opts.win and opts.win.position) and opts.win.position or calculate_config_window_position()
  end

  self.containers.result = Split({
    enter = false,
    relative = "editor",
    position = get_position(),
    buf_options = vim.tbl_deep_extend("force", buf_options, {
      modifiable = false,
      swapfile = false,
      buftype = "nofile",
      bufhidden = "wipe",
      filetype = "Avante",
    }),
    win_options = vim.tbl_deep_extend("force", base_win_options, {
      wrap = Config.windows.wrap,
      fillchars = Config.windows.fillchars,
    }),
    size = {
      width = self:get_result_container_width(),
      height = self:get_result_container_height(),
    },
  })

  self.containers.result:mount()

  self.containers.result:on(event.BufWinEnter, function()
    xpcall(function() api.nvim_buf_set_name(self.containers.result.bufnr, RESULT_BUF_NAME) end, function(_) end)
  end)

  self.containers.result:map("n", Config.mappings.sidebar.close, function() self:shutdown() end)
  self.containers.result:map("n", Config.mappings.sidebar.toggle_code_window, function() self:toggle_code_window() end)
  self.containers.result:map("n", Config.mappings.sidebar.toggle_fullscreen_edit, function() self:toggle_fullscreen_edit() end)

  self:create_input_container()

  self:create_selected_files_container()

  if self.code.bufnr and api.nvim_buf_is_valid(self.code.bufnr) then
    -- reset states when buffer is closed
    api.nvim_buf_attach(self.code.bufnr, false, {
      on_detach = function(_, _)
        vim.schedule(function()
          if not self.code.winid or not api.nvim_win_is_valid(self.code.winid) then return end
          local bufnr = api.nvim_win_get_buf(self.code.winid)
          self.code.bufnr = bufnr
          self:reload_chat_history()
        end)
      end,
    })
  end

  self:create_selected_code_container()

  self:create_plan_container()

  self:on_mount(opts)

  self:setup_colors()

  if opts.sidebar_post_render then
    self.post_render = opts.sidebar_post_render
    vim.defer_fn(function()
      opts.sidebar_post_render(self)
      self:update_content_with_history()
    end, 100)
  else
    self:update_content_with_history()
  end

  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = "AvanteInputSubmitted",
    callback = function(ev)
      if ev.data and ev.data.request then self:handle_submit(ev.data.request) end
    end,
  })

  self._is_rendering = false
  return self
end

function Sidebar:get_selected_files_container_height()
  local selected_filepaths_ = self.file_selector:get_selected_filepaths()
  return math.min(Config.windows.selected_files.height, #selected_filepaths_ + 1)
end

function Sidebar:adjust_selected_files_container_layout()
  if not Utils.is_valid_container(self.containers.selected_files, true) then return end

  local win_height = self:get_selected_files_container_height()
  api.nvim_win_set_height(self.containers.selected_files.winid, win_height)
end

function Sidebar:adjust_selected_code_container_layout()
  if not Utils.is_valid_container(self.containers.selected_code, true) then return end

  local win_height = self:get_selected_code_container_height()
  api.nvim_win_set_height(self.containers.selected_code.winid, win_height)
end

function Sidebar:adjust_plan_container_layout()
  if not Utils.is_valid_container(self.containers.plan, true) then return end

  local win_height = self:get_plan_container_height()
  api.nvim_win_set_height(self.containers.plan.winid, win_height)
end

--- Toggle plan container visibility (Cmd-t)
function Sidebar:toggle_plan_container()
  self._plan_visible = not self._plan_visible
  if self._plan_visible then
    self:create_plan_container()
  else
    if self.containers.plan and Utils.is_valid_container(self.containers.plan) then
      self.containers.plan:unmount()
    end
    self.containers.plan = nil
    self:adjust_layout()
  end
end

function Sidebar:create_selected_files_container()
  if self.containers.selected_files then self.containers.selected_files:unmount() end

  local selected_filepaths = self.file_selector:get_selected_filepaths()
  if #selected_filepaths == 0 then
    self.file_selector:off("update")
    self.file_selector:on("update", function() self:create_selected_files_container() end)
    return
  end

  self.containers.selected_files = Split({
    enter = false,
    relative = {
      type = "win",
      winid = self:get_split_candidate("selected_files"),
    },
    buf_options = vim.tbl_deep_extend("force", buf_options, {
      modifiable = false,
      swapfile = false,
      buftype = "nofile",
      bufhidden = "wipe",
      filetype = "AvanteSelectedFiles",
    }),
    win_options = vim.tbl_deep_extend("force", base_win_options, {
      fillchars = Config.windows.fillchars,
    }),
    position = "bottom",
    size = {
      height = 2,
    },
  })
  self.containers.selected_files:mount()

  local function render()
    local selected_filepaths_ = self.file_selector:get_selected_filepaths()
    if #selected_filepaths_ == 0 then
      if Utils.is_valid_container(self.containers.selected_files) then self.containers.selected_files:unmount() end
      return
    end

    if not Utils.is_valid_container(self.containers.selected_files, true) then
      self:create_selected_files_container()
      if not Utils.is_valid_container(self.containers.selected_files, true) then
        Utils.warn("Failed to create or find selected files container window.")
        return
      end
    end

    local lines_to_set = {}
    local highlights_to_apply = {}
    local annotation_positions = {}

    local project_path = Utils.root.get()
    for i, filepath in ipairs(selected_filepaths_) do
      local icon, hl = Utils.file.get_file_icon(filepath)
      local renderpath = PPath:new(filepath):normalize(project_path)
      
      -- Check if this is a directory
      local is_directory = vim.fn.isdirectory(filepath) == 1
      
      -- Format the line with optional directory annotation
      local formatted_line
      if is_directory then
        local base_line = string.format("%s %s", icon, renderpath)
        formatted_line = base_line .. " (managed by avante)"
        -- Track where the annotation starts for highlighting
        table.insert(annotation_positions, {
          line_nr = i,
          start_col = vim.fn.strwidth(base_line) + 1,
          end_col = vim.fn.strwidth(formatted_line)
        })
      else
        formatted_line = string.format("%s %s", icon, renderpath)
      end
      
      table.insert(lines_to_set, formatted_line)
      if hl and hl ~= "" then table.insert(highlights_to_apply, { line_nr = i, icon = icon, hl = hl }) end
    end

    local selected_files_count = #lines_to_set ---@type integer
    local selected_files_buf = api.nvim_win_get_buf(self.containers.selected_files.winid)
    Utils.unlock_buf(selected_files_buf)
    api.nvim_buf_clear_namespace(selected_files_buf, SELECTED_FILES_ICON_NAMESPACE, 0, -1)
    api.nvim_buf_clear_namespace(selected_files_buf, SELECTED_FILES_HINT_NAMESPACE, 0, -1)
    api.nvim_buf_set_lines(selected_files_buf, 0, -1, true, lines_to_set)

    for _, highlight_info in ipairs(highlights_to_apply) do
      local line_idx = highlight_info.line_nr - 1
      local icon_bytes = #highlight_info.icon
      pcall(api.nvim_buf_set_extmark, selected_files_buf, SELECTED_FILES_ICON_NAMESPACE, line_idx, 0, {
        end_col = icon_bytes,
        hl_group = highlight_info.hl,
        priority = PRIORITY,
      })
    end
    
    -- Apply annotation highlights for directories
    for _, annotation_info in ipairs(annotation_positions) do
      local line_idx = annotation_info.line_nr - 1
      pcall(api.nvim_buf_set_extmark, selected_files_buf, SELECTED_FILES_HINT_NAMESPACE, line_idx, annotation_info.start_col, {
        end_col = annotation_info.end_col,
        hl_group = "Comment",
        priority = PRIORITY,
      })
    end

    Utils.lock_buf(selected_files_buf)
    local win_height = self:get_selected_files_container_height()
    api.nvim_win_set_height(self.containers.selected_files.winid, win_height)
    self:render_header(
      self.containers.selected_files.winid,
      selected_files_buf,
      string.format(
        "%sSelected (%d file%s)",
        Utils.icon(" "),
        selected_files_count,
        selected_files_count > 1 and "s" or ""
      ),
      Highlights.SUBTITLE,
      Highlights.REVERSED_SUBTITLE
    )
    self:adjust_layout()
  end

  self.file_selector:on("update", render)

  local function remove_file(line_number) self.file_selector:remove_selected_filepaths_with_index(line_number) end

  -- Set up keybinding to remove files
  self.containers.selected_files:map("n", Config.mappings.sidebar.remove_file, function()
    local line_number = api.nvim_win_get_cursor(self.containers.selected_files.winid)[1]
    remove_file(line_number)
  end, { noremap = true, silent = true })

  self.containers.selected_files:map("x", Config.mappings.sidebar.remove_file, function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local start_line = math.min(vim.fn.line("v"), vim.fn.line("."))
    local end_line = math.max(vim.fn.line("v"), vim.fn.line("."))
    for _ = start_line, end_line do
      remove_file(start_line)
    end
  end, { noremap = true, silent = true })

  self.containers.selected_files:map(
    "n",
    Config.mappings.sidebar.add_file,
    function() self.file_selector:open() end,
    { noremap = true, silent = true }
  )

  -- Set up autocmd to show hint on cursor move
  self.containers.selected_files:on({ event.CursorMoved }, function() self:show_selected_files_hint() end, {})

  -- Clear hint when leaving the window
  self.containers.selected_files:on(event.BufLeave, function() self:close_selected_files_hint() end, {})

  self:setup_window_navigation(self.containers.selected_files)

  render()
end

function Sidebar:create_plan_container()
  Utils.debug("create_plan_container called, bufnr=" .. tostring(self.code.bufnr))

  -- Respect toggle state — if user hid the plan, don't show it
  if not self._plan_visible then
    if self.containers.plan and Utils.is_valid_container(self.containers.plan) then
      self.containers.plan:unmount()
    end
    self.containers.plan = nil
    return
  end

  local history = self.chat_history or Path.history.load(self.code.bufnr)
  Utils.debug("Plan container: todos count=" .. #(history.todos or {}))
  if not history.todos or #history.todos == 0 then
    Utils.debug("No todos, unmounting plan container")
    if self.containers.plan and Utils.is_valid_container(self.containers.plan) then
      self.containers.plan:unmount()
    end
    self.containers.plan = nil
    self:adjust_layout()
    return
  end

  -- Calculate safe height: entries + 1 header, capped at 12
  local safe_height = math.min(#history.todos + 1, 12)
  safe_height = math.min(safe_height, math.max(1, vim.o.lines - 5))

  if not Utils.is_valid_container(self.containers.plan, true) then
    self.containers.plan = Split({
      enter = false,
      relative = {
        type = "win",
        winid = self:get_split_candidate("plan"),
      },
      buf_options = vim.tbl_deep_extend("force", buf_options, {
        modifiable = true,
        swapfile = false,
        buftype = "acwrite",
        buflisted = false,
        bufhidden = "wipe",
        filetype = "markdown",
      }),
      win_options = vim.tbl_deep_extend("force", base_win_options, {
        fillchars = Config.windows.fillchars,
      }),
      position = "bottom",
      size = {
        height = safe_height,
      },
    })

    local ok, err = pcall(function()
      self.containers.plan:mount()
      self:setup_window_navigation(self.containers.plan)
    end)
    if not ok then
      Utils.debug("Failed to create plan container:", err)
      self.containers.plan = nil
      return
    end

    local plan_bufnr = api.nvim_win_get_buf(self.containers.plan.winid)

    -- Name the buffer so :wall doesn't fail with E141 (unnamed acwrite buffer)
    api.nvim_buf_set_name(plan_bufnr, "avante://plan")

    local function send_plan()
      local buf_lines = api.nvim_buf_get_lines(plan_bufnr, 0, -1, false)
      local edited_plan = self:parse_plan_buffer(buf_lines)
      self:send_plan_feedback(edited_plan)
      vim.bo[plan_bufnr].modified = false
    end

    -- :w on the plan buffer sends plan feedback
    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = plan_bufnr,
      callback = send_plan,
    })

    -- CR in normal mode toggles checkbox state and sends feedback
    vim.keymap.set("n", "<CR>", function()
      local row = api.nvim_win_get_cursor(self.containers.plan.winid)[1]
      local cur_line = api.nvim_buf_get_lines(plan_bufnr, row - 1, row, false)[1] or ""
      local new_line
      if cur_line:match("%- %[x%]") then
        new_line = cur_line:gsub("%- %[x%]", "- [~]", 1)
      elseif cur_line:match("%- %[~%]") then
        new_line = cur_line:gsub("%- %[~%]", "- [ ]", 1)
      elseif cur_line:match("%- %[ %]") then
        new_line = cur_line:gsub("%- %[ %]", "- [x]", 1)
      end
      if new_line then
        api.nvim_buf_set_lines(plan_bufnr, row - 1, row, false, { new_line })
        send_plan()
      end
    end, { buffer = plan_bufnr, noremap = true, silent = true, desc = "Toggle plan checkbox" })

    -- C-s sends plan feedback from any mode
    vim.keymap.set({ "n", "i" }, "<C-s>", send_plan, { buffer = plan_bufnr, noremap = true, silent = true, desc = "Send plan feedback" })
  end

  -- Render plan content as markdown checkboxes
  local done_count = 0
  local total_count = #history.todos
  local focused_idx = 1
  local plan_lines = {}
  for _, todo in ipairs(history.todos) do
    local checkbox = "- [ ] "
    if todo.status == "done" then
      done_count = done_count + 1
      checkbox = "- [x] "
    elseif todo.status == "doing" then
      checkbox = "- [~] "
    elseif todo.status == "cancelled" then
      checkbox = "- [x] ~~"
    end
    local line = checkbox .. (todo.content or "")
    if todo.status == "cancelled" then line = line .. "~~" end
    if todo.status ~= "todo" then focused_idx = focused_idx + 1 end
    table.insert(plan_lines, line)
  end
  if focused_idx > #plan_lines then focused_idx = #plan_lines end

  local plan_bufnr = api.nvim_win_get_buf(self.containers.plan.winid)
  api.nvim_buf_set_lines(plan_bufnr, 0, -1, false, plan_lines)
  pcall(function() api.nvim_win_set_cursor(self.containers.plan.winid, { focused_idx, 0 }) end)

  self:render_header(
    self.containers.plan.winid,
    plan_bufnr,
    Utils.icon(" ") .. "Plan" .. " (" .. done_count .. "/" .. total_count .. ")",
    Highlights.SUBTITLE,
    Highlights.REVERSED_SUBTITLE
  )

  local ok2, err2 = pcall(function() self:adjust_layout() end)
  if not ok2 then Utils.debug("Failed to adjust layout after plan creation:", err2) end
end

--- Parse markdown checkbox lines back into plan entries
---@param lines string[]
---@return avante.TODO[]
function Sidebar:parse_plan_buffer(lines)
  local entries = {}
  for _, line in ipairs(lines) do
    local status, content
    if line:match("^%- %[x%] ~~(.-)~~$") then
      content = line:match("^%- %[x%] ~~(.-)~~$")
      status = "cancelled"
    elseif line:match("^%- %[x%] (.+)$") then
      content = line:match("^%- %[x%] (.+)$")
      status = "done"
    elseif line:match("^%- %[~%] (.+)$") then
      content = line:match("^%- %[~%] (.+)$")
      status = "doing"
    elseif line:match("^%- %[ %] (.+)$") then
      content = line:match("^%- %[ %] (.+)$")
      status = "todo"
    end
    if content then
      table.insert(entries, { content = content, status = status })
    end
  end
  return entries
end

--- Send edited plan back to the agent as a user message
---@param edited_plan avante.TODO[]
function Sidebar:send_plan_feedback(edited_plan)
  -- Update internal state
  if self.chat_history then
    self.chat_history.todos = edited_plan
    Path.history.save(self.code.bufnr, self.chat_history)
  end
  if self.acp_thread then
    self.acp_thread.plan_entries = edited_plan
  end

  -- Build a message describing the updated plan
  local msg_lines = { "I've updated the plan. Here are my changes:", "" }
  for i, entry in ipairs(edited_plan) do
    local checkbox = "[ ] "
    if entry.status == "done" then
      checkbox = "[x] "
    elseif entry.status == "doing" then
      checkbox = "[~] "
    elseif entry.status == "cancelled" then
      checkbox = "[x] ~~"
    end
    local suffix = entry.status == "cancelled" and "~~" or ""
    table.insert(msg_lines, i .. ". " .. checkbox .. (entry.content or "") .. suffix)
  end
  table.insert(msg_lines, "")
  table.insert(msg_lines, "Please follow this updated plan.")

  local message = table.concat(msg_lines, "\n")
  self:handle_submit(message)
end

function Sidebar:adjust_layout()
  -- Guard: result container must exist before adjusting layout
  if not self.containers.result or not self.containers.result.winid then return end

  self:adjust_result_container_layout()
  self:adjust_plan_container_layout()
  self:adjust_selected_code_container_layout()
  self:adjust_selected_files_container_layout()
end

return Sidebar