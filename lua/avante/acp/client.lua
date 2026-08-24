---Drop-in replacement for `avante.libs.acp_client`, backed by the Python bridge.
---
---It deliberately mirrors the old ACPClient interface so `sidebar.lua` and
---`llm.lua` keep working unchanged: the session-update payloads the bridge
---emits are the same ACP wire shapes the Lua client used to receive, because
---the bridge serialises them with the protocol's own field names.
---
---What differs is everything underneath: terminals, resume, MCP forwarding and
---capability gating are handled by the bridge, and one bridge process serves
---every sidebar rather than one agent process per sidebar.

local Utils = require("avante.utils")
local Config = require("avante.config")
local ACPBridge = require("avante.acp.bridge")

local M = {}

M.ERROR_CODES = ACPBridge.ERROR_CODES

---Adapters by agentId, so bridge callbacks reach the right sidebar.
---@type table<string, avante.acp.BridgeClient>
local registry = {}

---@class avante.acp.BridgeClient
---@field config table
---@field agent_id string|nil
---@field agent_capabilities table|nil
---@field session_modes table|nil
---@field config_options table[]|nil
---@field on_mode_changed fun(mode_id: string)|nil
---@field on_config_options_changed fun(options: table[])|nil
local Client = {}
Client.__index = Client

--------------------------------------------------------------------------------
-- Bridge-wide handlers, installed once and routed by agentId
--------------------------------------------------------------------------------

local function install_handlers(bridge)
  -- Tracked on the bridge, not module-level: ACPBridge.reset() replaces the
  -- bridge, and a global flag would leave the new one with no handlers, which
  -- silently drops every session update.
  if bridge._avante_handlers_installed then return end
  bridge._avante_handlers_installed = true

  bridge:on("ui/permission", function(params, reply)
    local client = registry[params.agentId]
    local handlers = client and client.config and client.config.handlers
    if not (handlers and handlers.on_request_permission) then
      -- Cancelling keeps the agent moving; silence would block it forever.
      Utils.debug("No permission handler for " .. tostring(params.agentId) .. "; cancelling")
      reply({})
      return
    end

    local answered = false
    handlers.on_request_permission(params.toolCall, params.options or {}, function(option_id, result_data)
      if answered then return end
      answered = true
      local result = { optionId = option_id }
      if result_data then result = vim.tbl_deep_extend("force", result, result_data) end
      reply(result)
    end)
  end)

  bridge:on("ui/elicitation", function(params, reply)
    local client = registry[params.agentId]
    local handlers = client and client.config and client.config.handlers
    if not (handlers and handlers.on_elicitation) then
      reply({ action = "cancel" })
      return
    end
    handlers.on_elicitation(params, function(answer) reply(answer or { action = "cancel" }) end)
  end)

  bridge:on("ui/ext", function(params, reply)
    local client = registry[params.agentId]
    local handlers = client and client.config and client.config.handlers
    if handlers and handlers.on_ext_method then
      handlers.on_ext_method(params.method, params.params or {}, function(result) reply(result or {}) end)
      return
    end
    reply(nil, {
      code = ACPBridge.ERROR_CODES.METHOD_NOT_FOUND,
      message = "Unsupported extension method: " .. tostring(params.method),
    })
  end)

  bridge:on_event(function(event)
    local client = registry[event.agentId]
    if not client then return end
    client:_handle_event(event)
  end)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

---@param config table same shape as the Lua ACPClient config
---@return avante.acp.BridgeClient
function M.new(config)
  return setmetatable({
    config = config or {},
    agent_id = nil,
    agent_capabilities = nil,
    session_modes = nil,
    config_options = nil,
    state = "disconnected",
    _bridge = ACPBridge.get(),
  }, Client)
end

--- Colon-call form, for parity with `ACPClient:new(...)`.
--- Defined via a distinct name because `function M:new` would replace M.new
--- itself and recurse forever.
M.new_from_self = function(_self, config) return M.new(config) end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---@param callback fun(err: table|nil)
function Client:connect(callback)
  callback = callback or function() end

  local bridge = self._bridge
  install_handlers(bridge)

  self.state = "connecting"
  bridge:start(function(start_err)
    if start_err then
      self.state = "error"
      callback(start_err)
      return
    end

    bridge:spawn_agent({
      provider = self.config.provider or Config.provider or "claude",
      command = self.config.command,
      args = self.config.args,
      env = self.config.env,
      cwd = self.config.cwd or Utils.root.get(),
      autoApprove = Config.behaviour and Config.behaviour.auto_approve_tool_permissions or false,
    }, function(result, err)
      if err then
        self.state = "error"
        callback(err)
        return
      end

      self.agent_id = result.agentId
      self.agent_capabilities = result.capabilities or {}
      self.auth_methods = result.authMethods or {}
      registry[self.agent_id] = self
      self.state = "ready"

      Utils.debug("ACP agent ready via bridge: " .. tostring(self.agent_id))
      callback(nil)
    end)
  end)
end

function Client:stop()
  local agent_id = self.agent_id
  if agent_id then
    registry[agent_id] = nil
    self.agent_id = nil
    self._bridge:kill_agent(agent_id, function() end)
  end
  self.state = "disconnected"
end

