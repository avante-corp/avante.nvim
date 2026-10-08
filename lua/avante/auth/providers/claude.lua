local Utils = require("avante.utils")
local Config = require("avante.config")
local P = require("avante.providers")
local pkce = require("avante.auth.pkce")
local AuthStore = require("avante.auth.store")
local OAuthUI = require("avante.ui.oauth")
local curl = require("plenary.curl")

---@class ClaudeAuthToken
---@field access_token string
---@field refresh_token string
---@field expires_at integer

---@class AvanteAuthProvider
local M = {}

local release_timer_lock
local auth_endpoint = "https://claude.ai/oauth/authorize"
local token_endpoint = "https://console.anthropic.com/v1/oauth/token"
local client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

---@private
---@class AvanteAnthropicState
---@field claude_token ClaudeAuthToken?
M.state = {
  claude_token = nil,
}

M.api_key_name = "ANTHROPIC_API_KEY"
M._is_setup = false
M._refresh_timer = nil
M._manager_check_timer = nil
M._file_watcher = nil
M._provider = nil

---@param token ClaudeAuthToken?
---@return boolean
local function is_valid_token(token)
  return token ~= nil
    and type(token.access_token) == "string"
    and type(token.refresh_token) == "string"
    and type(token.expires_at) == "number"
    and token.access_token ~= ""
    and token.refresh_token ~= ""
end

local function try_acquire_timer_lock()
  if not release_timer_lock then release_timer_lock = AuthStore.try_lock("claude-timer") end
  return release_timer_lock ~= nil
end

local function setup_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
  end

  local now = math.floor(os.time())
  local expires_at = M.state.claude_token and M.state.claude_token.expires_at or now
  local time_until_expiry = math.max(0, expires_at - now)
  local initial_interval = math.max(0, (time_until_expiry - 120) * 1000)
  local repeat_interval = 0

  M._refresh_timer = vim.uv.new_timer()
  M._refresh_timer:start(
    initial_interval,
    repeat_interval,
    vim.schedule_wrap(function()
      if M._is_setup then M.refresh_token(true, true) end
    end)
  )
end

local function start_manager_check_timer()
  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
  end

  M._manager_check_timer = vim.uv.new_timer()
  M._manager_check_timer:start(
    30000,
    30000,
    vim.schedule_wrap(function()
      if not M._refresh_timer and try_acquire_timer_lock() then setup_timer() end
    end)
  )
end

local function setup_file_watcher()
  if M._file_watcher then return end

  AuthStore.watch(function(data)
    if data and data.claude then
      M.state.claude_token = data.claude
    else
      M.state.claude_token = nil
    end
  end)

  M._file_watcher = true
end

local function setup_token_management(provider)
  local timer_lock_acquired = try_acquire_timer_lock()
  if timer_lock_acquired then
    setup_timer()
  else
    vim.schedule(function()
      if M._is_setup then M.refresh_token(true, false) end
    end)
  end

  setup_file_watcher()
  start_manager_check_timer()
  require("avante.tokenizers").setup((provider and provider.tokenizer_id) or "gpt-4o")
  vim.g.avante_login = true
end

---@param provider AvanteProviderFunctor
function M.setup(provider)
  -- Inherited providers reuse the claude functor's setup; Claude auth only
  -- applies when claude is selected.
  if Config.provider ~= "claude" then return end

  if not M.state then M.state = { claude_token = nil } end

  local provider_conf = P[Config.provider]
  local auth_type = provider_conf and provider_conf.auth_type

  if auth_type == "api" then
    M.api_key_name = "ANTHROPIC_API_KEY"
    provider.api_key_name = "ANTHROPIC_API_KEY"
    require("avante.tokenizers").setup(provider.tokenizer_id)
    M._is_setup = true
    return
  end

  M.api_key_name = ""
  provider.api_key_name = ""

  local data = AuthStore.read()
  local token = data and data.claude

  if token and is_valid_token(token) then
    M.state.claude_token = token
    setup_token_management(provider)
    M._is_setup = true
    return
  end

  -- No auth flow starts on launch; the user logs in explicitly via :AvanteLogin.
  M._provider = provider

  if token then
    Utils.warn(
      "Claude token data is corrupted or invalid. Run :AvanteLogin to re-authenticate.",
      { once = true, title = "Avante" }
    )
    AuthStore.update("claude", nil)
    return
  end

  Utils.info("Claude login required. Run :AvanteLogin to authenticate.", { once = true, title = "Avante" })
