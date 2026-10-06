---@mod avante-acp Agent Client Protocol support
---
---@brief [[
---
---Avante.nvim now supports the Agent Client Protocol (ACP) (https://agentclientprotocol.com/overview/introduction), enabling seamless integration with AI agents that follow this standardized communication protocol.
---
---What is ACP?
---
---(ACP) is a standardized protocol that enables AI agents to communicate with development tools and environments. It provides:
---
---- **Standardized Communication**: A unified JSON-RPC based protocol for agent-client interactions
---- **Tool Integration**: Support for various development tools like file operations, code execution, and search
---- **Session Management**: Persistent sessions that maintain context across interactions
---- **Permission System**: Granular control over what agents can access and modify
---
--- Supported ACP agents include:
---
--- - Gemini CLI
--- - Claude Code
--- - Goose
--- - Codex
--- - Kimi CLI
---Before using ACP agents, ensure you have the required tools installed:
---
---- **For Gemini CLI**: Install the `gemini` CLI tool and set your `GEMINI_API_KEY`
---- **For Claude Code**: Install the `acp-claude-code` package via npm and set your `ANTHROPIC_API_KEY`
---
---ACP vs Traditional Providers
---
---ACP providers offer several advantages over traditional API-based providers:
---
---- **Enhanced Tool Access**: Agents can directly interact with your file system, run commands, and access development tools
---- **Persistent Context**: Sessions maintain state across multiple interactions
---- **Fine-grained Permissions**: Control exactly what agents can access and modify
---- **Standardized Protocol**: Compatible with any ACP-compliant agent
---@brief ]]
---@see avante-config
local Config = require("avante.config")
local Utils = require("avante.utils")
local Log = require("avante.utils.log")

---@param value any
---@return any
local function without_json_null(value)
  if value == vim.NIL then return nil end
  return value
end

---@param value any
---@return boolean
local function is_json_object(value) return type(value) == "table" and not vim.islist(value) end

---@param info table
---@return string|nil
local function normalize_session_metadata(info)
  local invalid = {}
  for _, field in ipairs({ "title", "updatedAt" }) do
    local value = info[field]
    -- ACP's schema defines updatedAt as string|null, without a narrower date-time format.
    if value ~= nil and value ~= vim.NIL and type(value) ~= "string" then
      info[field] = nil
      table.insert(invalid, field)
    end
  end
  if info._meta == vim.NIL then
    info._meta = nil
  elseif info._meta ~= nil and not is_json_object(info._meta) then
    info._meta = nil
    table.insert(invalid, "_meta")
  end
  return #invalid > 0 and table.concat(invalid, ", ") or nil
end

---@class avante.acp.ClientCapabilities
---@field fs avante.acp.FileSystemCapability
---@field terminal boolean

---@class avante.acp.FileSystemCapability
---@field readTextFile boolean
---@field writeTextFile boolean

---@class avante.acp.AgentCapabilities
---@field loadSession boolean
---@field promptCapabilities avante.acp.PromptCapabilities
---@field mcpCapabilities? avante.acp.McpCapabilities
---@field sessionCapabilities? avante.acp.SessionCapabilities

---@class avante.acp.SessionListCapability

---@class avante.acp.SessionCapability

---@class avante.acp.SessionCapabilities
---@field list? avante.acp.SessionListCapability
---@field delete? avante.acp.SessionCapability
---@field resume? avante.acp.SessionCapability
---@field close? avante.acp.SessionCapability
---@field additionalDirectories? avante.acp.SessionCapability

---@class avante.acp.McpCapabilities
---@field http boolean
---@field sse boolean

---@class avante.acp.SessionInfo
---@field sessionId string
---@field cwd string
---@field title? string
---@field updatedAt? string ISO 8601 timestamp
---@field additionalDirectories? string[] Complete ordered additional workspace roots
---@field _meta? table<string, any>

---@class avante.acp.ListSessionsResult
---@field sessions avante.acp.SessionInfo[]
---@field nextCursor? string
---@field _meta? table<string, any>

---@class avante.acp.LoadSessionOpts
---@field on_replay? fun(update: table): boolean Receives updates replayed while the load is in flight; return true to consume one instead of passing it to the session update handler
---@field additional_directories? string[] Additional absolute workspace roots

---@class avante.acp.PromptCapabilities
---@field image boolean
---@field audio boolean
---@field embeddedContext boolean

---@class avante.acp.AuthMethod
---@field id string
---@field name string
---@field description string|nil
---@field type? "agent" | "terminal" | string

---@class avante.acp.McpServer
---@field type? "stdio" | "http" | "sse"
---@field name string
---@field command? string
---@field args? string[]
---@field env? avante.acp.EnvVariable[]
---@field url? string
---@field headers? avante.acp.EnvVariable[]

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
---@field status ACPPlanEntryStatus

---@class avante.acp.Plan
---@field entries avante.acp.PlanEntry[]

---@class avante.acp.ConfigOptionValue
---@field value string
---@field name string
---@field description string|nil

---@class avante.acp.ConfigOption
---@field id string
---@field name string
---@field description string|nil
---@field category string|nil
---@field type string
---@field currentValue string
---@field options avante.acp.ConfigOptionValue[]

---@class avante.acp.ConfigOptionUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "config_option_update"
---@field configOptions avante.acp.ConfigOption[]

---@class avante.acp.AvailableCommand
---@field name string
---@field description string
---@field input? table<string, any>

---@class avante.acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan" | "available_commands_update" | "config_option_update" | "current_mode_update" | "session_info_update"
---@field _replayed? boolean Set by ACPClient when the update was replayed during a session/load request

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

---@class avante.acp.SessionInfoUpdate : avante.acp.BaseSessionUpdate
---@field sessionUpdate "session_info_update"
---@field title? string|vim.NIL
---@field updatedAt? string|vim.NIL
---@field _meta? table<string, any>|vim.NIL

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
---@field config_options avante.acp.ConfigOption[]|nil
---@field _legacy_api boolean|nil Whether agent uses old modes/models API instead of configOptions
---@field config ACPConfig
---@field callbacks table<number, fun(result: table|nil, err: avante.acp.ACPError|nil)>
---@field session_replay_handlers table<string, fun(update: table): boolean> Replay handlers keyed by session id, set while a session/load is in flight
---@field active_session_ids table<string, boolean> Sessions successfully created, loaded, or resumed on this connection
---@field stop_callbacks fun(err: avante.acp.ACPError|nil)[]
---@field debug_log_file file*|nil
---@field is_loading_session boolean Whether a session/load request is in flight
---@field stop_requested boolean Whether an intentional shutdown has disabled reconnects
---@field is_stopping boolean Whether graceful shutdown is waiting for session/close
local ACPClient = {}

-- ACP Error codes
ACPClient.ERROR_CODES = {
  -- JSON-RPC 2.0
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603,
  PROTOCOL_ERROR = -32600,
  -- ACP
  AUTH_REQUIRED = -32000,
  RESOURCE_NOT_FOUND = -32002,
}

local LOG_SEPARATOR = string.rep("=", 80) .. "\n"

---@class ACPHandlers
---@field on_session_update? fun(update: avante.acp.UserMessageChunk | avante.acp.AgentMessageChunk | avante.acp.AgentThoughtChunk | avante.acp.ToolCallUpdate | avante.acp.PlanUpdate | avante.acp.AvailableCommandsUpdate | avante.acp.SessionInfoUpdate, session_id: string)
---@field on_request_permission? fun(tool_call: table, options: table[], callback: fun(option_id: string | nil)): nil
---@field on_read_file? fun(path: string, line: integer | nil, limit: integer | nil, callback: fun(content: string), error_callback: fun(message: string, code: integer|nil)): nil
---@field on_write_file? fun(path: string, content: string, callback: fun(error: string|nil)): nil
---@field on_error? fun(error: table)

---@class ACPConfig
---@field transport_type "stdio" | "websocket" | "tcp"
---@field command? string Command to spawn agent (for stdio)
---@field args string[] Arguments for agent command
---@field env? table Environment variables
---@field host? string Host for tcp/websocket
---@field port? number Port for tcp/websocket
---@field timeout? number Request timeout in milliseconds
---@field reconnect? boolean Enable auto-reconnect
---@field max_reconnect_attempts? number Maximum reconnection attempts
---@field heartbeat_interval? number Heartbeat interval in milliseconds
---@field session_close_timeout? number Maximum time to wait for session/close responses in milliseconds
---@field auth_method? string Authentication method
---@field mcp_servers? table[] MCP servers from the provider config, passed to new, loaded, and resumed sessions
---@field additional_directories? string[] Additional absolute workspace roots for sessions
---@field handlers? ACPHandlers
---@field on_state_change? fun(new_state: ACPConnectionState, old_state: ACPConnectionState)

---Create a new ACP client instance
---@param config ACPConfig
---@return avante.acp.ACPClient
function ACPClient:new(config)
  config = config or {}
  local handlers = config.handlers or {}
  local client = setmetatable({
    id_counter = -1,
    protocol_version = 1,
    capabilities = {
      terminal = false,
      -- Advertise only methods this client can actually serve.
      fs = {
        readTextFile = type(handlers.on_read_file) == "function",
        writeTextFile = type(handlers.on_write_file) == "function",
      },
    },
    debug_log_file = nil,
    callbacks = {},
    session_replay_handlers = {},
    active_session_ids = {},
    stop_callbacks = {},
    transport = nil,
    config = config,
    config_options = nil,
    state = "disconnected",
    reconnect_count = 0,
    heartbeat_timer = nil,
    is_loading_session = false,
    stop_requested = false,
    is_stopping = false,
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
  if not self.debug_log_file then
    self.debug_log_file = io.open(vim.fs.joinpath(vim.fn.stdpath("log"), "avante-acp-session.log"), "a")
  end

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
    --- @type uv.uv_pipe_t|nil
    stderr = nil,
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

    local args = vim.deepcopy(self.config.args)
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

      if self.is_stopping then
        self:_complete_stop(nil)
        return
      end
      self.active_session_ids = {}
      transport_self:stop()

      -- Handle auto-reconnect
      if
        not self.stop_requested
        and self.config.reconnect
        and self.reconnect_count < (self.config.max_reconnect_attempts or 3)
      then
        self.reconnect_count = self.reconnect_count + 1
        vim.defer_fn(function()
          if self.state == "disconnected" then self:connect(function(_err) end) end
        end, 2000) -- Wait 2 seconds before reconnecting
      end
    end)

    Utils.debug("Spawned ACP agent process with PID " .. tostring(pid))

    if not handle then
      self:_set_state("error")
      error("Failed to spawn ACP agent process [" .. table.concat({ self.config.command, unpack(args) }, " ") .. "]")
    end

    transport_self.process = handle
    transport_self.stdin = stdin
    transport_self.stdout = stdout
    transport_self.stderr = stderr

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
    if transport_self.stderr then
      transport_self.stderr:close()
      transport_self.stderr = nil
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
  if self.is_stopping and method ~= "session/close" then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "ACP client is stopping"))
    return
  end
  local id = self:_next_id()
  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }

  self.callbacks[id] = callback

  local data = vim.json.encode(message)
  self:_debug_log("request: " .. data .. "\n" .. LOG_SEPARATOR)
  if self.transport:send(data) == false then
    self.callbacks[id] = nil
    callback(nil, self:_create_error(self.ERROR_CODES.INTERNAL_ERROR, "ACP transport is not writable"))
  end
