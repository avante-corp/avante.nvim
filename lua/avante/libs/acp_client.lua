---@mod avante-acp Agent Client Protocol support
---
---@brief [[
---
---Avante supports the Agent Client Protocol (ACP) through the official Rust SDK.
---ACP standardizes communication between editors and AI agents for sessions,
---streamed responses, and tool calls. See
---https://agentclientprotocol.com/overview/introduction.
---
---The native Rust module handles protocol messages and agent process lifecycle;
---this Lua client handles UI, history, permission, and buffer integration.
---@brief ]]
---@see avante-config

---@class avante.acp.EnvVariable
---@field name string
---@field value string

---@class avante.acp.McpServer
---@field type? "stdio"|"http"|"sse"
---@field name string
---@field command? string
---@field args? string[]
---@field env? avante.acp.EnvVariable[]
---@field url? string
---@field headers? avante.acp.EnvVariable[]

---@class avante.acp.PermissionOption
---@field optionId string
---@field name string
---@field kind "allow_once"|"allow_always"|"reject_once"|"reject_always"

---@class avante.acp.ToolCall
---@field toolCallId string
---@field title string
---@field kind string
---@field status string
---@field content? table[]
---@field locations? table[]
---@field rawInput? table
---@field rawOutput? table

---@class avante.acp.ToolCallUpdate
---@field sessionUpdate "tool_call"|"tool_call_update"
---@field toolCallId string
---@field title? string
---@field kind? string
---@field status? string
---@field content? table[]
---@field locations? table[]
---@field rawInput? table
---@field rawOutput? table

---@class avante.acp.ConfigOptionValue
---@field value string
---@field name string
---@field description? string

---@class avante.acp.ConfigOption
---@field id string
---@field name string
---@field description? string
---@field category? string
---@field type string
---@field currentValue string|boolean
---@field options? avante.acp.ConfigOptionValue[]

---@class avante.acp.ACPError
---@field kind "invalid_request"|"invalid_input"|"unsupported"|"not_found"|"session_not_found"|"cancelled"|"authentication"|"timeout"|"internal"
---@field code? integer
---@field message string
---@field data? any

---@class avante.acp.SessionInfo
---@field sessionId string
---@field cwd string
---@field title? string
---@field updatedAt? string

---@class avante.acp.LoadSessionOpts
---@field on_replay? fun(update: table): boolean
---@field additional_directories? string[]

---@class ACPHandlers
---@field on_session_update? fun(update: table)
---@field on_config_change? fun()
---@field on_request_permission? fun(tool_call: table, options: table[], callback: fun(option_id: string|nil))
---@field on_read_file? fun(path: string, line: integer|nil, limit: integer|nil, callback: fun(content: string), error_callback: fun(message: string, kind?: string))
---@field on_write_file? fun(path: string, content: string, callback: fun(error_message?: string))
---@field on_error? fun(error: table)
---@field on_state_change? fun(state: string)

---@class avante.acp.ClientConfig : AvanteACPProvider
---@field handlers? ACPHandlers

---@class avante.acp.ACPClient
---@field config avante.acp.ClientConfig
---@field connection_state "disconnected"|"connecting"|"ready"|"error"
---@field native userdata|table|nil
---@field native_generation integer
---@field callbacks table<integer, fun(result: table|nil, err: avante.acp.ACPError|nil)>
---@field connect_callbacks fun(err: avante.acp.ACPError|nil)[]
---@field stop_callbacks fun(err: avante.acp.ACPError|nil)[]
---@field session_replay_handlers table<string, fun(update: table): boolean>
---@field loading_sessions table<string, table>
---@field pending_session_operations integer
---@field session_commands table<string, { name: string, description?: string }[]>
---@field poll_timer any
---@field reconnect_count integer
---@field stop_requested boolean
---@field is_stopping boolean
---@field supports_load boolean
---@field supports_list boolean
---@field active_session_id string|nil
---@field active_session_setup table|nil
---@field reconnect_pending boolean
---@field restoring_session boolean
---@field config_options avante.acp.ConfigOption[]|nil
---@field protected _native_module? table
---@field on_dispose? fun()
---@field update_request_context? fun(opts: AvanteLLMStreamOptions)
local ACPClient = {}
ACPClient.__index = ACPClient
local NATIVE_API_VERSION = 3

