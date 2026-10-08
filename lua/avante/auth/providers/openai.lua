local Utils = require("avante.utils")
local Config = require("avante.config")
local Providers = require("avante.providers")
local Path = require("plenary.path")
local pkce = require("avante.auth.pkce")
local AuthStore = require("avante.auth.store")
local OAuthServer = require("avante.auth.oauth_server")
local OIDC = require("avante.auth.oidc")
local curl = require("plenary.curl")

---@class OpenAIAuthToken
---@field access_token string
---@field refresh_token string
---@field expires_at integer
---@field client_id string Issued public client ID
---@field scopes string[]
---@field id_token string
---@field subject string Validated OpenAI identity

---@class AvanteOpenAIAuthProvider
local M = {}

local auth_issuer = "https://auth.openai.com"

-- See auth/README.md for the sign-in and credential lifecycle.
local authorize_endpoint = auth_issuer .. "/api/accounts/authorize"
local token_endpoint = auth_issuer .. "/api/accounts/oauth/token"
local dynamic_client_id = "dynamic_agent_client"
local resource = "https://api.openai.com/v1"
local direct_token_scope = "chatgpt.tokens.use.direct"
local scope = "openid profile email offline_access resource.invoke " .. direct_token_scope
local host_id_path = vim.fn.stdpath("data") .. "/avante/device_id"
local refresh_skew_sec = 120
local refresh_check_interval_ms = 60000

---@private
---@class AvanteOpenAIState
---@field openai_token OpenAIAuthToken?
M.state = {
  openai_token = nil,
}

M.api_key_name = "OPENAI_API_KEY"
M._is_setup = false
M._refresh_timer = nil
M._file_watcher = nil
M._refresh_in_flight = false
M._provider = nil

local function is_valid_token(token)
  return type(token) == "table"
    and type(token.access_token) == "string"
    and token.access_token ~= ""
    and type(token.refresh_token) == "string"
    and token.refresh_token ~= ""
    and type(token.expires_at) == "number"
    and type(token.client_id) == "string"
    and token.client_id ~= ""
    and token.client_id ~= dynamic_client_id
    and type(token.scopes) == "table"
    and vim.tbl_contains(token.scopes, direct_token_scope)
    and type(token.subject) == "string"
    and token.subject ~= ""
    and type(token.id_token) == "string"
    and token.id_token ~= ""
end

-- OpenAI identifies each installation ("agent host") by a stable UUID. It is kept
-- apart from auth.json so logging out does not register a new host.
local function get_or_create_host_id()
  local ok, existing = pcall(function() return vim.trim(Path:new(host_id_path):read()) end)
  if ok and existing:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
    return existing:lower()
  end

  local bytes, err = pkce.random_bytes(16)
  if not bytes then return nil, err end
  local b = { bytes:byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = string.format(string.rep("%02x", 16), unpack(b))
  local uuid =
    string.format("%s-%s-%s-%s-%s", hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21))

  local parent = Path:new(host_id_path):parent()
  if not parent:exists() then parent:mkdir({ parents = true }) end
  Path:new(host_id_path):write(uuid, "w")
  return uuid
end

---@return string[]|nil scopes
---@return string|nil error
local function granted_scopes(tokens)
  if type(tokens.scope) ~= "string" or vim.trim(tokens.scope) == "" then
    return nil, "Token response has invalid scope"
  end
  local scopes = vim.split(vim.trim(tokens.scope), "%s+")
  if not vim.tbl_contains(scopes, direct_token_scope) then
    return nil, "OpenAI OAuth grant did not include " .. direct_token_scope
  end
  return scopes
end

local function setup_token_management(provider)
  if not M._file_watcher then
    M._file_watcher = AuthStore.watch(function(data)
      local token = data and data.openai
      M.state.openai_token = is_valid_token(token) and token or nil
    end)
  end
  if not M._refresh_timer then
    M._refresh_timer = vim.uv.new_timer()
    M._refresh_timer:start(
      refresh_check_interval_ms,
      refresh_check_interval_ms,
      vim.schedule_wrap(function() M.refresh_token(true, false) end)
    )
  end
  require("avante.tokenizers").setup((provider and provider.tokenizer_id) or "gpt-4o")
  vim.g.avante_login = true
end

local function encode_form(params)
  local parts = {}
  -- rfc2396 escapes "+", "=", "&", ":" and "/", which the default rfc3986 mode leaves as-is.
  for key, value in pairs(params) do
    table.insert(
      parts,
      string.format("%s=%s", vim.uri_encode(key, "rfc2396"), vim.uri_encode(tostring(value), "rfc2396"))
    )
  end
  return table.concat(parts, "&")
end

local function token_request_options(body)
  return {
    body = encode_form(body),
    headers = { Accept = "application/json", ["Content-Type"] = "application/x-www-form-urlencoded" },
    timeout = 30000,
  }