end

---Send JSON-RPC notification
---@param method string
---@param params table?
function ACPClient:_send_notification(method, params)
  if self.is_stopping then return end
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
  if message.method and message.result == nil and message.error == nil then
    -- This is a notification
    self:_handle_notification(message.id, message.method, message.params)
  elseif message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
    self:_debug_log("response: " .. vim.inspect(message) .. "\n" .. string.rep("=", 100) .. "\n")
    local callback = self.callbacks[message.id]
    if callback then
      self.callbacks[message.id] = nil
      callback(message.result, message.error)
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
  elseif method == "_auth/status_update" then
    Log.debug("ACP auth identity:", params.authStatus)
  else
    vim.notify("Unknown notification method: " .. method, vim.log.levels.WARN)
  end
end

---Handle session update notification
---@param params table
function ACPClient:_handle_session_update(params)
  local session_id = params.sessionId
  local update = params.update

  if type(session_id) ~= "string" then
    vim.notify("Received session/update without a string sessionId", vim.log.levels.WARN)
    return
  end

  if not is_json_object(update) then
    vim.notify("Received session/update without update data", vim.log.levels.WARN)
    return
  end

  if update.sessionUpdate == "session_info_update" then
    local invalid = normalize_session_metadata(update)
    if invalid then
      vim.schedule(
        function() vim.notify("Ignored invalid session_info_update fields: " .. invalid, vim.log.levels.WARN) end
      )
    end
  end

  if update.sessionUpdate == "config_option_update" and update.configOptions then
    self.config_options = update.configOptions
  end

  -- Handle legacy current_mode_update notification
  if update.sessionUpdate == "current_mode_update" and update.modeId then
    if self.config_options then
      for _, opt in ipairs(self.config_options) do
        if opt.id == "mode" and opt.category == "mode" then
          opt.currentValue = update.modeId
          break
        end
      end
    end
  end

  -- Agents replay the loaded conversation as session/update notifications
  -- while a session/load request is in flight. Stamp those updates here, at
  -- read time — the session/load response only arrives (and clears the flag)
  -- after all replay notifications have been read.
  if self.is_loading_session then update._replayed = true end

  -- An import collects the replay instead. Called synchronously: the session/load response
  -- callback runs inline once the replay is done, so a scheduled call would come too late.
  local replay_handler = self.session_replay_handlers[session_id]
  if replay_handler and replay_handler(update) then return end

  if self.config.handlers and self.config.handlers.on_session_update then
    vim.schedule(function() self.config.handlers.on_session_update(update, session_id) end)
  end