local function create_error(kind, message, data) return { kind = kind, message = message, data = data } end

local function report_handler_error(self, err)
  local handler = self.config.handlers and self.config.handlers.on_error
  if handler then pcall(handler, create_error("internal", tostring(err))) end
end

local function load_native()
  local ok, native = pcall(require, "avante_acp")
  if ok then return native end
  error("Failed to load avante_acp native module: " .. tostring(native))
end

local function set_connection_state(self, state)
  if self.connection_state == state then return end
  self.connection_state = state
  local handler = self.config.handlers and self.config.handlers.on_state_change
  if handler then
    local ok, err = pcall(handler, state)
    if not ok then report_handler_error(self, err) end
  end
end

local function native_config(self)
  return {
    command = self.config.command,
    args = self.config.args or {},
    env = self.config.env or {},
    authMethod = self.config.auth_method,
    readTextFile = self.config.handlers and self.config.handlers.on_read_file ~= nil,
    writeTextFile = self.config.handlers and self.config.handlers.on_write_file ~= nil,
    sessionCloseTimeoutMs = self.config.session_close_timeout,
  }
end

---@param config avante.acp.ClientConfig
---@return avante.acp.ACPClient
function ACPClient:new(config)
  if config.transport_type and config.transport_type ~= "stdio" then
    error(
      "The official ACP Rust process adapter only supports stdio transport (got "
        .. tostring(config.transport_type)
        .. ")"
    )
  end
  config = vim.tbl_extend("force", config, { session_close_timeout = config.session_close_timeout or 500 })
  return setmetatable({
    config = config,
    connection_state = "disconnected",
    native = nil,
    native_generation = 0,
    callbacks = {},
    connect_callbacks = {},
    stop_callbacks = {},
    session_replay_handlers = {},
    loading_sessions = {},
    pending_session_operations = 0,
    session_commands = {},
    poll_timer = nil,
    reconnect_count = 0,
    stop_requested = false,
    is_stopping = false,
    supports_load = false,
    supports_list = false,
    active_session_id = nil,
    active_session_setup = nil,
    reconnect_pending = false,
    restoring_session = false,
    config_options = nil,
  }, self)
end

function ACPClient.is_same_process_config(left, right)
  if not left or not right then return false end
  return left.command == right.command
    and vim.deep_equal(left.args or {}, right.args or {})
    and vim.deep_equal(left.env or {}, right.env or {})
    and left.auth_method == right.auth_method
    and (left.transport_type or "stdio") == (right.transport_type or "stdio")
    and (left.reconnect == true) == (right.reconnect == true)
    and (left.max_reconnect_attempts or 3) == (right.max_reconnect_attempts or 3)
    and (left.session_close_timeout or 500) == (right.session_close_timeout or 500)
end

function ACPClient._slice_lines(lines, line, limit)
  local first = line or 1
  local last = limit == nil and #lines or math.min(#lines, first + limit - 1)
  local result = {}
  for index = first, last do
    if lines[index] ~= nil then table.insert(result, lines[index]) end
  end
  return result
end

function ACPClient:_start_polling()
  if self.poll_timer then return end
  local timer = (vim.uv or vim.loop).new_timer()
  if not timer then error("Failed to create ACP event timer") end
  self.poll_timer = timer
  timer:start(
    0,
    10,
    vim.schedule_wrap(function()
      if self.poll_timer == timer then self:_poll_events() end
    end)
  )
end

function ACPClient:_poll_events()
  local native, generation = self.native, self.native_generation
  if not native then return end
  local ok, events = pcall(native.poll, native)
  if not ok then
    events = {
      {
        type = "fatal_error",
        error = create_error("internal", tostring(events)),
      },
    }
  end
  for _, event in ipairs(events or {}) do
    if self.native ~= native or self.native_generation ~= generation then break end
    local handled, err = pcall(self._handle_event, self, event)
    if not handled then report_handler_error(self, err) end
  end
end

function ACPClient:_stop_polling()
  local timer = self.poll_timer
  self.poll_timer = nil
  if not timer then return end
  pcall(timer.stop, timer)
  if not timer:is_closing() then pcall(timer.close, timer) end
