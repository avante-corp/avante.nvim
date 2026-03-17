local Config = require("avante.config")
local Utils = require("avante.utils")

---@class avante.acp.ClientCapabilities
---@field fs avante.acp.FileSystemCapability

---@class avante.acp.FileSystemCapability
---@field readTextFile boolean
---@field writeTextFile boolean

---@class avante.acp.AgentCapabilities
---@field loadSession boolean
---@field promptCapabilities avante.acp.PromptCapabilities

---@class avante.acp.PromptCapabilities
---@field image boolean
---@field audio boolean
---@field embeddedContext boolean

---@class avante.acp.AuthMethod
---@field id string
---@field name string
---@field description string|nil

---@class avante.acp.McpServer
---@field name string
---@field command string
---@field args string[]
---@field env avante.acp.EnvVariable[]

---@class avante.acp.EnvVariable
---@field name string
---@field value string

---@alias ACPStopReason "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled"

---@alias ACPToolKind "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other"

---@alias ACPToolCallStatus "pending" | "in_progress" | "completed" | "failed"

---@alias ACPPlanEntryStatus "pending" | "in_progress" | "completed"

---@alias ACPPlanEntryPriority "high" | "medium" | "low"

---@class avante.acp.BaseContent
---@field type "text" | "image" | "audio" | "resource_link" | "resource"
---@field annotations avante.acp.Annotations|nil

---@class avante.acp.TextContent : avante.acp.BaseContent
---@field type "text"
---@field text string

---@class avante.acp.ImageContent : avante.acp.BaseContent
---@field type "image"
---@field data string
---@field mimeType string
---@field uri string|nil

---@class avante.acp.AudioContent : avante.acp.BaseContent
---@field type "audio"
---@field data string
---@field mimeType string

---@class avante.acp.ResourceLinkContent : avante.acp.BaseContent
---@field type "resource_link"
---@field uri string
---@field name string
---@field description string|nil
---@field mimeType string|nil
---@field size number|nil
---@field title string|nil

---@class avante.acp.ResourceContent : avante.acp.BaseContent
---@field type "resource"
---@field resource avante.acp.EmbeddedResource

---@class avante.acp.EmbeddedResource
---@field uri string
---@field text string|nil
---@field blob string|nil
---@field mimeType string|nil

---@class avante.acp.Annotations
---@field audience any[]|nil
---@field lastModified string|nil
---@field priority number|nil

---@alias ACPContent avante.acp.TextContent | avante.acp.ImageContent | avante.acp.AudioContent | avante.acp.ResourceLinkContent | avante.acp.ResourceContent

---@class avante.acp.ToolCall
---@field toolCallId string
---@field title string
---@field kind ACPToolKind
---@field status ACPToolCallStatus
---@field content ACPToolCallContent[]
---@field locations avante.acp.ToolCallLocation[]
---@field rawInput table
---@field rawOutput table

---@class avante.acp.BaseToolCallContent
---@field type "content" | "diff"

---@class avante.acp.ToolCallRegularContent : avante.acp.BaseToolCallContent
---@field type "content"
---@field content ACPContent

---@class avante.acp.ToolCallDiffContent : avante.acp.BaseToolCallContent
---@field type "diff"
---@field path string
---@field oldText string|nil
---@field newText string

---@alias ACPToolCallContent avante.acp.ToolCallRegularContent | avante.acp.ToolCallDiffContent

---@class avante.acp.ToolCallLocation
---@field path string
---@field line number|nil

---@class avante.acp.PlanEntry
---@field content string
---@field priority ACPPlanEntryPriority
---@field status "pending"|"in_progress"|"completed"|nil

---@class avante.acp.SessionMode
---@field id string
---@field name string
---@field description string|nil

---@class avante.acp.SessionModeState
---@field current_mode_id string
---@field modes avante.acp.SessionMode[]
---@field status ACPPlanEntryStatus

---@class avante.acp.Plan
---@field entries avante.acp.PlanEntry[]

---@class avante.acp.AvailableCommand
---@field name string
---@field description string
---@field input? table<string, any>

---@class avante.acp.ConfigOption
---@field id string
---@field name string
---@field description? string
---@field category? string  -- "mode", "model", "thought_level", or custom "_*"
---@field type string       -- currently only "select"
---@field currentValue string
---@field options avante.acp.ConfigOptionValue[]

---@class avante.acp.ConfigOptionValue
---@field value string
---@field name string
---@field description? string