end

function M.authenticate()
  local verifier, verifier_err = pkce.generate_verifier()
  if not verifier then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE verifier: " .. (verifier_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local challenge, challenge_err = pkce.generate_challenge(verifier)
  if not challenge then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE challenge: " .. (challenge_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local state, state_err = pkce.generate_verifier()
  if not state then
    vim.schedule(
      function() vim.notify("Failed to generate PKCE state: " .. (state_err or "Unknown error"), vim.log.levels.ERROR) end
    )
    return
  end

  local function build_auth_url(redirect_uri)
    return string.format(
      "%s?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256",
      auth_endpoint,
      client_id,
      vim.uri_encode(redirect_uri),
      vim.uri_encode("org:create_api_key user:profile user:inference"),
      state,
      challenge
    )
  end

  local function exchange_code(code, callback_state, redirect_uri)
    local response = curl.post(token_endpoint, {
      body = vim.json.encode({
        grant_type = "authorization_code",
        client_id = client_id,
        code = code,
        state = callback_state,
        redirect_uri = redirect_uri,
        code_verifier = verifier,
      }),
      headers = {
        ["Content-Type"] = "application/json",
      },
    })

    if response.status >= 400 then
      vim.schedule(
        function() vim.notify(string.format("HTTP %d: %s", response.status, response.body), vim.log.levels.ERROR) end
      )
      return
    end

    local ok, tokens = pcall(vim.json.decode, response.body)
    if ok then
      M.store_tokens(tokens)
      M._is_setup = true
      setup_token_management(M._provider)
      vim.schedule(function() vim.notify("✓ Authentication successful!", vim.log.levels.INFO) end)
    else
      vim.schedule(function() vim.notify("Failed to decode JSON", vim.log.levels.ERROR) end)
    end
  end

  local function parse_manual_input(input)
    if not input then return nil, nil, "Authorization input is empty" end
    local value = vim.trim(input)
    if value == "" then return nil, nil, "Authorization input is empty" end

    local code, input_state
    if value:match("^https?://") then
      code = value:match("[?&]code=([^&]+)")
      input_state = value:match("[?&]state=([^&]+)")
      if code then code = vim.uri_decode(code) end
      if input_state then input_state = vim.uri_decode(input_state) end
    elseif value:find("#", 1, true) then
      local splits = vim.split(value, "#")
      code = splits[1]
      input_state = splits[2]
    else
      code = value
    end

    if not code or code == "" then return nil, nil, "Failed to parse authorization code" end
    if input_state and input_state ~= "" and input_state ~= state then
      return nil, nil, "State mismatch - potential CSRF attack"
    end

    return code, input_state or state, nil
  end

  local function prompt_manual_input()
    local Input = require("avante.ui.input")
    local input_config = Config.input or {}
    local input = Input:new({
      provider = input_config.provider,
      title = "Enter Auth Key: ",
      default = "",
      conceal = false,
      provider_opts = input_config.provider_opts,
      on_submit = function(raw)
        local code, callback_state, parse_err = parse_manual_input(raw)
        if not code then
          vim.schedule(function() vim.notify(parse_err, vim.log.levels.ERROR) end)
          return
        end
        exchange_code(code, callback_state, "https://console.anthropic.com/oauth/code/callback")
      end,
    })
    input:open()
  end

  vim.schedule(function()
    OAuthUI.show_auth_url({
      provider_name = "Claude Pro/Max",
      auth_url = build_auth_url("https://console.anthropic.com/oauth/code/callback"),
      on_open = function(ctx)
        local ok, err = pcall(vim.ui.open, ctx.auth_url)
        if ok then
          vim.notify("Opened Claude login URL in browser", vim.log.levels.INFO)
          ctx.close()
          prompt_manual_input()
        else
          vim.fn.setreg("+", ctx.auth_url)
          vim.notify(
            "Could not open browser (" .. tostring(err) .. "). URL copied to clipboard for manual flow.",
            vim.log.levels.WARN
          )
          ctx.close()
          prompt_manual_input()
        end
      end,
      on_copy = function(ctx)
        ctx.close()
        prompt_manual_input()
      end,
    })
  end)