end

local function decode_tokens(response)
  if type(response) ~= "table" or type(response.status) ~= "number" then return nil, "Token request failed" end
  if response.status ~= 200 then return nil, "Token endpoint returned HTTP " .. response.status end
  local ok, tokens = pcall(vim.json.decode, response.body)
  if not ok or type(tokens) ~= "table" then return nil, "Invalid token response" end
  return tokens
end

---@param provider AvanteProviderFunctor
function M.setup(provider)
  -- OpenAI-compatible providers keep their own API-key setup.
  if Config.provider ~= "openai" then return end

  M._provider = provider
  local provider_conf = Providers[Config.provider]
  local auth_type = provider_conf and provider_conf.auth_type

  if auth_type == "chatgpt" then
    M.api_key_name = ""
    provider.api_key_name = ""
    provider_conf.api_key_name = ""
  else
    M.api_key_name = "OPENAI_API_KEY"
    provider.api_key_name = "OPENAI_API_KEY"
    if provider_conf then provider_conf.api_key_name = "OPENAI_API_KEY" end
    require("avante.tokenizers").setup(provider.tokenizer_id or "gpt-4o")
    vim.g.avante_login = true
    M._is_setup = true
    return
  end

  local data = AuthStore.read()
  local token = data and data.openai
  if token and is_valid_token(token) then
    M.state.openai_token = token
    setup_token_management(provider)
    M._is_setup = true
    return
  end

  M.state.openai_token = nil
  M._is_setup = false
  -- No auth flow starts on launch; the user logs in explicitly via :AvanteLogin.
  if token then
    Utils.warn(
      "OpenAI credentials are invalid or from an older sign-in flow. Run :AvanteLogin to re-authenticate.",
      { once = true, title = "Avante" }
    )
    AuthStore.update("openai", nil)
    return
  end

  Utils.info("OpenAI login required. Run :AvanteLogin to authenticate.", { once = true, title = "Avante" })
end

function M.authenticate()
  OAuthServer.stop()
  local crypto_ok, crypto_err = OIDC.check_available()
  if not crypto_ok then return Utils.error(crypto_err or "OpenAI signature verification unavailable") end
  local host_id, host_err = get_or_create_host_id()
  if not host_id then return Utils.error("Failed to create OpenAI host ID: " .. tostring(host_err)) end
  local verifier, verifier_err = pkce.generate_verifier()
  local state, state_err = pkce.generate_verifier()
  local nonce, nonce_err = pkce.generate_verifier()
  if not verifier or not state or not nonce then
    return Utils.error("Failed to generate OAuth randomness: " .. tostring(verifier_err or state_err or nonce_err))
  end
  local challenge, challenge_err = pkce.generate_challenge(verifier)
  if not challenge then return Utils.error("Failed to generate PKCE challenge: " .. tostring(challenge_err)) end

  ---@type OpenAIAuthToken|nil
  local saved = M.get_token() or (AuthStore.read() or {}).openai
  if type(saved) ~= "table" then saved = nil end
  ---@type string|nil
  local registered_client = saved and type(saved.client_id) == "string" and saved.client_id or nil
  if registered_client == "" or registered_client == dynamic_client_id then registered_client = nil end
  local server_info, server_err = OAuthServer.start()
  if not server_info then return Utils.error("Failed to start OAuth callback server: " .. tostring(server_err)) end

  local function fail(err)
    OAuthServer.stop()
    Utils.error("OpenAI authentication failed: " .. tostring(err))
  end

  OAuthServer.wait_for_callback(state, function(code, params)
    OAuthServer.stop()
    local issued_client = params.client_id or registered_client
    if not issued_client or issued_client == "" or issued_client == dynamic_client_id then
      return fail("Callback did not contain an issued client ID")
    end
    if registered_client and issued_client ~= registered_client then return fail("Callback client ID changed") end
    local ok, response = pcall(
      curl.post,
      token_endpoint,
      token_request_options({
        grant_type = "authorization_code",
        client_id = issued_client,
        code = code,
        code_verifier = verifier,
        redirect_uri = server_info.redirect_uri,
        resource = resource,
      })
    )
    if not ok then return fail("Could not reach the token endpoint") end
    local tokens, token_err = decode_tokens(response)
    if not tokens then return fail(token_err) end
    local identity, identity_err = OIDC.validate(tokens.id_token, issued_client, nonce)
    if not identity then return fail(identity_err) end
    if registered_client and saved and saved.subject and saved.subject ~= identity.sub then
      return fail("Signed-in identity changed")
    end
    if not M.store_tokens(tokens, { client_id = issued_client, subject = identity.sub }) then return end
    M._is_setup = true
    setup_token_management(M._provider)
    Utils.info("OpenAI authentication successful")
  end, fail)

  local auth_url = authorize_endpoint
    .. "?"
    .. encode_form({
      client_id = registered_client or dynamic_client_id,
      agent_name_hint = not registered_client and "Avante" or nil,
      ext_agent_host_id = "urn:uuid:" .. host_id,
      id_token_hint = registered_client and saved and saved.id_token or nil,
      response_type = "code",
      redirect_uri = server_info.redirect_uri,
      resource = resource,
      scope = scope,
      state = state,
      nonce = nonce,
      code_challenge = challenge,
      code_challenge_method = "S256",
    })
  -- vim.ui.open returns nil plus an error when no browser launcher is available.
  local ok, process, open_err = pcall(vim.ui.open, auth_url)
  if not ok or not process then return fail(open_err or "Could not open a browser") end
  Utils.info("Continue with ChatGPT in your browser")