end

local function finish_connect(self, err)
  local callbacks = self.connect_callbacks
  self.connect_callbacks = {}
  for _, callback in ipairs(callbacks) do
    pcall(callback, err)
  end
end

local function dispose(self)
  local callback = self.on_dispose
  self.on_dispose = nil
  if callback then pcall(callback) end
end

local function finish_stop(self, err)
  local connecting, operations, callbacks = self.connect_callbacks, self.callbacks, self.stop_callbacks
  local on_dispose = self.on_dispose
  self.connect_callbacks, self.callbacks, self.stop_callbacks = {}, {}, {}
  self.on_dispose = nil
  self:_stop_polling()
  self.native = nil
  self.session_replay_handlers = {}
  self.session_commands = {}
  self.active_session_id = nil
  self.active_session_setup = nil
  self.reconnect_pending = false
  self.restoring_session = false
  self.config_options = nil
  self.is_stopping = false
  set_connection_state(self, "disconnected")
  local failure = err or create_error("cancelled", "ACP client stopped")
  for _, callback in ipairs(connecting) do
    pcall(callback, failure)
  end
  for _, callback in pairs(operations) do
    pcall(callback, nil, failure)
  end
  if self.native then
    self.on_dispose = self.on_dispose or on_dispose
  elseif on_dispose then
    pcall(on_dispose)
  end
  for _, callback in ipairs(callbacks) do
    pcall(callback, err)
  end
end

local function operation_error(err) return create_error("internal", (tostring(err):gsub("^.-:%d+: ", ""))) end

local function start_operation(self, method, callback, ...)
  callback = callback or function() end
  if self.connection_state ~= "ready" or self.is_stopping or not self.native then
    callback(nil, create_error("invalid_request", "ACP client is not ready"))
    return
  end
  local native_method = self.native[method]
  if type(native_method) ~= "function" then
    callback(nil, create_error("internal", "Native ACP method is unavailable: " .. method))
    return
  end
  local ok, start = pcall(native_method, self.native, ...)
  if not ok then
    callback(nil, operation_error(start))
    return
  end
  if type(start) ~= "table" then
    callback(nil, create_error("internal", "Native ACP method returned an invalid operation result"))
    return
  end
  if start.error then
    callback(nil, start.error)
    return
  end
  if type(start.operationId) ~= "number" then
    callback(nil, create_error("internal", "Native ACP method did not return an operation ID"))
    return
  end
  self.callbacks[start.operationId] = callback
end

local function send_native(self, method, ...)
  if not self.native then return end
  local generation, native = self.native_generation, self.native
  if type(native[method]) ~= "function" then return end
  local ok, err = pcall(native[method], native, ...)
  if not ok and generation == self.native_generation then
    self:_handle_event({ type = "fatal_error", error = operation_error(err) })
  end
end

local function responder(self, event)
  local generation = self.native_generation
  local completed = false
  return function(method, ...)
    if completed or generation ~= self.native_generation then return end
    completed = true
    send_native(self, method, event.requestId, ...)
  end
end

local function replace_config_options(self, options)
  self.config_options = type(options) == "table" and #options > 0 and options or nil
end

local function apply_config_value(self, change)
  if type(change) ~= "table" or not self.config_options then return end
  for _, option in ipairs(self.config_options) do
    if option.id == change.id then
      option.currentValue = change.currentValue
      return
    end
  end
end

local function apply_config_result(self, result)
  if type(result) ~= "table" then return end
  if result.configOptions ~= nil then replace_config_options(self, result.configOptions) end
  apply_config_value(self, result.configValue)
end

local function should_reconnect(self)
  return not self.stop_requested
    and self.config.reconnect == true
    and self.reconnect_count < (self.config.max_reconnect_attempts or 3)
end