---@class avante.acp.ConfigOptionsUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "config_options_update"
---@field configOptions avante.acp.ConfigOption[]

---@class avante.acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan" | "available_commands_update" | "current_mode_update" | "config_options_update"

---@class avante.acp.UserMessageChunk : avante.acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk"
---@field content ACPContent

---@class avante.acp.AgentMessageChunk : avante.acp.BaseSessionUpdate
---@field sessionUpdate "agent_message_chunk"
---@field content ACPContent

---@class avante.acp.AgentThoughtChunk : avante.acp.BaseSessionUpdate
---@field sessionUpdate "agent_thought_chunk"
---@field content ACPContent

---@class avante.acp.ToolCallUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "tool_call" | "tool_call_update"
---@field toolCallId string
---@field title string|nil
---@field kind ACPToolKind|nil
---@field status ACPToolCallStatus|nil
---@field content ACPToolCallContent[]|nil
---@field locations avante.acp.ToolCallLocation[]|nil
---@field rawInput table|nil
---@field rawOutput table|nil

---@class avante.acp.PlanUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "plan"
---@field entries avante.acp.PlanEntry[]

---@class avante.acp.AvailableCommandsUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "available_commands_update"
---@field availableCommands avante.acp.AvailableCommand[]

---@class avante.acp.CurrentModeUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "current_mode_update"
---@field currentModeId string

---@class avante.acp.PermissionOption
---@field optionId string
---@field name string
---@field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

---@class avante.acp.RequestPermissionOutcome
---@field outcome "cancelled" | "selected"
---@field optionId string|nil

---@class avante.acp.ACPTransport
---@field send function
---@field start function
---@field stop function

---@alias ACPConnectionState "disconnected" | "connecting" | "connected" | "initializing" | "ready" | "error"

---@class avante.acp.ACPError
---@field code number
---@field message string
---@field data any|nil

---@class avante.acp.ACPClient
---@field protocol_version number
---@field capabilities avante.acp.ClientCapabilities
---@field agent_capabilities avante.acp.AgentCapabilities|nil
---@field config ACPConfig
---@field callbacks table<number, fun(result: table|nil, err: avante.acp.ACPError|nil)>
---@field debug_log_file file*|nil
local ACPClient = {}

-- ACP Error codes
ACPClient.ERROR_CODES = {
  -- JSON-RPC 2.0
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603,
  -- ACP
  AUTH_REQUIRED = -32000,
  RESOURCE_NOT_FOUND = -32002,
}

---@class ACPHandlers
---@field on_session_update? fun(update: avante.acp.UserMessageChunk | avante.acp.AgentMessageChunk | avante.acp.AgentThoughtChunk | avante.acp.ToolCallUpdate | avante.acp.PlanUpdate | avante.acp.AvailableCommandsUpdate | avante.acp.CurrentModeUpdate)
---@field on_request_permission? fun(tool_call: table, options: table[], callback: fun(option_id: string | nil)): nil
---@field on_read_file? fun(path: string, line: integer | nil, limit: integer | nil, callback: fun(content: string), error_callback: fun(message: string, code: integer|nil)): nil
---@field on_write_file? fun(path: string, content: string, callback: fun(error: string|nil)): nil
---@field on_error? fun(error: table)

---@class ACPConfig
---@field transport_type "stdio" | "websocket" | "tcp"
---@field command? string Command to spawn agent (for stdio)
---@field args? string[] Arguments for agent command
---@field env? table Environment variables
---@field host? string Host for tcp/websocket
---@field port? number Port for tcp/websocket
---@field timeout? number Request timeout in milliseconds
---@field reconnect? boolean Enable auto-reconnect
---@field max_reconnect_attempts? number Maximum reconnection attempts
---@field heartbeat_interval? number Heartbeat interval in milliseconds
---@field auth_method? string Authentication method
---@field handlers? ACPHandlers
---@field on_state_change? fun(new_state: ACPConnectionState, old_state: ACPConnectionState)

---Create a new ACP client instance
---@param config ACPConfig
---@return avante.acp.ACPClient
function ACPClient:new(config)
  local client = setmetatable({
    id_counter = 0,
    protocol_version = 1,
    capabilities = {
      fs = {
        readTextFile = true,
        writeTextFile = true,
      },
    },
    debug_log_file = nil,
    callbacks = {},
    transport = nil,
    config = config or {},
    state = "disconnected",
    reconnect_count = 0,
    heartbeat_timer = nil,
    session_modes = nil, ---@type avante.acp.SessionModeState|nil
    config_options = nil, ---@type avante.acp.ConfigOption[]|nil
    on_mode_changed = nil, ---@type fun(mode_id: string)|nil
    on_config_options_changed = nil, ---@type fun(config_options: avante.acp.ConfigOption[])|nil
  }, { __index = self })

  client:_setup_transport()
  return client