end

---@param tokens table
---@param registration { client_id: string, subject?: string, id_token?: string }
---@return boolean
function M.store_tokens(tokens, registration)
  local scopes, scope_err = granted_scopes(tokens)
  if not scopes then
    Utils.error(scope_err or "Missing granted scopes")
    return false
  end
  local token = {
    access_token = tokens.access_token,
    refresh_token = tokens.refresh_token,
    expires_at = os.time() + (tonumber(tokens.expires_in) or 0),
    client_id = registration.client_id,
    subject = registration.subject,
    id_token = tokens.id_token or registration.id_token,
    scopes = scopes,
  }
  if not is_valid_token(token) or token.expires_at <= os.time() then
    Utils.error("OpenAI returned incomplete credentials")
    return false
  end
  if not AuthStore.update("openai", token) then return false end
  M.state.openai_token = token
  return true
end

---@param async boolean|nil
---@param force boolean|nil
---@return boolean
function M.refresh_token(async, force)
  local token = M.get_token()
  if not token or not is_valid_token(token) or M._refresh_in_flight then return false end
  if not force and token.expires_at - os.time() > refresh_skew_sec then return false end
  local release = AuthStore.try_lock("openai-refresh")
  if not release then return false end
  -- Another process may have refreshed since our watcher last ran.
  local data = AuthStore.read()
  if data and is_valid_token(data.openai) then
    token = data.openai
    M.state.openai_token = token
  end
  if not force and token.expires_at - os.time() > refresh_skew_sec then
    release()
    return false
  end
  M._refresh_in_flight = true

  local finished = false
  local function finish(response)
    if finished then return false end
    finished = true
    local tokens, err = decode_tokens(response)
    local success = false
    if tokens then
      -- Each successful refresh must replace both tokens before releasing the lock.
      success = M.store_tokens(tokens, token)
    else
      Utils.error("Failed to refresh OpenAI credentials: " .. tostring(err))
    end
    M._refresh_in_flight = false
    release()
    return success
  end
  local opts = token_request_options({
    grant_type = "refresh_token",
    client_id = token.client_id,
    refresh_token = token.refresh_token,
    resource = resource,
  })
  opts.on_error = vim.schedule_wrap(function() finish(nil) end)
  if async ~= false then opts.callback = vim.schedule_wrap(finish) end
  local ok, response = pcall(curl.post, token_endpoint, opts)
  if not ok then return finish(nil) end
  if async == false then return finish(response) end
  return true
end

function M.cleanup()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil
  end

  if M._file_watcher then
    M._file_watcher()
    M._file_watcher = nil
  end
  OAuthServer.stop()
end

---@return OpenAIAuthToken|nil
function M.get_token() return M.state and M.state.openai_token or nil end

---@param provider_conf table
---@return boolean
function M.is_oauth(provider_conf) return provider_conf.auth_type == "chatgpt" end

---@param provider_conf table
---@param provider AvanteProviderFunctor
---@return table<string,string>|nil
function M.get_headers(provider_conf, provider)
  if M.is_oauth(provider_conf) then
    if not M._is_setup then M.setup(provider) end
    if not M.state or not M.state.openai_token then
      Utils.error("OpenAI authentication required. Run :AvanteLogin to login, then try again.")
      return nil
    end

    M.refresh_token(false, false)
    local token = M.state.openai_token
    if not token or not is_valid_token(token) or token.expires_at <= os.time() then
      Utils.error("OpenAI access token unavailable. Please re-authenticate.")
      return nil
    end

    local headers = {
      ["Authorization"] = "Bearer " .. token.access_token,
      ["User-Agent"] = Utils.get_user_agent_string(),
    }
    return headers
  end

  if Providers.env.require_api_key(provider_conf) then
    local api_key = provider.parse_api_key()
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return nil
    end
    return {
      ["Authorization"] = "Bearer " .. api_key,
    }
  end

  return {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() M.cleanup() end,
})

return M