local function finish_ready(self)
  local session_id = self.reconnect_pending and self.active_session_id or nil
  local setup = session_id and self.active_session_setup or nil
  self.restoring_session = setup ~= nil
  set_connection_state(self, "ready")
  if not setup then
    self.reconnect_pending = false
    self.reconnect_count = 0
    finish_connect(self, nil)
    return
  end

  self:load_session(session_id, setup.cwd, setup.mcpServers, function(_, err)
    self.restoring_session = false
    self.reconnect_pending = false
    if err then
      finish_connect(self, err)
      self:stop()
      local handler = self.config.handlers and self.config.handlers.on_error
      if handler then pcall(handler, err) end
      return
    end
    self.reconnect_count = 0
    finish_connect(self, nil)
  end, { additional_directories = setup.additionalDirectories })
end

local function handle_session_update(self, event)
  local notification = event.notification
  if type(notification) ~= "table" or type(notification.update) ~= "table" then return end
  local update = notification.update
  if event.replayed then update._replayed = true end
  local is_config_update = event.configOptions ~= nil or event.configValue ~= nil
  if notification.sessionId == self.active_session_id then
    if event.configOptions ~= nil then replace_config_options(self, event.configOptions) end
    if event.configValue ~= nil then apply_config_value(self, event.configValue) end
    local config_handler = self.config.handlers and self.config.handlers.on_config_change
    if is_config_update and config_handler then config_handler() end
  end
  if is_config_update then return end
  if
    update.sessionUpdate == "available_commands_update"
    and (
      not self.active_session_id
      or notification.sessionId == self.active_session_id
      or self.loading_sessions[notification.sessionId]
    )
  then
    self.session_commands[notification.sessionId] = update.availableCommands or {}
  end
  local replay_handler = self.session_replay_handlers[notification.sessionId]
  if event.replayed and replay_handler and replay_handler(update) then return end
  if self.active_session_id and notification.sessionId ~= self.active_session_id then return end
  local handler = self.config.handlers and self.config.handlers.on_session_update
  if handler then handler(update) end
end

local function handle_permission(self, event)
  local session_id = event.request.sessionId
  if self.active_session_id and session_id ~= self.active_session_id and not self.loading_sessions[session_id] then
    send_native(self, "respond_permission", event.requestId, nil)
    return
  end
  local handler = self.config.handlers and self.config.handlers.on_request_permission
  if not handler then
    send_native(self, "respond_error", event.requestId, "unsupported", "Permission handler not configured")
    return
  end
  local respond = responder(self, event)
  local ok, err = pcall(
    handler,
    event.request.toolCall,
    event.request.options,
    function(option_id) respond("respond_permission", option_id) end
  )
  if not ok then respond("respond_error", "internal", operation_error(err).message) end
end

local function handle_read(self, event)
  local handler = self.config.handlers and self.config.handlers.on_read_file
  if not handler then
    send_native(self, "respond_error", event.requestId, "unsupported", "Read file handler not configured")
    return
  end
  local respond = responder(self, event)
  local ok, err = pcall(handler, event.request.path, event.request.line, event.request.limit, function(content)
    if type(content) ~= "string" then
      respond("respond_error", "invalid_input", "Read file handler must return a string")
      return
    end
    respond("respond_read_text_file", content)
  end, function(message, kind) respond("respond_error", kind or "internal", message) end)
  if not ok then respond("respond_error", "internal", operation_error(err).message) end
end

local function handle_write(self, event)
  local handler = self.config.handlers and self.config.handlers.on_write_file
  if not handler then
    send_native(self, "respond_error", event.requestId, "unsupported", "Write file handler not configured")
    return
  end
  local respond = responder(self, event)
  local ok, err = pcall(handler, event.request.path, event.request.content, function(err)
    if err then
      respond("respond_error", "internal", err)
    else
      respond("respond_write_text_file")
    end
  end)
  if not ok then respond("respond_error", "internal", operation_error(err).message) end
end

