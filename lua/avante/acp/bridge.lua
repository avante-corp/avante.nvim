---Client for the Python ACP bridge.
---
---Neovim runs exactly one bridge process, which owns every agent subprocess and
---every session. This module is the transport plus the Neovim half of the
---bridge protocol; it deliberately knows nothing about ACP itself.
---
---The invariants mirror the Python side, because their absence is what made the
---previous Lua-only ACP client hang:
--- * every outbound request has a deadline (0 means "no deadline")
--- * every inbound request produces exactly one reply, including on error
--- * unknown inbound methods get -32601 rather than silence
--- * losing the process fails all in-flight requests

local Utils = require("avante.utils")
local Config = require("avante.config")

local uv = vim.uv or vim.loop

local M = {}

M.ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603,
  -- ACP
  AUTH_REQUIRED = -32000,
  RESOURCE_NOT_FOUND = -32002,
  -- avante-internal
  PROTOCOL_ERROR = -32001,
  TIMEOUT_ERROR = -32003,
  CONNECTION_CLOSED = -32004,
}

M.DEFAULT_TIMEOUT = 30000

---Requests whose duration is bounded by user or agent action, not a clock.
M.NO_DEADLINE = {
  ["session/prompt"] = true,
  ["agent/authenticate"] = true,
}

---How long to allow for starting the bridge and each agent. npx may need to
---download a package on first run.
M.SPAWN_TIMEOUT = 300000

local STDERR_TAIL_LINES = 50

---@class avante.acp.Bridge
---@field handle uv.uv_process_t|nil
---@field stdin uv.uv_pipe_t|nil
---@field stdout uv.uv_pipe_t|nil
---@field stderr uv.uv_pipe_t|nil
---@field callbacks table<number, fun(result: any, err: table|nil)>
---@field timers table<number, any>
---@field methods table<number, string>
---@field handlers table<string, fun(params: table, reply: fun(result: any, err: table|nil))>
---@field event_handlers fun(event: table)[]
local Bridge = {}
Bridge.__index = Bridge

--------------------------------------------------------------------------------
-- Locating the interpreter
--------------------------------------------------------------------------------

---@return string plugin_root
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  -- lua/avante/acp/bridge.lua -> repo root
  return vim.fn.fnamemodify(source, ":h:h:h:h")
end

M.plugin_root = plugin_root

---Work out how to run the bridge.
---Prefers an existing venv, then uv, so a normal install needs no manual setup.
---@return string|nil command, string[] args, string|nil err
function M.resolve_interpreter()
  local root = plugin_root()
  local project = root .. "/python"

  local configured = Config.acp_python
  if configured and configured ~= "" then return configured, { "-m", "avante_acp" }, nil end

  local candidates = {
    project .. "/.venv/bin/python",
    project .. "/.venv/Scripts/python.exe",
    vim.fn.stdpath("data") .. "/avante/py/bin/python",
  }
  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 then return candidate, { "-m", "avante_acp" }, nil end
  end

  if vim.fn.executable("uv") == 1 then
    return "uv", { "run", "--project", project, "python", "-m", "avante_acp" }, nil
  end

  return nil,
    {},
    "No Python environment for the ACP bridge. Install uv, or run "
      .. "`cd "
      .. project
      .. " && uv sync`, or set `acp_python` in your avante config."
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

---@return avante.acp.Bridge
function M.new()
  return setmetatable({
    handle = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    id_counter = 0,
    callbacks = {},
    timers = {},
    methods = {},
    handlers = {},
    event_handlers = {},
    stderr_tail = {},
    state = "stopped",
    _buffer = "",
  }, Bridge)
end

local singleton = nil

---Shared bridge for this Neovim instance. One process owns every agent, which
---is what allows several chats and worktrees at once.
---@return avante.acp.Bridge
function M.get()
  if singleton == nil then
    singleton = M.new()
    singleton:register_default_handlers()
  end
  return singleton
end

function M.reset()
  if singleton then pcall(function() singleton:stop() end) end
  singleton = nil
end

--------------------------------------------------------------------------------
-- Process lifecycle
--------------------------------------------------------------------------------