end

---Write debug log message
---@param message string
function ACPClient:_debug_log(message)
  if not Config.debug then
    self:_close_debug_log()
    return
  end

  -- Open file if needed
  if not self.debug_log_file then self.debug_log_file = io.open("/tmp/avante-acp-session.log", "a") end

  if self.debug_log_file then
    self.debug_log_file:write(message)
    self.debug_log_file:flush()
  end
end

---Close debug log file
function ACPClient:_close_debug_log()
  if self.debug_log_file then
    self.debug_log_file:close()
    self.debug_log_file = nil
  end
end

---Setup transport layer
function ACPClient:_setup_transport()
  local transport_type = self.config.transport_type or "stdio"

  if transport_type == "stdio" then
    self.transport = self:_create_stdio_transport()
  elseif transport_type == "websocket" then
    self.transport = self:_create_websocket_transport()
  elseif transport_type == "tcp" then
    self.transport = self:_create_tcp_transport()
  else
    error("Unsupported transport type: " .. transport_type)
  end
end

---Set connection state
---@param state ACPConnectionState
function ACPClient:_set_state(state)
  local old_state = self.state
  self.state = state

  if self.config.on_state_change then self.config.on_state_change(state, old_state) end
end

---Create error object
---@param code number
---@param message string
---@param data any?
---@return avante.acp.ACPError
function ACPClient:_create_error(code, message, data)
  return {
    code = code,
    message = message,
    data = data,
  }
end