function ACPClient:_handle_event(event)
  if
    self.is_stopping
    and (
      event.type == "session_update"
      or event.type == "permission_request"
      or event.type == "read_text_file_request"
      or event.type == "write_text_file_request"
    )
  then
    return
  end
  if event.type == "state_changed" then
    if event.state == "connecting" then
      set_connection_state(self, "connecting")
    elseif event.state == "ready" then
      finish_ready(self)
    elseif event.state == "disconnected" then
      if self.is_stopping then
        finish_stop(self, nil)
      else
        self.native = nil
        self:_stop_polling()
        set_connection_state(self, "disconnected")
        if self.native then return end
        if should_reconnect(self) then
          self.reconnect_count = self.reconnect_count + 1
          self.reconnect_pending = true
          local generation = self.native_generation
          vim.defer_fn(function()
            if
              self.connection_state == "disconnected"
              and self.reconnect_pending
              and not self.stop_requested
              and self.native_generation == generation
            then
              self:connect(function() end)
            end
          end, 2000)
        else
          self.active_session_id = nil
          self.active_session_setup = nil
          self.reconnect_pending = false
          dispose(self)
        end
      end
    end
  elseif event.type == "initialized" then
    self.supports_load = event.supportsLoadSession == true
    self.supports_list = event.supportsListSessions == true
  elseif event.type == "operation_completed" or event.type == "operation_failed" then
    local callback = self.callbacks[event.operationId]
    self.callbacks[event.operationId] = nil
    if callback then callback(event.result, event.error) end
  elseif event.type == "session_update" then
    handle_session_update(self, event)
  elseif event.type == "permission_request" then
    handle_permission(self, event)
  elseif event.type == "read_text_file_request" then
    handle_read(self, event)
  elseif event.type == "write_text_file_request" then
    handle_write(self, event)
  elseif event.type == "fatal_error" then
    local native, generation = self.native, self.native_generation
    local connecting, operations = self.connect_callbacks, self.callbacks
    self.connect_callbacks, self.callbacks = {}, {}
    set_connection_state(self, "error")
    for _, callback in ipairs(connecting) do
      pcall(callback, event.error)
    end
    for _, callback in pairs(operations) do
      pcall(callback, nil, event.error)
    end
    if self.native ~= native or self.native_generation ~= generation then return end
    if should_reconnect(self) then
      local stopped = self.native and pcall(self.native.stop, self.native)
      if not stopped then self:_handle_event({ type = "state_changed", state = "disconnected" }) end
    else
      self:stop()
    end
    local handler = self.config.handlers and self.config.handlers.on_error
    if handler then handler(event.error) end
  end
end

function ACPClient:connect(callback)
  callback = callback or function() end
  if self.connection_state == "ready" then
    callback(nil)
    return
  end
  table.insert(self.connect_callbacks, callback)
  if self.connection_state ~= "disconnected" and self.connection_state ~= "error" then return end
  self.stop_requested = false
  set_connection_state(self, "connecting")
  local ok, err = pcall(function()
    local native = self._native_module or load_native()
    if native.api_version ~= NATIVE_API_VERSION then
      error(
        string.format(
          "Incompatible avante_acp native module (expected API %d, got %s); rebuild or reinstall Avante's native libraries",
          NATIVE_API_VERSION,
          tostring(native.api_version or "missing")
        )
      )
    end
    self.native_generation = self.native_generation + 1
    self.session_commands = {}
    self.native = native.new(native_config(self))
    self:_start_polling()
    self.native:start()
  end)
  if not ok then
    local callbacks, generation = self.connect_callbacks, self.native_generation
    self.connect_callbacks = {}
    self.native = nil
    self:_stop_polling()
    set_connection_state(self, "error")
    local failure = create_error("internal", tostring(err))
    for _, pending in ipairs(callbacks) do
      pcall(pending, failure)
    end
    if not self.native and self.native_generation == generation then dispose(self) end
  end
end

function ACPClient:initialize(callback) self:connect(callback) end

function ACPClient:stop(callback)
  if callback then table.insert(self.stop_callbacks, callback) end
  if self.is_stopping then return end
  self.stop_requested = true
  self.is_stopping = true
  if not self.native then
    finish_stop(self, nil)
    return
  end
  local ok, err = pcall(self.native.stop, self.native)
  if not ok then
    finish_stop(self, operation_error(err))
    return
  end
  local generation = self.native_generation
  vim.defer_fn(function()
    if self.is_stopping and self.native_generation == generation then
      finish_stop(self, create_error("timeout", "Timed out stopping ACP client"))
    end
  end, self.config.session_close_timeout + 1000)
end

function ACPClient:force_stop()
  if not self.native then return end
  self.stop_requested = true
  self.is_stopping = true
  pcall(self.native.force_stop, self.native)
  finish_stop(self, nil)