---@param callback fun(err: table|nil)
function Bridge:start(callback)
  callback = callback or function() end

  if self.state == "running" then
    callback(nil)
    return
  end
  if self.state == "starting" then
    self._pending_starts = self._pending_starts or {}
    table.insert(self._pending_starts, callback)
    return
  end

  local command, args, err = M.resolve_interpreter()
  if not command then
    callback({ code = M.ERROR_CODES.INTERNAL_ERROR, message = err })
    return
  end

  self.state = "starting"
  self._pending_starts = { callback }

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  if not stdin or not stdout or not stderr then
    self:_finish_start({ code = M.ERROR_CODES.INTERNAL_ERROR, message = "Failed to create pipes" })
    return
  end

  local env = {}
  for key, value in pairs(uv.os_environ() or {}) do
    env[#env + 1] = key .. "=" .. value
  end
  if Config.debug then env[#env + 1] = "AVANTE_ACP_LOG_LEVEL=DEBUG" end

  local handle, pid = uv.spawn(command, {
    args = args,
    env = env,
    cwd = plugin_root(),
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    vim.schedule(function() self:_on_exit(code, signal) end)
  end)

  if not handle then
    self:_finish_start({
      code = M.ERROR_CODES.INTERNAL_ERROR,
      message = "Failed to spawn ACP bridge: " .. command,
    })
    return
  end

  self.handle = handle
  self.stdin = stdin
  self.stdout = stdout
  self.stderr = stderr

  Utils.debug("Started ACP bridge (pid " .. tostring(pid) .. "): " .. command .. " " .. table.concat(args, " "))

  self:_read_stdout()
  self:_read_stderr()

  -- The handshake doubles as a readiness probe: if the interpreter is broken we
  -- find out here rather than on the user's first prompt.
  self:request("bridge/hello", {}, {
    timeout = M.SPAWN_TIMEOUT,
    -- We are mid-start; without this the auto-start guard would recurse.
    _starting_handshake = true,
  }, function(result, hello_err)
    if hello_err then
      self:_finish_start(hello_err)
      return
    end
    self.info = result
    self.state = "running"
    Utils.debug("ACP bridge ready: v" .. tostring(result and result.version))
    self:_finish_start(nil)
  end)
end

---@param err table|nil
function Bridge:_finish_start(err)
  if err then
    self.state = "stopped"
    self:_teardown_process()
  end
  local waiting = self._pending_starts or {}
  self._pending_starts = nil
  for _, callback in ipairs(waiting) do
    local ok, cb_err = pcall(callback, err)
    if not ok then Utils.error("ACP bridge start callback failed: " .. tostring(cb_err)) end
  end
end

function Bridge:_on_exit(code, signal)
  Utils.debug("ACP bridge exited (code=" .. tostring(code) .. " signal=" .. tostring(signal) .. ")")
  self.state = "stopped"

  local reason = string.format("ACP bridge exited (code=%d, signal=%d)", code or -1, signal or 0)
  local stderr = self:recent_stderr()
  if stderr ~= "" then reason = reason .. "\n" .. stderr end

  self:_teardown_process()
  self:_fail_pending(reason)
  self:_finish_start({ code = M.ERROR_CODES.CONNECTION_CLOSED, message = reason })
end

function Bridge:_teardown_process()
  for _, name in ipairs({ "stdin", "stdout", "stderr" }) do
    local pipe = self[name]
    if pipe and not pipe:is_closing() then pcall(function() pipe:close() end) end
    self[name] = nil
  end
  if self.handle and not self.handle:is_closing() then pcall(function() self.handle:close() end) end
  self.handle = nil
end

function Bridge:stop()
  if self.handle and not self.handle:is_closing() then
    pcall(function() self.handle:kill(15) end)
  end
  self:_teardown_process()
  self:_fail_pending("ACP bridge stopped")
  self.state = "stopped"
end

function Bridge:is_running() return self.state == "running" end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

function Bridge:_read_stdout()
  self.stdout:read_start(function(err, data)
    if err then
      vim.schedule(function() Utils.error("ACP bridge stdout error: " .. tostring(err)) end)
      return
    end
    if not data then return end

    self._buffer = self._buffer .. data
    local lines = vim.split(self._buffer, "\n", { plain = true })
    self._buffer = lines[#lines]

    for i = 1, #lines - 1 do
      local line = vim.trim(lines[i])
      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if ok then
          vim.schedule(function() self:_handle_message(message) end)
        else
          vim.schedule(function() Utils.debug("Discarding malformed bridge message: " .. line:sub(1, 200)) end)
        end
      end
    end
  end)
end

function Bridge:_read_stderr()
  self.stderr:read_start(function(err, data)
    if err or not data then return end
    for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
      if vim.trim(line) ~= "" then
        table.insert(self.stderr_tail, line)
        while #self.stderr_tail > STDERR_TAIL_LINES do
          table.remove(self.stderr_tail, 1)
        end
      end
    end
    if Config.debug then vim.schedule(function() Utils.debug("ACP bridge stderr: " .. data) end) end
  end)
end

---@return string
function Bridge:recent_stderr() return table.concat(self.stderr_tail or {}, "\n") end

--------------------------------------------------------------------------------
-- Outbound
--------------------------------------------------------------------------------

function Bridge:_next_id()
  self.id_counter = self.id_counter + 1
  return self.id_counter
end

---@param message table
---@return boolean sent
function Bridge:_send(message)
  if not self.stdin or self.stdin:is_closing() then return false end
  local ok, data = pcall(vim.json.encode, message)
  if not ok then return false end
  self.stdin:write(data .. "\n")
  return true
end

---@param method string
---@param params table|nil
---@param opts { timeout?: number }|nil
---@param callback fun(result: any, err: table|nil)|nil
function Bridge:request(method, params, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  -- Self-heal: a request can arrive from a code path that never called start(),
  -- or after the bridge died. Start it and retry once rather than failing with
  -- "bridge is not running", which is never actionable for the user.
  -- `_starting_handshake` guards the bridge/hello sent from within start().
  if self.state ~= "running" and not opts._starting_handshake then
    if opts._restarted then
      callback(nil, {
        code = M.ERROR_CODES.CONNECTION_CLOSED,
        message = "ACP bridge could not be started",
        data = { method = method, stderr = self:recent_stderr() },
      })
      return
    end
    self:start(function(start_err)
      if start_err then
        callback(nil, start_err)
        return
      end
      local retry = vim.tbl_extend("force", opts, { _restarted = true })
      self:request(method, params, retry, callback)
    end)
    return
  end

  local id = self:_next_id()
  self.callbacks[id] = callback
  self.methods[id] = method

  local timeout = opts.timeout
  if timeout == nil then timeout = M.NO_DEADLINE[method] and 0 or (Config.acp_timeout or M.DEFAULT_TIMEOUT) end

  if timeout and timeout > 0 then
    self.timers[id] = vim.defer_fn(function()
      self:_resolve(id, nil, {
        code = M.ERROR_CODES.TIMEOUT_ERROR,
        message = string.format("ACP bridge request '%s' timed out after %dms", method, timeout),
        data = { method = method, stderr = self:recent_stderr() },
      })
    end, timeout)
  end

  local sent = self:_send({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
  if not sent then
    self:_resolve(id, nil, {
      code = M.ERROR_CODES.CONNECTION_CLOSED,
      message = "Cannot send '" .. method .. "': ACP bridge is not running",
    })
  end
end

---@param method string
---@param params table|nil
function Bridge:notify(method, params)
  self:_send({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
end

---Resolve a pending request exactly once, cancelling its deadline.
function Bridge:_resolve(id, result, err)
  local callback = self.callbacks[id]
  if not callback then return end

  self.callbacks[id] = nil
  self.methods[id] = nil

  local timer = self.timers[id]
  self.timers[id] = nil
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end

  local ok, cb_err = pcall(callback, result, err)
  if not ok then Utils.error("ACP bridge callback failed: " .. tostring(cb_err)) end
end

function Bridge:_fail_pending(reason)
  local ids = vim.tbl_keys(self.callbacks)
  table.sort(ids)
  for _, id in ipairs(ids) do
    self:_resolve(id, nil, {
      code = M.ERROR_CODES.CONNECTION_CLOSED,
      message = reason,
      data = { method = self.methods[id] },
    })
  end
end

--------------------------------------------------------------------------------
-- Inbound
--------------------------------------------------------------------------------

function Bridge:_handle_message(message)
  if type(message) ~= "table" then return end

  local id = message.id
  if id == vim.NIL then id = nil end

  if message.method and message.result == nil and message.error == nil then
    self:_handle_call(id, message.method, message.params or {})
  elseif id ~= nil then
    local err = message.error
    if err == vim.NIL then err = nil end
    local result = message.result
    if result == vim.NIL then result = nil end
    self:_resolve(id, result, err)
  end
end

function Bridge:_handle_call(id, method, params)
  if method == "event" then
    self:_dispatch_event(params)
    return
  end

  local handler = self.handlers[method]
  if not handler then
    -- Silence would block the bridge, which in turn blocks the agent.
    if id ~= nil then
      self:_send({
        jsonrpc = "2.0",
        id = id,
        error = { code = M.ERROR_CODES.METHOD_NOT_FOUND, message = "Method not supported by avante: " .. method },
      })
    end
    return
  end

  if id == nil then
    pcall(handler, params, function() end)
    return
  end

  local answered = false
  local function reply(result, err)
    if answered then return end
    answered = true
    if err then
      self:_send({ jsonrpc = "2.0", id = id, error = err })
    else
      self:_send({ jsonrpc = "2.0", id = id, result = result == nil and vim.empty_dict() or result })
    end
  end

  local ok, handler_err = pcall(handler, params, reply)
  if not ok then
    Utils.error("ACP handler for " .. method .. " failed: " .. tostring(handler_err))
    reply(nil, { code = M.ERROR_CODES.INTERNAL_ERROR, message = tostring(handler_err) })
  end
end

function Bridge:_dispatch_event(event)
  for _, handler in ipairs(self.event_handlers) do
    local ok, err = pcall(handler, event)
    if not ok then Utils.error("ACP event handler failed: " .. tostring(err)) end
  end
end

--------------------------------------------------------------------------------
-- Handler registration
--------------------------------------------------------------------------------

---@param method string
---@param handler fun(params: table, reply: fun(result: any, err: table|nil))
function Bridge:on(method, handler) self.handlers[method] = handler end

---@param handler fun(event: table)
---@return fun() unsubscribe
function Bridge:on_event(handler)
  table.insert(self.event_handlers, handler)
  return function()
    for i, existing in ipairs(self.event_handlers) do
      if existing == handler then
        table.remove(self.event_handlers, i)
        return
      end
    end
  end
end

---Filesystem access stays in Neovim because only the editor knows about
---unsaved buffers; the agent must see what the user sees.
function Bridge:register_default_handlers()
  self:on("fs/read", function(params, reply)
    local abs_path = Utils.to_absolute_path(params.path)
    local lines, err, errname = Utils.read_file_from_buf_or_disk(abs_path)
    if err then
      reply(nil, {
        code = errname == "ENOENT" and -32002 or M.ERROR_CODES.INTERNAL_ERROR,
        message = tostring(err),
      })
      return
    end
    reply({ content = table.concat(lines or {}, "\n") })
  end)

  self:on("fs/write", function(params, reply)
    local abs_path = Utils.to_absolute_path(params.path)
    local file, open_err = io.open(abs_path, "w")
    if not file then
      reply(nil, { code = M.ERROR_CODES.INTERNAL_ERROR, message = tostring(open_err) })
      return
    end
    file:write(params.content or "")
    file:close()
    reply({})
  end)
end

--------------------------------------------------------------------------------
-- Bridge protocol convenience wrappers
--------------------------------------------------------------------------------

function Bridge:spawn_agent(opts, callback)
  self:request("agent/spawn", opts, { timeout = M.SPAWN_TIMEOUT }, callback)
end

function Bridge:kill_agent(agent_id, callback) self:request("agent/kill", { agentId = agent_id }, {}, callback) end

function Bridge:new_session(opts, callback) self:request("session/new", opts, { timeout = 120000 }, callback) end

function Bridge:prompt(opts, callback) self:request("session/prompt", opts, { timeout = 0 }, callback) end

function Bridge:cancel(agent_id, session_id)
  self:notify("session/cancel", { agentId = agent_id, sessionId = session_id })
end

M.Bridge = Bridge

return M