function Client:is_ready() return self.state == "ready" end
function Client:is_connected() return self.state == "ready" or self.state == "connecting" end
function Client:get_state() return self.state end
function Client:recent_stderr() return self._bridge:recent_stderr() end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Client:_handle_event(event)
  local kind = event.kind
  local update = event.update

  if kind == "agent_stderr" then
    Utils.debug("ACP agent stderr: " .. tostring(update and update.line))
    return
  end

  if kind == "current_mode_update" and update then
    if self.session_modes then self.session_modes.current_mode_id = update.currentModeId end
    if self.on_mode_changed then self.on_mode_changed(update.currentModeId) end
  end

  if (kind == "config_option_update" or kind == "config_options_update") and update then
    self.config_options = update.configOptions
    if self.on_config_options_changed then self.on_config_options_changed(self.config_options) end
  end

  local handlers = self.config and self.config.handlers
  if handlers and handlers.on_session_update and update then handlers.on_session_update(update) end
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

---@param modes table|nil bridge shape: { currentModeId, availableModes }
function Client:_apply_modes(modes)
  if not modes then return end
  self.session_modes = {
    current_mode_id = modes.currentModeId,
    modes = modes.availableModes or {},
  }
end

function Client:create_session(cwd, mcp_servers, callback)
  callback = callback or function() end
  if not self.agent_id then
    callback(nil, { code = M.ERROR_CODES.CONNECTION_CLOSED, message = "ACP agent is not connected" })
    return
  end

  self._bridge:new_session({
    agentId = self.agent_id,
    cwd = cwd,
    -- nil lets the bridge discover MCP servers from disk; the Lua client used
    -- to hardcode {} here, so configured servers never reached the agent.
    mcpServers = mcp_servers and #mcp_servers > 0 and mcp_servers or nil,
  }, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    self:_apply_modes(result.modes)
    self.config_options = result.configOptions
    callback(result.sessionId, nil)
  end)
end

function Client:load_session(session_id, cwd, mcp_servers, callback)
  callback = callback or function() end
  if not self.agent_id then
    callback(nil, { code = M.ERROR_CODES.CONNECTION_CLOSED, message = "ACP agent is not connected" })
    return
  end

  -- Prefer resume: it reconnects without replaying the whole history. The Lua
  -- client could not tell the two apart and always replayed.
  local method = self:supports_resume() and "session/resume" or "session/load"
  self._bridge:request(method, {
    agentId = self.agent_id,
    sessionId = session_id,
    cwd = cwd,
    mcpServers = mcp_servers and #mcp_servers > 0 and mcp_servers or nil,
  }, { timeout = 120000 }, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    if result and result.modes then self:_apply_modes(result.modes) end
    callback(result, nil)
  end)
end

function Client:supports_resume()
  local caps = self.agent_capabilities or {}
  local session_caps = caps.sessionCapabilities or {}
  return session_caps.resume ~= nil
end

function Client:send_prompt(session_id, prompt, mode_id, callback)
  -- The legacy signature allowed a callback in the mode_id slot.
  if type(mode_id) == "function" then
    callback = mode_id
    mode_id = nil
  end
  callback = callback or function() end

  self._bridge:prompt({
    agentId = self.agent_id,
    sessionId = session_id,
    prompt = prompt,
  }, function(result, err) callback(result, err) end)
end

function Client:send_text_prompt(session_id, text, callback)
  self:send_prompt(session_id, { { type = "text", text = text } }, nil, callback)
end

function Client:cancel_session(session_id) self._bridge:cancel(self.agent_id, session_id) end

function Client:list_sessions(callback)
  callback = callback or function() end
  self._bridge:request(
    "session/list",
    { agentId = self.agent_id, cwd = Utils.root.get() },
    {},
    function(result, err) callback(result, err) end
  )
end

function Client:close_session(session_id, callback)
  self._bridge:request(
    "session/close",
    { agentId = self.agent_id, sessionId = session_id },
    {},
    callback or function() end
  )
end

--------------------------------------------------------------------------------
-- Modes and config options
--------------------------------------------------------------------------------

function Client:current_mode() return self.session_modes and self.session_modes.current_mode_id or nil end

function Client:all_modes() return self.session_modes and self.session_modes.modes or {} end

function Client:mode_by_id(mode_id)
  for _, mode in ipairs(self:all_modes()) do
    if mode.id == mode_id then return mode end
  end
  return nil
end

function Client:has_modes() return #self:all_modes() > 0 end

function Client:set_mode(session_id, mode_id, callback)
  self._bridge:request("session/set_mode", {
    agentId = self.agent_id,
    sessionId = session_id,
    modeId = mode_id,
  }, {}, callback or function() end)
end

Client.set_session_mode = Client.set_mode

function Client:all_config_options() return self.config_options or {} end

function Client:has_config_options() return #self:all_config_options() > 0 end

function Client:set_config_option(session_id, config_id, value, callback)
  self._bridge:request("session/set_config_option", {
    agentId = self.agent_id,
    sessionId = session_id,
    configId = config_id,
    value = value,
  }, {}, function(result, err)
    if result and result.configOptions then self.config_options = result.configOptions end
    if callback then callback(result, err) end
  end)
end

function Client:authenticate(method_id, callback)
  self._bridge:request(
    "agent/authenticate",
    { agentId = self.agent_id, methodId = method_id },
    { timeout = 0 },
    callback or function() end
  )
end

--------------------------------------------------------------------------------
-- Content block builders (same shapes as the Lua client)
--------------------------------------------------------------------------------

function Client:create_text_content(text, annotations)
  return { type = "text", text = text, annotations = annotations }
end

function Client:create_resource_link_content(uri, name, description, mime_type, size, title, annotations)
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

function Client:create_image_content(data, mime_type, uri, annotations)
  return { type = "image", data = data, mimeType = mime_type, uri = uri, annotations = annotations }
end

M.Client = Client

return M