end

---@param async boolean|nil
---@param force boolean|nil
---@return boolean|nil
function M.refresh_token(async, force)
  if not M.state or not M.state.claude_token then return false end
  async = async == nil and true or async
  force = force or false

  if
    not force
    and M.state.claude_token
    and M.state.claude_token.expires_at
    and M.state.claude_token.expires_at > math.floor(os.time())
  then
    return false
  end

  local body = {
    grant_type = "refresh_token",
    client_id = client_id,
    refresh_token = M.state.claude_token.refresh_token,
  }
  local curl_opts = {
    body = vim.json.encode(body),
    headers = {
      ["Content-Type"] = "application/json",
    },
  }

  local function handle_response(response)
    if response.status >= 400 then
      vim.schedule(
        function()
          vim.notify(
            string.format("[%s]Failed to refresh access token: %s", response.status, response.body),
            vim.log.levels.ERROR
          )
        end
      )
      return false
    end

    local ok, tokens = pcall(vim.json.decode, response.body)
    if ok then
      M.store_tokens(tokens)
      return true
    end

    return false
  end

  if async then
    curl.post(
      token_endpoint,
      vim.tbl_deep_extend("force", {
        callback = handle_response,
      }, curl_opts)
    )
  else
    local response = curl.post(token_endpoint, curl_opts)
    return handle_response(response)
  end
end

---@param tokens table
function M.store_tokens(tokens)
  if not M.state then M.state = { claude_token = nil } end

  local json = {
    access_token = tokens["access_token"],
    refresh_token = tokens["refresh_token"],
    expires_at = os.time() + tokens["expires_in"],
  }
  M.state.claude_token = json

  vim.schedule(function() AuthStore.update("claude", json) end)
end

function M.cleanup()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil
  end
  if release_timer_lock then
    release_timer_lock()
    release_timer_lock = nil
  end

  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
    M._manager_check_timer = nil
  end

  if M._file_watcher then M._file_watcher = nil end
end

function M.get_token() return M.state and M.state.claude_token or nil end

---@param provider_conf table
---@return boolean
function M.is_oauth(provider_conf) return provider_conf.auth_type == "max" end

---@param provider_conf table
---@param provider AvanteProviderFunctor
---@return table<string,string>|nil
function M.get_headers(provider_conf, provider)
  if M.is_oauth(provider_conf) then
    M.refresh_token(false, false)
    local token = M.get_token()
    if not token or not token.access_token then
      Utils.error("Claude Max authentication required. Run :AvanteLogin to login, then try again.")
      return nil
    end

    return {
      authorization = string.format("Bearer %s", token.access_token),
      ["user-agent"] = "claude-cli/2.1.2 (external, cli)",
      ["anthropic-beta"] = "oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,prompt-caching-2024-07-31",
    }
  end

  if P.env.require_api_key(provider_conf) then
    local api_key = provider.parse_api_key()
    if not api_key then
      Utils.error("Claude: API key is not set. Please set " .. M.api_key_name)
      return nil
    end
    return {
      ["x-api-key"] = api_key,
      ["anthropic-beta"] = "prompt-caching-2024-07-31",
    }
  end

  return {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() M.cleanup() end,
})

return M