---Create stdio transport layer
function ACPClient:_create_stdio_transport()
  local uv = vim.uv or vim.loop

  --- @class avante.acp.ACPTransportInstance
  local transport = {
    --- @type uv.uv_pipe_t|nil
    stdin = nil,
    --- @type uv.uv_pipe_t|nil
    stdout = nil,
    --- @type uv.uv_process_t|nil
    process = nil,
  }

  --- @param transport_self avante.acp.ACPTransportInstance
  --- @param data string
  function transport.send(transport_self, data)
    if transport_self.stdin and not transport_self.stdin:is_closing() then
      transport_self.stdin:write(data .. "\n")
      return true
    end
    return false
  end

  --- @param transport_self avante.acp.ACPTransportInstance
  --- @param on_message fun(message: any)
  function transport.start(transport_self, on_message)
    self:_set_state("connecting")

    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)

    if not stdin or not stdout or not stderr then
      self:_set_state("error")
      error("Failed to create pipes for ACP agent")
    end

    local args = vim.deepcopy(self.config.args or {})
    local env = self.config.env

    -- Start with system environment and override with config env
    local final_env = {}

    local path = vim.fn.getenv("PATH")
    if path then final_env[#final_env + 1] = "PATH=" .. path end

    if env then
      for k, v in pairs(env) do
        final_env[#final_env + 1] = k .. "=" .. v
      end
    end

    ---@diagnostic disable-next-line: missing-fields
    local handle, pid = uv.spawn(self.config.command, {
      args = args,
      env = final_env,
      stdio = { stdin, stdout, stderr },
    }, function(code, signal)
      Utils.debug("ACP agent exited with code " .. code .. " and signal " .. signal)
      self:_set_state("disconnected")

      if transport_self.process then
        transport_self.process:close()
        transport_self.process = nil
      end

      -- Handle auto-reconnect
      if self.config.reconnect and self.reconnect_count < (self.config.max_reconnect_attempts or 3) then
        self.reconnect_count = self.reconnect_count + 1
        vim.defer_fn(function()
          if self.state == "disconnected" then self:connect(function(_err) end) end
        end, 2000) -- Wait 2 seconds before reconnecting
      end
    end)

    Utils.debug("Spawned ACP agent process with PID " .. tostring(pid))

    if not handle then
      self:_set_state("error")
      error("Failed to spawn ACP agent process")
    end

    transport_self.process = handle
    transport_self.stdin = stdin
    transport_self.stdout = stdout

    self:_set_state("connected")

    -- Read stdout
    local buffer = ""
    stdout:read_start(function(err, data)
      if err then
        vim.notify("ACP stdout error: " .. err, vim.log.levels.ERROR)
        self:_set_state("error")
        return
      end

      if data then
        buffer = buffer .. data

        -- Split on newlines and process complete JSON-RPC messages
        local lines = vim.split(buffer, "\n", { plain = true })
        buffer = lines[#lines] -- Keep incomplete line in buffer

        for i = 1, #lines - 1 do
          local line = vim.trim(lines[i])
          if line ~= "" then
            local ok, message = pcall(vim.json.decode, line)
            if ok then
              on_message(message)
            else
              vim.schedule(
                function() vim.notify("Failed to parse JSON-RPC message: " .. line, vim.log.levels.WARN) end
              )
            end
          end
        end
      end
    end)

    -- Read stderr for debugging
    stderr:read_start(function(_, data)
      -- if data then
      --   -- Filter out common session recovery error messages to avoid user confusion
      --   if not (data:match("Session not found") or data:match("session/prompt")) then
      --     vim.schedule(function() vim.notify("ACP stderr: " .. data, vim.log.levels.DEBUG) end)
      --   end
      -- end
    end)
  end

  --- @param transport_self avante.acp.ACPTransportInstance
  function transport.stop(transport_self)
    if transport_self.process and not transport_self.process:is_closing() then
      local process = transport_self.process
      transport_self.process = nil

      if not process then return end

      -- Try to terminate gracefully
      pcall(function() process:kill(15) end)
      -- then force kill, it'll fail harmlessly if already exited
      pcall(function() process:kill(9) end)
      process:close()
    end
    if transport_self.stdin then
      transport_self.stdin:close()
      transport_self.stdin = nil
    end
    if transport_self.stdout then
      transport_self.stdout:close()
      transport_self.stdout = nil
    end
    self:_set_state("disconnected")
  end

  return transport
end

---Create WebSocket transport layer (placeholder)
function ACPClient:_create_websocket_transport() error("WebSocket transport not implemented yet") end

---Create TCP transport layer (placeholder)
function ACPClient:_create_tcp_transport() error("TCP transport not implemented yet") end

---Generate next request ID
---@return number
function ACPClient:_next_id()
  self.id_counter = self.id_counter + 1
  return self.id_counter
end

---Send JSON-RPC request
---@param method string
---@param params table?
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:_send_request(method, params, callback)
  local id = self:_next_id()
  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }

  self.callbacks[id] = callback

  local data = vim.json.encode(message)
  self:_debug_log("request: " .. data .. string.rep("=", 100) .. "\n")
  self.transport:send(data)
end

---Send JSON-RPC notification
---@param method string
---@param params table?
function ACPClient:_send_notification(method, params)
  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  }

  local data = vim.json.encode(message)
  self:_debug_log("notification: " .. data .. string.rep("=", 100) .. "\n")
  self.transport:send(data)
end

---Send JSON-RPC result
---@param id number
---@param result table | string | vim.NIL | nil
---@return nil
function ACPClient:_send_result(id, result)
  local message = { jsonrpc = "2.0", id = id, result = result }

  local data = vim.json.encode(message)
  self:_debug_log("request: " .. data .. "\n" .. string.rep("=", 100) .. "\n")
  self.transport:send(data)
end

---Send JSON-RPC error
---@param id number
---@param message string
---@param code? number
---@return nil
function ACPClient:_send_error(id, message, code)
  code = code or self.ERROR_CODES.INTERNAL_ERROR
  local msg = { jsonrpc = "2.0", id = id, error = { code = code, message = message } }

  local data = vim.json.encode(msg)
  self.transport:send(data)
end

---Handle received message
---@param message table
function ACPClient:_handle_message(message)
  -- Check if this is a notification (has method but no id, or has both method and id for notifications)
  if message.method and not message.result and not message.error then
    -- This is a notification
    self:_handle_notification(message.id, message.method, message.params)
  elseif message.id and (message.result or message.error) then
    self:_debug_log("response: " .. vim.inspect(message) .. "\n" .. string.rep("=", 100) .. "\n")
    local callback = self.callbacks[message.id]
    if callback then
      callback(message.result, message.error)
      self.callbacks[message.id] = nil
    end
  else
    -- Unknown message type
    vim.notify("Unknown message type: " .. vim.inspect(message), vim.log.levels.WARN)
  end
end

---Handle notification
---@param method string
---@param params table
function ACPClient:_handle_notification(message_id, method, params)
  self:_debug_log("method: " .. method .. "\n")
  self:_debug_log(vim.inspect(params) .. "\n" .. string.rep("=", 100) .. "\n")
  if method == "session/update" then
    self:_handle_session_update(params)
  elseif method == "session/request_permission" then
    self:_handle_request_permission(message_id, params)
  elseif method == "fs/read_text_file" then
    self:_handle_read_text_file(message_id, params)
  elseif method == "fs/write_text_file" then
    self:_handle_write_text_file(message_id, params)
  else
    vim.notify("Unknown notification method: " .. method, vim.log.levels.WARN)
  end
end

---Handle session update notification
---@param params table
function ACPClient:_handle_session_update(params)
  local session_id = params.sessionId
  local update = params.update

  if not session_id then
    vim.notify("Received session/update without sessionId", vim.log.levels.WARN)
    return
  end

  if not update then
    vim.notify("Received session/update without update data", vim.log.levels.WARN)
    return
  end

  -- Debug log the session update type
  Utils.debug("session/update received: sessionUpdate=" .. tostring(update.sessionUpdate))
  if update.sessionUpdate == "plan" then
    Utils.debug("Plan update entries: " .. vim.inspect(update.entries))
  end

  -- Handle CurrentModeUpdate internally
  if update.sessionUpdate == "current_mode_update" then
    if self.session_modes then
      self.session_modes.current_mode_id = update.currentModeId
    end
    if self.on_mode_changed then
      vim.schedule(function() self.on_mode_changed(update.currentModeId) end)
    end
  end

  -- Handle ConfigOptionsUpdate internally
  if update.sessionUpdate == "config_options_update" then
    if update.configOptions then
      self.config_options = update.configOptions
      Utils.debug("Config options updated: " .. #self.config_options .. " options")
    end
    if self.on_config_options_changed then
      vim.schedule(function() self.on_config_options_changed(self.config_options) end)
    end
  end

  if self.config.handlers and self.config.handlers.on_session_update then
    vim.schedule(function() self.config.handlers.on_session_update(update) end)
  end
end

---Handle permission request notification
---@param message_id number
---@param params table
function ACPClient:_handle_request_permission(message_id, params)
  local session_id = params.sessionId
  local tool_call = params.toolCall
  local options = params.options

  if not session_id or not tool_call then 
    Utils.debug("Permission request missing sessionId or toolCall")
    return 
  end

  Utils.debug("Permission request received: session=" .. session_id .. ", tool=" .. (tool_call.kind or "unknown") .. ", message_id=" .. message_id)
  Utils.debug("Permission options: " .. vim.inspect(options))

  if self.config.handlers and self.config.handlers.on_request_permission then
    vim.schedule(function()
      self.config.handlers.on_request_permission(
        tool_call,
        options,
        function(option_id, result_data)
          Utils.debug("Permission response: message_id=" .. message_id .. ", option_id=" .. option_id)
          local result = {
            outcome = {
              outcome = "selected",
              optionId = option_id,
            },
          }
          -- Allow callers to include additional result fields (e.g. answer for AskUserQuestion)
          if result_data then
            result = vim.tbl_deep_extend("force", result, result_data)
          end
          self:_send_result(message_id, result)
          Utils.debug("Permission response sent successfully")
        end
      )
    end)
  else
    Utils.warn("No permission handler configured")
  end
end

---Handle fs/read_text_file requests
---@param message_id number
---@param params table
function ACPClient:_handle_read_text_file(message_id, params)
  local session_id = params.sessionId
  local path = params.path

  if not session_id or not path then
    self:_send_error(message_id, "Invalid fs/read_text_file params", ACPClient.ERROR_CODES.INVALID_PARAMS)
    return
  end

  if self.config.handlers and self.config.handlers.on_read_file then
    vim.schedule(function()
      self.config.handlers.on_read_file(
        path,
        params.line ~= vim.NIL and params.line or nil,
        params.limit ~= vim.NIL and params.limit or nil,
        function(content) self:_send_result(message_id, { content = content }) end,
        function(err, code) self:_send_error(message_id, err or "Failed to read file", code) end
      )
    end)
  else
    self:_send_error(message_id, "fs/read_text_file handler not configured", ACPClient.ERROR_CODES.METHOD_NOT_FOUND)
  end
end

---Handle fs/write_text_file requests
---@param message_id number
---@param params table
function ACPClient:_handle_write_text_file(message_id, params)
  local session_id = params.sessionId
  local path = params.path
  local content = params.content

  if not session_id or not path or not content then
    self:_send_error(message_id, "Invalid fs/write_text_file params", ACPClient.ERROR_CODES.INVALID_PARAMS)
    return
  end

  if self.config.handlers and self.config.handlers.on_write_file then
    vim.schedule(function()
      self.config.handlers.on_write_file(
        path,
        content,
        function(error) self:_send_result(message_id, error == nil and vim.NIL or error) end
      )
    end)
  else
    self:_send_error(message_id, "fs/write_text_file handler not configured", ACPClient.ERROR_CODES.METHOD_NOT_FOUND)
  end
end

---Start client
---@param callback fun(err: avante.acp.ACPError|nil)
function ACPClient:connect(callback)
  callback = callback or function() end

  if self.state ~= "disconnected" then
    callback(nil)
    return
  end

  self.transport:start(vim.schedule_wrap(function(message) self:_handle_message(message) end))

  self:initialize(callback)
end

---Stop client
function ACPClient:stop()
  self.transport:stop()
  self:_close_debug_log()
  self.reconnect_count = 0
end

---Initialize protocol connection
---@param callback fun(err: avante.acp.ACPError|nil)
function ACPClient:initialize(callback)
  callback = callback or function() end

  if self.state ~= "connected" then
    local error = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Cannot initialize: client not connected")
    callback(error)
    return
  end

  self:_set_state("initializing")

  self:_send_request("initialize", {
    protocolVersion = self.protocol_version,
    clientCapabilities = self.capabilities,
  }, function(result, err)
    if err or not result then
      self:_set_state("error")
      vim.schedule(function() vim.notify("Failed to initialize", vim.log.levels.ERROR) end)
      callback(err or self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to initialize: missing result"))
      return
    end

    -- Update protocol version and capabilities
    self.protocol_version = result.protocolVersion
    self.agent_capabilities = result.agentCapabilities
    self.auth_methods = result.authMethods or {}

    -- Normalize capability: sessionCapabilities.resume → loadSession
    -- The ACP protocol reports resume support under sessionCapabilities.resume,
    -- but our code checks agentCapabilities.loadSession throughout.
    if self.agent_capabilities and self.agent_capabilities.sessionCapabilities and self.agent_capabilities.sessionCapabilities.resume then
      self.agent_capabilities.loadSession = true
    end

    -- Parse session modes from agent capabilities
    if result.agentCapabilities and result.agentCapabilities.modes then
      self.session_modes = {
        current_mode_id = result.agentCapabilities.defaultMode or result.agentCapabilities.modes[1].id,
        modes = result.agentCapabilities.modes
      }
    end

    -- Check if we need to authenticate
    local auth_method = self.config.auth_method

    if auth_method then
      Utils.debug("Authenticating with method " .. auth_method)
      self:authenticate(auth_method, function(auth_err)
        if auth_err then
          callback(auth_err)
        else
          self:_set_state("ready")
          callback(nil)
        end
      end)
    else
      Utils.debug("No authentication method found or specified")
      self:_set_state("ready")
      callback(nil)
    end
  end)
end

---Authentication (if required)
---@param method_id string
---@param callback fun(err: avante.acp.ACPError|nil)
function ACPClient:authenticate(method_id, callback)
  callback = callback or function() end

  self:_send_request("authenticate", {
    methodId = method_id,
  }, function(result, err) callback(err) end)
end

---Create new session
---@param cwd string
---@param mcp_servers table[]?
---@param callback fun(session_id: string|nil, err: avante.acp.ACPError|nil)
function ACPClient:create_session(cwd, mcp_servers, callback)
  callback = callback or function() end

  self:_send_request("session/new", {
    cwd = cwd,
    mcpServers = mcp_servers or {},
  }, function(result, err)
    if err then
      vim.schedule(function() vim.notify("Failed to create session: " .. err.message, vim.log.levels.ERROR) end)
      callback(nil, err)
      return
    end
    if not result then
      local error = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to create session: missing result")
      callback(nil, error)
      return
    end
    
    -- Parse session modes from response (Zed-style: modes come from session/new response)
    Utils.debug("session/new response keys: " .. vim.inspect(vim.tbl_keys(result)))
    if result.modes then
      Utils.debug("session/new modes: " .. vim.inspect(result.modes))
    else
      Utils.debug("session/new: no modes in response")
    end
    if result.modes and result.modes.availableModes and #result.modes.availableModes > 0 then
      self.session_modes = {
        current_mode_id = result.modes.currentModeId,
        modes = result.modes.availableModes,
      }
      Utils.debug("Session modes from session/new: " .. #self.session_modes.modes .. " modes available, current: " .. tostring(self.session_modes.current_mode_id))
    end

    -- Parse configOptions (ACP spec: supersedes modes)
    if result.configOptions and #result.configOptions > 0 then
      self.config_options = result.configOptions
      Utils.debug("Config options from session/new: " .. #self.config_options .. " options")
    end

    callback(result.sessionId, nil)
  end)
end

---Load existing session
---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:load_session(session_id, cwd, mcp_servers, callback)
  callback = callback or function() end

  if not self.agent_capabilities or not self.agent_capabilities.loadSession then
    vim.schedule(function() vim.notify("Agent does not support loading sessions", vim.log.levels.WARN) end)
    local err = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Agent does not support loading sessions")
    callback(nil, err)
    return
  end

  self:_send_request("session/load", {
    sessionId = session_id,
    cwd = cwd,
    mcpServers = mcp_servers or {},
  }, function(result, err)
    if result then
      -- Parse session modes from response (same as session/new)
      if result.modes and result.modes.availableModes and #result.modes.availableModes > 0 then
        self.session_modes = {
          current_mode_id = result.modes.currentModeId,
          modes = result.modes.availableModes,
        }
        Utils.debug("Session modes from session/load: " .. #self.session_modes.modes .. " modes available")
      end

      -- Parse configOptions
      if result.configOptions and #result.configOptions > 0 then
        self.config_options = result.configOptions
        Utils.debug("Config options from session/load: " .. #self.config_options .. " options")
      end
    end
    callback(result, err)
  end)
end

---Send prompt
---@param session_id string
---@param prompt table[]
---@param mode_id string|nil Optional mode ID to include with the prompt
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, mode_id, callback)
  -- Handle optional mode_id parameter for backward compatibility
  if type(mode_id) == "function" then
    callback = mode_id
    mode_id = nil
  end
  
  local params = {
    sessionId = session_id,
    prompt = prompt,
  }

  -- Include current mode if available and agent supports modes
  if mode_id and self:has_modes() then
    params.modeId = mode_id
    Utils.debug("Sending prompt with modeId: " .. mode_id)
  end
  
  return self:_send_request("session/prompt", params, callback)
end

---Get current mode ID (Zed-style AgentSessionModes interface)
---@return string|nil
function ACPClient:current_mode()
  if self.session_modes then
    return self.session_modes.current_mode_id
  end
  return nil
end

---Get all available modes (Zed-style AgentSessionModes interface)
---@return avante.acp.SessionMode[]
function ACPClient:all_modes()
  if self.session_modes and self.session_modes.modes then
    return self.session_modes.modes
  end
  return {}
end

---Get mode by ID
---@param mode_id string
---@return avante.acp.SessionMode|nil
function ACPClient:mode_by_id(mode_id)
  if not self.session_modes or not self.session_modes.modes then
    return nil
  end
  for _, mode in ipairs(self.session_modes.modes) do
    if mode.id == mode_id then
      return mode
    end
  end
  return nil
end

---Check if modes are available from agent
---@return boolean
function ACPClient:has_modes()
  return self.session_modes ~= nil and self.session_modes.modes ~= nil and #self.session_modes.modes > 0
end

---Set session mode (Zed-style AgentSessionModes interface)
---@param session_id string
---@param mode_id string
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_mode(session_id, mode_id, callback)
  callback = callback or function() end

  self:_send_request("session/set_mode", {
    sessionId = session_id,
    modeId = mode_id,
  }, callback)
end

---@deprecated Use set_mode instead
---@param session_id string
---@param mode_id string
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_session_mode(session_id, mode_id, callback)
  self:set_mode(session_id, mode_id, callback)
end

---Set a config option value
---@param session_id string
---@param config_id string
---@param value string
---@param callback? fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_config_option(session_id, config_id, value, callback)
  callback = callback or function() end

  self:_send_request("session/set_config_option", {
    sessionId = session_id,
    configId = config_id,
    value = value,
  }, function(result, err)
    if not err and result and result.configOptions then
      self.config_options = result.configOptions
      if self.on_config_options_changed then
        vim.schedule(function() self.on_config_options_changed(self.config_options) end)
      end
    end
    callback(result, err)
  end)
end

---Get all config options
---@return avante.acp.ConfigOption[]
function ACPClient:all_config_options()
  return self.config_options or {}
end

---Check if agent has config options
---@return boolean
function ACPClient:has_config_options()
  return self.config_options ~= nil and #self.config_options > 0
end

---Cancel session
---@param session_id string
function ACPClient:cancel_session(session_id)
  self:_send_notification("session/cancel", {
    sessionId = session_id,
  })
end

---List all sessions
---@param callback fun(sessions: table[]|nil, err: avante.acp.ACPError|nil)
function ACPClient:list_sessions(callback)
  callback = callback or function() end

  self:_send_request("session/list", {}, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if not result then
      local error = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to list sessions: missing result")
      callback(nil, error)
      return
    end
    -- Result should be an array of session objects
    local sessions = result.sessions or result or {}
    callback(sessions, nil)
  end)
end

---Helper function: Create text content block
---@param text string
---@param annotations table?
---@return table
function ACPClient:create_text_content(text, annotations)
  return {
    type = "text",
    text = text,
    annotations = annotations,
  }
end

---Helper function: Create image content block
---@param data string Base64 encoded image data
---@param mime_type string
---@param uri string?
---@param annotations table?
---@return table
function ACPClient:create_image_content(data, mime_type, uri, annotations)
  return {
    type = "image",
    data = data,
    mimeType = mime_type,
    uri = uri,
    annotations = annotations,
  }
end

---Helper function: Create audio content block
---@param data string Base64 encoded audio data
---@param mime_type string
---@param annotations table?
---@return table
function ACPClient:create_audio_content(data, mime_type, annotations)
  return {
    type = "audio",
    data = data,
    mimeType = mime_type,
    annotations = annotations,
  }
end

---Helper function: Create resource link content block
---@param uri string
---@param name string
---@param description string?
---@param mime_type string?
---@param size number?
---@param title string?
---@param annotations table?
---@return table
function ACPClient:create_resource_link_content(uri, name, description, mime_type, size, title, annotations)
  return {
    type = "resource_link",
    uri = uri,
    name = name,
    description = description,
    mimeType = mime_type,
    size = size,
    title = title,
    annotations = annotations,
  }
end

---Helper function: Create embedded resource content block
---@param resource table
---@param annotations table?
---@return table
function ACPClient:create_resource_content(resource, annotations)
  return {
    type = "resource",
    resource = resource,
    annotations = annotations,
  }
end

---Helper function: Create text resource
---@param uri string
---@param text string
---@param mime_type string?
---@return table
function ACPClient:create_text_resource(uri, text, mime_type)
  return {
    uri = uri,
    text = text,
    mimeType = mime_type,
  }
end

---Helper function: Create binary resource
---@param uri string
---@param blob string Base64 encoded binary data
---@param mime_type string?
---@return table
function ACPClient:create_blob_resource(uri, blob, mime_type)
  return {
    uri = uri,
    blob = blob,
    mimeType = mime_type,
  }
end

---Convenience method: Check if client is ready
---@return boolean
function ACPClient:is_ready() return self.state == "ready" end

---Convenience method: Check if client is connected
---@return boolean
function ACPClient:is_connected() return self.state ~= "disconnected" and self.state ~= "error" end

---Convenience method: Get current state
---@return ACPConnectionState
function ACPClient:get_state() return self.state end

---Convenience method: Wait for client to be ready
---@param callback function
---@param timeout number? Timeout in milliseconds
function ACPClient:wait_ready(callback, timeout)
  if self:is_ready() then
    callback(nil)
    return
  end

  local timeout_ms = timeout or 10000 -- 10 seconds default
  local start_time = vim.loop.now()

  local function check_ready()
    if self:is_ready() then
      callback(nil)
    elseif self.state == "error" then
      callback(self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Client entered error state while waiting"))
    elseif vim.loop.now() - start_time > timeout_ms then
      callback(self:_create_error(self.ERROR_CODES.TIMEOUT_ERROR, "Timeout waiting for client to be ready"))
    else
      vim.defer_fn(check_ready, 100) -- Check every 100ms
    end
  end

  check_ready()
end

---Convenience method: Send simple text prompt
---@param session_id string
---@param text string
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:send_text_prompt(session_id, text, callback)
  local prompt = { self:create_text_content(text) }
  self:send_prompt(session_id, prompt, callback)
end

return ACPClient