end

---Handle permission request notification
---@param message_id number
---@param params table
function ACPClient:_handle_request_permission(message_id, params)
  local session_id = params.sessionId
  local tool_call = params.toolCall
  local options = params.options

  if not session_id or not tool_call then return end

  if self.config.handlers and self.config.handlers.on_request_permission then
    vim.schedule(function()
      self.config.handlers.on_request_permission(
        tool_call,
        options,
        function(option_id)
          self:_send_result(message_id, {
            outcome = {
              outcome = "selected",
              optionId = option_id,
            },
          })
        end
      )
    end)
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
      self.config.handlers.on_write_file(path, content, function(error)
        if error then
          self:_send_error(message_id, error)
        else
          -- WriteTextFileResponse is an empty object.
          self:_send_result(message_id, vim.empty_dict())
        end
      end)
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

  self.stop_requested = false
  self.transport:start(vim.schedule_wrap(function(message) self:_handle_message(message) end))

  self:initialize(callback)
end

---@param err avante.acp.ACPError|nil
function ACPClient:_complete_stop(err)
  if not self.is_stopping then return end
  local pending = self.callbacks
  self.is_stopping = false
  self.active_session_ids = {}
  self.session_replay_handlers = {}
  self.callbacks = {}
  self.is_loading_session = false
  self.transport:stop()
  self:_close_debug_log()
  self.reconnect_count = 0

  local request_err = err or self:_create_error(self.ERROR_CODES.INTERNAL_ERROR, "ACP client stopped")
  for _, callback in pairs(pending) do
    pcall(callback, nil, request_err)
  end

  local callbacks = self.stop_callbacks
  self.stop_callbacks = {}
  for _, callback in ipairs(callbacks) do
    pcall(callback, err)
  end