end

local function session_setup(self, cwd, mcp_servers, additional_directories)
  return {
    cwd = cwd,
    mcpServers = mcp_servers or {},
    additionalDirectories = additional_directories or self.config.additional_directories or {},
  }
end

function ACPClient:create_session(cwd, mcp_servers, callback, additional_directories)
  local setup = session_setup(self, cwd, mcp_servers, additional_directories)
  self.pending_session_operations = self.pending_session_operations + 1
  start_operation(self, "new_session", function(result, err)
    self.pending_session_operations = self.pending_session_operations - 1
    local session_id = result and result.sessionId
    if err or type(session_id) ~= "string" or session_id == "" then
      callback(nil, err or create_error("internal", "session/new returned an invalid sessionId"))
      return
    end
    self.active_session_id = session_id
    self.active_session_setup = setup
    apply_config_result(self, result)
    callback(session_id, nil)
  end, setup)
end

function ACPClient:load_session(session_id, cwd, mcp_servers, callback, opts)
  if self.loading_sessions[session_id] then
    callback(nil, create_error("invalid_request", "Session is already loading"))
    return
  end
  local setup = session_setup(self, cwd, mcp_servers, opts and opts.additional_directories)
  local loading = {}
  self.loading_sessions[session_id] = loading
  self.pending_session_operations = self.pending_session_operations + 1
  if opts and opts.on_replay then self.session_replay_handlers[session_id] = opts.on_replay end
  start_operation(self, "load_session", function(result, err)
    if self.loading_sessions[session_id] == loading then
      self.session_replay_handlers[session_id] = nil
      self.loading_sessions[session_id] = nil
    end
    self.pending_session_operations = self.pending_session_operations - 1
    if not err then
      self.active_session_id = session_id
      self.active_session_setup = setup
      apply_config_result(self, result)
    end
    callback(result, err)
  end, session_id, setup)
end

function ACPClient:resume_session(session_id, cwd, mcp_servers, callback, additional_directories)
  local setup = session_setup(self, cwd, mcp_servers, additional_directories)
  self.pending_session_operations = self.pending_session_operations + 1
  start_operation(self, "resume_session", function(result, err)
    self.pending_session_operations = self.pending_session_operations - 1
    if not err then
      self.active_session_id = session_id
      self.active_session_setup = setup
      apply_config_result(self, result)
    end
    callback(result, err)
  end, session_id, setup)
end

function ACPClient:close_session(session_id, callback)
  start_operation(self, "close_session", function(_, err)
    if not err then self.session_commands[session_id] = nil end
    if not err and self.active_session_id == session_id then
      self.active_session_id = nil
      self.active_session_setup = nil
      self.config_options = nil
    end
    (callback or function() end)(err)
  end, session_id)
end

function ACPClient:delete_session(session_id, callback)
  start_operation(self, "delete_session", function(_, err)
    if not err then self.session_commands[session_id] = nil end
    if not err and self.active_session_id == session_id then
      self.active_session_id = nil
      self.active_session_setup = nil
      self.config_options = nil
    end
    (callback or function() end)(err)
  end, session_id)
end

function ACPClient:supports_load_session() return self.supports_load end
function ACPClient:supports_list_sessions() return self.supports_list end

function ACPClient:list_all_sessions(cwd, callback)
  start_operation(
    self,
    "list_sessions",
    function(result, err) callback(type(result) == "table" and result or {}, err) end,
    cwd
  )
end

function ACPClient:set_session_option(session_id, config_id, value, callback)
  start_operation(self, "set_session_option", function(result, err)
    if not err and self.active_session_id == session_id then apply_config_result(self, result) end
    (callback or function() end)(err and nil or self.config_options, err)
  end, session_id, config_id, value)
end

function ACPClient:send_prompt(session_id, prompt, callback)
  start_operation(self, "prompt", callback, session_id, prompt)
end

function ACPClient:cancel_session(session_id) send_native(self, "cancel", session_id) end

---Whether the client can accept a new operation.
---@return boolean
function ACPClient:is_ready()
  return self.connection_state == "ready"
    and not self.is_stopping
    and not self.restoring_session
    and self.pending_session_operations == 0
end

return ACPClient
