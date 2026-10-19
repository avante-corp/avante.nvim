local M = {}
local uv = vim.uv
local server, server_info, pending

local function page(message, success)
  local escaped = message:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  return string.format(
    [[<!doctype html>
<html><head><meta charset="utf-8"><title>Avante sign-in</title>
<style>body{font-family:system-ui,sans-serif;background:#131010;color:#f1ecec;
max-width:40rem;margin:20vh auto;padding:2rem;text-align:center}p{color:#b7b1b1}</style>
</head><body><h1>%s</h1><p>%s</p></body></html>]],
    success and "Return to Avante" or "Authorization failed",
    escaped
  )
end

local function clear_pending()
  local attempt = pending
  pending = nil
  if attempt then
    attempt.timer:stop()
    attempt.timer:close()
  end
  return attempt
end

local function finish(error_msg, code, params)
  local attempt = clear_pending()
  if not attempt then return end
  -- Capture the attempt before scheduling; pending has already been cleared.
  vim.schedule(function()
    if error_msg then
      if attempt.on_error then attempt.on_error(error_msg) end
    elseif attempt.on_success then
      attempt.on_success(code, params)
    end
  end)
end

local function parse_query(query)
  local params = {}
  for pair in (query or ""):gmatch("[^&]+") do
    local key, value = pair:match("([^=]+)=?(.*)")
    if key then params[vim.uri_decode(key)] = vim.uri_decode(value:gsub("+", " ")) end
  end
  return params
end

local function respond(client, status, body)
  local reasons = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found" }
  client:write(
    table.concat({
      string.format("HTTP/1.1 %d %s", status, reasons[status]),
      "Content-Type: text/html; charset=utf-8",
      "Content-Length: " .. #body,
      "Connection: close",
      "",
      body,
    }, "\r\n"),
    function()
      if not client:is_closing() then client:close() end
    end
  )
end

local function handle_request(client, request)
  local method, target = request:match("^(%S+)%s+(%S+)")
  if method ~= "GET" then return respond(client, 400, page("Invalid request")) end
  local path, query = target:match("^([^?]+)%??(.*)$")
  if path ~= "/auth/callback" then return respond(client, 404, page("Not found")) end
  local params = parse_query(query)
  local error_msg
  if not pending or params.state ~= pending.state then
    error_msg = "Invalid OAuth state"
  elseif params.error then
    error_msg = params.error_description or params.error
  elseif not params.code or params.code == "" then
    error_msg = "Missing authorization code"
  end
  finish(error_msg, params.code, params)
  respond(
    client,
    error_msg and 400 or 200,
    page(error_msg or "Finish signing in in Neovim. You can close this window.", not error_msg)
  )
end

local function on_connection(err)
  if err or not server then return end
  local client = uv.new_tcp()
  if not client then return end
  if not server:accept(client) then
    client:close()
    return
  end
  local buffer = ""
  client:read_start(function(read_err, chunk)
    if read_err or not chunk then
      if not client:is_closing() then client:close() end
      return
    end
    buffer = buffer .. chunk
    if #buffer > 16384 then
      client:read_stop()
      respond(client, 400, page("Request too large"))
    elseif buffer:find("\r\n\r\n", 1, true) then
      client:read_stop()
      handle_request(client, buffer)
    end
  end)
end

---@return { port: integer, redirect_uri: string }|nil
---@return string|nil error
function M.start()
  if server then return server_info end
  -- Prefer the usual port, then let the OS choose one if another process uses it.
  for _, port in ipairs({ 1455, 0 }) do
    local candidate = uv.new_tcp()
    if not candidate then return nil, "Could not create a TCP listener" end
    local bound = candidate:bind("127.0.0.1", port)
    local listening, err
    if bound then
      listening, err = candidate:listen(16, on_connection)
    end
    if listening then
      server = candidate
      local address = server:getsockname()
      if not address then
        M.stop()
        return nil, "Could not read listener address"
      end
      server_info = { port = address.port, redirect_uri = "http://127.0.0.1:" .. address.port .. "/auth/callback" }
      return server_info
    end
    candidate:close()
    if port == 0 then return nil, err or "Could not bind a loopback port" end
  end
end

function M.stop()
  clear_pending()
  if server then
    server:close()
    server = nil
    server_info = nil
  end
end

---@param state string
---@param on_success fun(code: string, params: table)
---@param on_error fun(error: string)
function M.wait_for_callback(state, on_success, on_error)
  if pending then return on_error("OAuth callback already pending") end
  local timer = uv.new_timer()
  if not timer then return on_error("Could not create OAuth timeout") end
  pending = { state = state, timer = timer, on_success = on_success, on_error = on_error }
  timer:start(5 * 60 * 1000, 0, function() finish("OAuth callback timed out") end)
end

return M