end

---Stop the client after closing every active session advertised by this connection.
---@param callback? fun(err: avante.acp.ACPError|nil)
function ACPClient:stop(callback)
  if callback then table.insert(self.stop_callbacks, callback) end
  if self.is_stopping then return end

  self.stop_requested = true
  self.is_stopping = true
  if self.state == "disconnected" then
    self:_complete_stop(nil)
    return
  end

  local session_ids = vim.tbl_keys(self.active_session_ids)
  if self.state ~= "ready" or #session_ids == 0 or not self:_supports_session_capability("close") then
    self:_complete_stop(nil)
    return
  end

  local remaining = #session_ids
  local first_error ---@type avante.acp.ACPError|nil
  for _, session_id in ipairs(session_ids) do
    self:close_session(session_id, function(err)
      if not self.is_stopping then return end
      first_error = first_error or err
      remaining = remaining - 1
      if remaining == 0 then self:_complete_stop(first_error) end
    end)
  end

  if self.is_stopping then
    vim.defer_fn(function()
      if not self.is_stopping then return end
      self:_complete_stop(self:_create_error(self.ERROR_CODES.INTERNAL_ERROR, "Timed out waiting for session/close"))
    end, self.config.session_close_timeout or 500)
  end
end

---Immediately stop the transport, bypassing graceful session closure.
function ACPClient:force_stop()
  self.stop_requested = true
  if not self.is_stopping then self.is_stopping = true end
  self:_complete_stop(nil)
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
    clientInfo = { name = "avante.nvim", title = "Avante.nvim", version = "unknown" },
  }, function(result, err)
    if err or not result then
      self:_set_state("error")
      vim.schedule(function() vim.notify("Failed to initialize", vim.log.levels.ERROR) end)
      callback(err or self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to initialize: missing result"))
      return
    end
    -- Both peers must agree on a version before any session is created.
    if result.protocolVersion ~= self.protocol_version then
      self:_set_state("error")
      self.transport:stop()
      callback(self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Agent returned an unsupported protocol version"))
      return
    end
    self.protocol_version = result.protocolVersion
    -- These response fields default to empty values when omitted.
    self.agent_capabilities = result.agentCapabilities or {}
    self.auth_methods = result.authMethods or {}

    -- Check if we need to authenticate
    local auth_method = self.config.auth_method

    if auth_method then
      local selected = vim.iter(self.auth_methods):find(function(method) return method.id == auth_method end)
      -- A missing type means "agent"; only this type uses authenticate.
      if not selected or (selected.type or "agent") ~= "agent" then
        self:_set_state("error")
        callback(self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Unsupported ACP authentication method"))
        return
      end

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
  }, function(_result, err) callback(err) end)
end

---@param capability string
---@return boolean
function ACPClient:_supports_session_capability(capability)
  -- ACP advertises optional session methods with JSON object markers; null or arrays mean unsupported.
  if not is_json_object(self.agent_capabilities) then return false end
  local session_capabilities = without_json_null(self.agent_capabilities.sessionCapabilities)
  return is_json_object(session_capabilities) and is_json_object(without_json_null(session_capabilities[capability]))
end

---@param values any
---@param label string
---@param absolute boolean?
---@return string|nil
local function validate_string_array(values, label, absolute)
  if type(values) ~= "table" or not vim.islist(values) then return label .. " must be an array" end
  for i, value in ipairs(values) do
    if type(value) ~= "string" then return string.format("%s[%d] must be a string", label, i) end
    if absolute and (value == "" or vim.fn.isabsolutepath(value) ~= 1) then
      return string.format("%s[%d] must be an absolute path", label, i)
    end
  end
  return nil
end

---@param values any
---@param label string
---@return string|nil
local function validate_name_value_array(values, label)
  if type(values) ~= "table" or not vim.islist(values) then return label .. " must be an array" end
  for i, value in ipairs(values) do
    if not is_json_object(value) or type(value.name) ~= "string" or type(value.value) ~= "string" then
      return string.format("%s[%d] must contain string name and value fields", label, i)
    end
  end
  return nil
end

---@param client avante.acp.ACPClient
---@param servers any
---@return string|nil
---@return integer|nil
local function validate_mcp_servers(client, servers)
  if type(servers) ~= "table" or not vim.islist(servers) then return "MCP servers must be an array" end

  local capabilities = is_json_object(client.agent_capabilities)
      and without_json_null(client.agent_capabilities.mcpCapabilities)
    or nil
  for i, server in ipairs(servers) do
    local label = string.format("MCP server %d", i)
    if not is_json_object(server) then return label .. " must be an object" end
    if type(server.name) ~= "string" then return label .. ".name must be a string" end

    local transport = server.type
    -- Stdio is the required default transport; HTTP and SSE require explicit agent capabilities.
    if transport == nil then transport = "stdio" end
    if transport == "stdio" then
      if type(server.command) ~= "string" or server.command == "" or vim.fn.isabsolutepath(server.command) ~= 1 then
        return label .. ".command must be an absolute path"
      end
      local err = validate_string_array(server.args, label .. ".args")
        or validate_name_value_array(server.env, label .. ".env")
      if err then return err end
    elseif transport == "http" or transport == "sse" then
      if type(server.url) ~= "string" then return label .. ".url must be a string" end
      local err = validate_name_value_array(server.headers, label .. ".headers")
      if err then return err end
      if not is_json_object(capabilities) or capabilities[transport] ~= true then
        return "Agent does not support the " .. transport .. " MCP transport", ACPClient.ERROR_CODES.INVALID_REQUEST
      end
    else
      return label .. ".type is not a supported MCP transport"
    end
  end

  return nil
end

---@param cwd string
---@param mcp_servers table[]?
---@param session_id string?
---@param additional_directories string[]?
---@return table|nil params
---@return avante.acp.ACPError|nil err
function ACPClient:_session_setup_params(cwd, mcp_servers, session_id, additional_directories)
  -- ACP forbids session setup before initialization and requires an absolute primary working directory.
  if self.state ~= "ready" then
    return nil, self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Cannot set up session before initialization")
  end
  if self.is_stopping then
    return nil, self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Cannot set up session while stopping")
  end
  if type(cwd) ~= "string" or cwd == "" or vim.fn.isabsolutepath(cwd) ~= 1 then
    return nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session cwd must be an absolute path")
  end
  if session_id ~= nil and (type(session_id) ~= "string" or session_id == "") then
    return nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session ID must be a non-empty string")
  end

  local servers = mcp_servers
  -- Session setup always carries mcpServers, including an empty JSON array when none are configured.
  if servers == nil then servers = {} end
  local mcp_err, mcp_err_code = validate_mcp_servers(self, servers)
  if mcp_err then return nil, self:_create_error(mcp_err_code or self.ERROR_CODES.INVALID_PARAMS, mcp_err) end

  local params = { cwd = cwd, mcpServers = servers }
  if session_id then params.sessionId = session_id end

  local directories = additional_directories
  if directories == nil then directories = self.config.additional_directories end
  if directories ~= nil then
    local directories_err = validate_string_array(directories, "Additional session directories", true)
    if directories_err then return nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, directories_err) end
  end
  if directories and #directories > 0 then
    -- Clients may only widen the effective root set when the agent advertises this capability.
    if not self:_supports_session_capability("additionalDirectories") then
      return nil,
        self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Agent does not support additional session directories")
    end
    params.additionalDirectories = directories
  end

  return params, nil
end

---Create new session
---@param cwd string
---@param mcp_servers table[]?
---@param callback fun(session_id: string|nil, err: avante.acp.ACPError|nil)
---@param additional_directories? string[]
function ACPClient:create_session(cwd, mcp_servers, callback, additional_directories)
  callback = callback or function() end

  local params, params_err = self:_session_setup_params(cwd, mcp_servers, nil, additional_directories)
  if params_err then
    callback(nil, params_err)
    return
  end

  self:_send_request("session/new", params, function(result, err)
    if err then
      vim.schedule(function() vim.notify("Failed to create session: " .. err.message, vim.log.levels.ERROR) end)
      callback(nil, err)
      return
    end
    -- session/new must return a usable session ID before any session-scoped request can be sent.
    if result == nil or not is_json_object(result) then
      local error = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to create session: invalid sessionId")
      callback(nil, error)
      return
    end
    local session_id = result.sessionId
    if type(session_id) ~= "string" or session_id == "" then
      local error = self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to create session: invalid sessionId")
      callback(nil, error)
      return
    end
    self.active_session_ids[session_id] = true
    self:_convert_legacy_session_fields(result)
    callback(session_id, nil)
  end)
end

---Load existing session
---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
---@param opts? avante.acp.LoadSessionOpts
function ACPClient:load_session(session_id, cwd, mcp_servers, callback, opts)
  callback = callback or function() end

  local additional_directories = opts and opts.additional_directories
  local params, params_err = self:_session_setup_params(cwd, mcp_servers, session_id, additional_directories)
  if params_err then
    callback(nil, params_err)
    return
  end

  -- Clients MUST NOT call session/load unless loadSession is explicitly true.
  if not is_json_object(self.agent_capabilities) or self.agent_capabilities.loadSession ~= true then
    vim.schedule(function() vim.notify("Agent does not support loading sessions", vim.log.levels.WARN) end)
    local err = self:_create_error(self.ERROR_CODES.METHOD_NOT_FOUND, "Agent does not support loading sessions")
    callback(nil, err)
    return
  end

  -- Updates received before the response are the required history replay for session/load.
  self.is_loading_session = true
  if opts and opts.on_replay then self.session_replay_handlers[session_id] = opts.on_replay end

  self:_send_request("session/load", params, function(result, err)
    self.is_loading_session = false
    self.session_replay_handlers[session_id] = nil
    if err then
      callback(nil, err)
      return
    end
    if result == nil or not is_json_object(result) then
      callback(nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to load session: missing result"))
      return
    end
    self.active_session_ids[session_id] = true
    self:_convert_legacy_session_fields(result)
    callback(result, nil)
  end)
end

---Resume an existing session without replaying its conversation history
---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
---@param additional_directories? string[]
function ACPClient:resume_session(session_id, cwd, mcp_servers, callback, additional_directories)
  callback = callback or function() end
  local params, params_err = self:_session_setup_params(cwd, mcp_servers, session_id, additional_directories)
  if params_err then
    callback(nil, params_err)
    return
  end
  -- session/resume is optional and, unlike session/load, must not enter replay mode.
  if not self:_supports_session_capability("resume") then
    callback(nil, self:_create_error(self.ERROR_CODES.METHOD_NOT_FOUND, "Agent does not support resuming sessions"))
    return
  end

  self:_send_request("session/resume", params, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if result == nil or not is_json_object(result) then
      callback(nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to resume session: missing result"))
      return
    end
    self.active_session_ids[session_id] = true
    self:_convert_legacy_session_fields(result)
    callback(result, nil)
  end)
end

---Close an active session
---@param session_id string
---@param callback? fun(err: avante.acp.ACPError|nil)
function ACPClient:close_session(session_id, callback)
  callback = callback or function() end
  if self.state ~= "ready" then
    callback(self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Cannot close session before initialization"))
    return
  end
  -- session/close is optional and must be capability-gated before sending.
  if not self:_supports_session_capability("close") then
    callback(self:_create_error(self.ERROR_CODES.METHOD_NOT_FOUND, "Agent does not support closing sessions"))
    return
  end
  if type(session_id) ~= "string" or session_id == "" then
    callback(self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session ID must be a non-empty string"))
    return
  end

  self:_send_request("session/close", { sessionId = session_id }, function(result, err)
    if err then
      callback(err)
      return
    end
    if not is_json_object(result) then
      callback(self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to close session: missing result"))
      return
    end
    self.active_session_ids[session_id] = nil
    callback(nil)
  end)
end

---Delete a session from the agent's session history
---@param session_id string
---@param callback? fun(result: table|nil, err: avante.acp.ACPError|nil)
---@param meta? table<string, any>|vim.NIL Request metadata; use vim.empty_dict() for an empty object
function ACPClient:delete_session(session_id, callback, meta)
  callback = callback or function() end
  if self.state ~= "ready" or self.is_stopping then
    callback(
      nil,
      self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Cannot delete sessions while the client is not ready")
    )
    return
  end
  if not self:_supports_session_capability("delete") then
    callback(nil, self:_create_error(self.ERROR_CODES.METHOD_NOT_FOUND, "Agent does not support deleting sessions"))
    return
  end
  if type(session_id) ~= "string" then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session ID must be a string"))
    return
  end
  meta = without_json_null(meta)
  if meta ~= nil and not is_json_object(meta) then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session delete _meta must be an object"))
    return
  end

  local params = { sessionId = session_id }
  if meta ~= nil then params._meta = meta end
  self:_send_request("session/delete", params, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if not is_json_object(result) then
      callback(
        nil,
        self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Invalid session/delete response: expected an object")
      )
      return
    end
    ---@cast result table
    local response = vim.empty_dict()
    local response_meta = without_json_null(result._meta)
    if is_json_object(response_meta) then response._meta = response_meta end
    callback(response, nil)
  end)
end

---Whether the agent supports session/list
---@return boolean
function ACPClient:supports_list_sessions() return self:_supports_session_capability("list") end

---List one page of the agent's sessions, optionally filtered by working directory
---@param cwd string|vim.NIL|nil
---@param cursor string|vim.NIL|nil
---@param callback fun(result: avante.acp.ListSessionsResult|nil, err: avante.acp.ACPError|nil)
---@param meta? table<string, any>|vim.NIL Request metadata; use vim.empty_dict() for an empty object
function ACPClient:list_sessions(cwd, cursor, callback, meta)
  if self.state ~= "ready" or self.is_stopping then
    callback(
      nil,
      self:_create_error(self.ERROR_CODES.INVALID_REQUEST, "Cannot list sessions while the client is not ready")
    )
    return
  end
  if not self:supports_list_sessions() then
    callback(nil, self:_create_error(self.ERROR_CODES.METHOD_NOT_FOUND, "Agent does not support listing sessions"))
    return
  end

  cwd = without_json_null(cwd)
  cursor = without_json_null(cursor)
  meta = without_json_null(meta)
  if cwd ~= nil and (type(cwd) ~= "string" or vim.fn.isabsolutepath(cwd) ~= 1) then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session cwd must be an absolute path"))
    return
  end
  if cursor ~= nil and type(cursor) ~= "string" then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session cursor must be a string"))
    return
  end
  if meta ~= nil and not is_json_object(meta) then
    callback(nil, self:_create_error(self.ERROR_CODES.INVALID_PARAMS, "Session list _meta must be an object"))
    return
  end

  local params = vim.empty_dict()
  params.cwd = cwd
  params.cursor = cursor
  params._meta = meta

  self:_send_request("session/list", params, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if not is_json_object(result) then
      callback(nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Invalid session/list response"))
      return
    end
    ---@cast result table
    local supports_additional_directories = self:_supports_session_capability("additionalDirectories")
    local sessions = {}
    for _, session in ipairs(vim.islist(result.sessions) and result.sessions or {}) do
      if
        is_json_object(session)
        and type(session.sessionId) == "string"
        and type(session.cwd) == "string"
        and vim.fn.isabsolutepath(session.cwd) == 1
      then
        local normalized = { sessionId = session.sessionId, cwd = session.cwd }
        for _, field in ipairs({ "title", "updatedAt" }) do
          if type(session[field]) == "string" then normalized[field] = session[field] end
        end
        if supports_additional_directories and vim.islist(session.additionalDirectories) then
          normalized.additionalDirectories = {}
          for _, directory in ipairs(session.additionalDirectories) do
            if type(directory) == "string" and vim.fn.isabsolutepath(directory) == 1 then
              table.insert(normalized.additionalDirectories, directory)
            end
          end
        end
        local session_meta = without_json_null(session._meta)
        if is_json_object(session_meta) then normalized._meta = session_meta end
        table.insert(sessions, normalized)
      end
    end
    local response = { sessions = sessions }
    if type(result.nextCursor) == "string" then response.nextCursor = result.nextCursor end
    local response_meta = without_json_null(result._meta)
    if is_json_object(response_meta) then response._meta = response_meta end
    callback(response, nil)
  end)
end

local MAX_SESSION_LIST_PAGES = 50

---List all of the agent's sessions for a working directory, following pagination
---@param cwd string|vim.NIL|nil
---@param callback fun(sessions: avante.acp.SessionInfo[], err: avante.acp.ACPError|nil)
---@param meta? table<string, any>|vim.NIL Request metadata sent on every page
function ACPClient:list_all_sessions(cwd, callback, meta)
  local all_sessions = {}
  local seen_cursors = {}
  local pages = 0

  local function fetch(cursor)
    pages = pages + 1
    self:list_sessions(cwd, cursor, function(result, err)
      if err or not result then
        callback(all_sessions, err)
        return
      end
      vim.list_extend(all_sessions, result.sessions)

      local next_cursor = result.nextCursor
      if not next_cursor then
        callback(all_sessions, nil)
        return
      end
      if seen_cursors[next_cursor] or pages >= MAX_SESSION_LIST_PAGES then
        local reason = seen_cursors[next_cursor] and "the agent repeated a cursor"
          or ("stopped after " .. MAX_SESSION_LIST_PAGES .. " pages")
        callback(
          all_sessions,
          self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Session list incomplete: " .. reason)
        )
        return
      end
      seen_cursors[next_cursor] = true
      fetch(next_cursor)
    end, meta)
  end

  fetch(nil)
end

---Set a session config option (model, mode, etc.)
---@param session_id string
---@param config_id string
---@param value string
---@param callback fun(config_options: avante.acp.ConfigOption[]|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_config_option(session_id, config_id, value, callback)
  callback = callback or function() end

  self:_send_request("session/set_config_option", {
    sessionId = session_id,
    configId = config_id,
    value = value,
  }, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if result and result.configOptions then self.config_options = result.configOptions end
    callback(self.config_options, nil)
  end)
end

---Set session mode via legacy session/set_mode API
---@param session_id string
---@param mode_id string
---@param callback fun(config_options: avante.acp.ConfigOption[]|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_mode(session_id, mode_id, callback)
  callback = callback or function() end

  self:_send_request("session/set_mode", {
    sessionId = session_id,
    modeId = mode_id,
  }, function(_result, err)
    if err then
      callback(nil, err)
      return
    end
    -- Update the synthetic mode config option's currentValue locally
    if self.config_options then
      for _, opt in ipairs(self.config_options) do
        if opt.id == "mode" and opt.category == "mode" then
          opt.currentValue = mode_id
          break
        end
      end
    end
    callback(self.config_options, nil)
  end)
end

---Set session model via non-standard session/set_model API.
---Some agents (e.g. OpenCode) support this even without configOptions.
---Agents that don't support it will return -32601 (Method not found).
---@param session_id string
---@param model_id string
---@param callback fun(config_options: avante.acp.ConfigOption[]|nil, err: avante.acp.ACPError|nil)
function ACPClient:set_model(session_id, model_id, callback)
  callback = callback or function() end

  self:_send_request("session/set_model", {
    sessionId = session_id,
    modelId = model_id,
  }, function(_result, err)
    if err then
      callback(nil, err)
      return
    end
    -- Update the synthetic model config option's currentValue locally
    if self.config_options then
      for _, opt in ipairs(self.config_options) do
        if opt.id == "model" and opt.category == "model" then
          opt.currentValue = model_id
          break
        end
      end
    end
    callback(self.config_options, nil)
  end)
end

---Convert legacy session fields (modes/models) to synthetic config_options.
---If result.configOptions exists, use it directly and clear _legacy_api flag.
---Otherwise, build synthetic ConfigOption[] from result.modes and result.models.
---@param result table The session/new, session/load, or session/resume result
function ACPClient:_convert_legacy_session_fields(result)
  if result.configOptions and result.configOptions ~= vim.NIL then
    self.config_options = result.configOptions
    self._legacy_api = false
    return
  end

  local config_options = {}

  -- Convert legacy modes field
  if type(result.modes) == "table" and result.modes.availableModes then
    local options = {}
    for _, m in ipairs(result.modes.availableModes) do
      table.insert(options, {
        value = m.id,
        name = m.name or m.id,
        description = m.description,
      })
    end
    table.insert(config_options, {
      id = "mode",
      name = "Mode",
      category = "mode",
      type = "select",
      currentValue = result.modes.currentModeId or "",
      options = options,
    })
  end

  -- Convert legacy models field
  if type(result.models) == "table" and result.models.availableModels then
    local options = {}
    for _, m in ipairs(result.models.availableModels) do
      table.insert(options, {
        value = m.modelId,
        name = m.name or m.modelId,
        description = m.description,
      })
    end
    table.insert(config_options, {
      id = "model",
      name = "Model",
      category = "model",
      type = "select",
      currentValue = result.models.currentModelId or "",
      options = options,
    })
  end

  if #config_options > 0 then
    self.config_options = config_options
    self._legacy_api = true
  else
    self.config_options = nil
    self._legacy_api = false
  end
end

---Send prompt
---@param session_id string
---@param prompt table[]
---@param callback fun(result: table|nil, err: avante.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
  local params = {
    sessionId = session_id,
    prompt = prompt,
  }
  return self:_send_request("session/prompt", params, callback)
end

---Cancel session
---@param session_id string
function ACPClient:cancel_session(session_id)
  self:_send_notification("session/cancel", {
    sessionId = session_id,
  })
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
function ACPClient:is_ready() return self.state == "ready" and not self.is_stopping end

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
