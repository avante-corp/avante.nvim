---Reference implementation:
---https://github.com/zbirenbaum/copilot.lua/blob/master/lua/copilot/auth.lua config file
---https://github.com/zed-industries/zed/blob/ad43bbbf5eda59eba65309735472e0be58b4f7dd/crates/copilot/src/copilot_chat.rs#L272 for authorization
---
---@class CopilotToken
---@field annotations_enabled boolean
---@field chat_enabled boolean
---@field chat_jetbrains_enabled boolean
---@field code_quote_enabled boolean
---@field codesearch boolean
---@field copilotignore_enabled boolean
---@field endpoints {api: string, ["origin-tracker"]: string, proxy: string, telemetry: string}
---@field expires_at integer
---@field individual boolean
---@field nes_enabled boolean
---@field prompt_8k boolean
---@field public_suggestions string
---@field refresh_in integer
---@field sku string
---@field snippy_load_test_enabled boolean
---@field telemetry string
---@field token string
---@field tracking_id string
---@field vsc_electron_fetcher boolean
---@field xcode boolean
---@field xcode_chat boolean

local curl = require("plenary.curl")

local Path = require("plenary.path")
local Utils = require("avante.utils")
local Providers = require("avante.providers")
local OpenAI = require("avante.providers").openai

local H = {}

---@class AvanteProviderFunctor
local M = {}

local copilot_path = vim.fn.stdpath("data") .. "/avante/github-copilot.json"
local lockfile_path = vim.fn.stdpath("data") .. "/avante/copilot-timer.lock"

-- Lockfile management
local function is_process_running(pid)
  local result = vim.uv.kill(pid, 0)
  if result ~= nil and result == 0 then
    return true
  else
    return false
  end
end

local function try_acquire_timer_lock()
  local lockfile = Path:new(lockfile_path)

  local tmp_lockfile = lockfile_path .. ".tmp." .. vim.fn.getpid()

  Path:new(tmp_lockfile):write(tostring(vim.fn.getpid()), "w")

  -- Check existing lock
  if lockfile:exists() then
    local content = lockfile:read()
    local pid = tonumber(content)
    if pid and is_process_running(pid) then
      os.remove(tmp_lockfile)
      return false -- Another instance is already managing
    end
  end

  -- Attempt to take ownership
  local success = os.rename(tmp_lockfile, lockfile_path)
  if not success then
    os.remove(tmp_lockfile)
    return false
  end

  return true
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
      if not M._refresh_timer and try_acquire_timer_lock() then M.setup_timer() end
    end)
  )
end

---@class OAuthToken
---@field user string
---@field oauth_token string
---
---@return string
function H.get_oauth_token()
  local xdg_config = vim.fn.expand("$XDG_CONFIG_HOME")
  local os_name = Utils.get_os_name()
  ---@type string
  local config_dir

  if xdg_config and vim.fn.isdirectory(xdg_config) > 0 then
    config_dir = xdg_config
  elseif vim.tbl_contains({ "linux", "darwin" }, os_name) then
    config_dir = vim.fn.expand("~/.config")
  else
    config_dir = vim.fn.expand("$LOCALAPPDATA")
  end

  local copilot_dir = Path:new(config_dir):joinpath("github-copilot")

  -- Try the new SQLite auth.db first (copilot.lua >= 2025.12)
  local db_path = copilot_dir:joinpath("auth.db")
  if db_path:exists() then
    local token = H.read_token_from_authdb(tostring(db_path))
    if token then return token end
  end

  -- Fall back to legacy JSON files: hosts.json (copilot.lua) / apps.json (copilot.vim)
  ---@type Path[]
  local json_files = vim.iter({ "hosts.json", "apps.json" }):fold({}, function(acc, name)
    local p = copilot_dir:joinpath(name)
    if p:exists() then table.insert(acc, p) end
    return acc
  end)

  if #json_files > 0 then
    local token = H.read_token_from_json(json_files[1])
    if token then return token end
  end

  error(
    "Could not find a Copilot OAuth token.\n"
      .. "Make sure you are signed in: run :Copilot auth (copilot.lua) or :Copilot setup (copilot.vim).",
    2
  )
end

--- Read the OAuth token from the new SQLite auth.db.
--- Returns nil on any failure so the caller can fall back gracefully.
---@param db_path string Absolute path to auth.db
---@return string|nil
function H.read_token_from_authdb(db_path)
  -- Preferred: query via sqlite3 CLI
  if vim.fn.executable("sqlite3") == 1 then
    local query = "SELECT cast(token_ciphertext as text) FROM oauth_tokens LIMIT 1;"
    local obj = vim.system({ "sqlite3", "-batch", "-noheader", db_path, query }):wait()
    if obj.code == 0 and obj.stdout then
      local token = vim.trim(obj.stdout):match("^(gh[uco]_[%w_-]+)$")
      if token then return token end
    end
  end

  -- Last resort: scan the raw bytes of the db (and its WAL) for a token
  -- that matches the well-known GitHub OAuth prefix.  This works because
  -- schema_version 0 stores the token as a plaintext BLOB; it will stop
  -- working if/when GitHub encrypts the column for real
  local function scan_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content:match("gh[uco]_[a-zA-Z0-9_%-]+")
  end

  return scan_file(db_path) or scan_file(db_path .. "-wal")
end

--- Read the OAuth token from a legacy hosts.json / apps.json file.
---@param json_path Path
---@return string|nil
function H.read_token_from_json(json_path)
  local ok, data = pcall(vim.json.decode, json_path:read())
  if not ok or type(data) ~= "table" then return nil end

  return vim
    .iter(data)
    :filter(function(k, _) return k:match("github%.com") or k:match("ghe%.com") end)
    :fold({}, function(acc, _, v)
      acc.oauth_token = v.oauth_token
      return acc
    end).oauth_token
end

local function _get_chat_auth_url()
  local ok, provider_conf = pcall(Providers.get_config, "copilot")
  if ok and provider_conf and provider_conf.endpoint then
    local endpoint = provider_conf.endpoint
    local host = endpoint:match("https?://([^/]+)")
    if host and host:match("%.ghe%.com$") then
      -- GHE Cloud: token exchange via api.<tenant>.ghe.com
      local tenant = host:match("^(.+)%.ghe%.com$")
      return "https://api." .. tenant .. ".ghe.com/copilot_internal/v2/token"
    elseif host and not host:match("githubcopilot%.com$") and not host:match("^api%.github%.com$") then
      -- Self-hosted GHES
      return Utils.url_join(endpoint, "/copilot_internal/v2/token")
    end
  end
  return "https://api.github.com/copilot_internal/v2/token"
end
H.chat_auth_url = _get_chat_auth_url()
function H.chat_completion_url(base_url) return Utils.url_join(base_url, "/chat/completions") end
function H.response_url(base_url) return Utils.url_join(base_url, "/responses") end

function H.refresh_token(async, force)
  if not M.state then error("internal initialization error") end

  async = async == nil and true or async
  force = force or false

  -- Do not refresh token if not forced or not expired
  if
    not force
    and M.state.github_token
    and M.state.github_token.expires_at
    and M.state.github_token.expires_at > math.floor(os.time())
  then
    return false
  end

  local provider_conf = Providers.get_config("copilot")

  local curl_opts = {
    headers = {
      ["Authorization"] = "token " .. M.state.oauth_token,
      ["Accept"] = "application/json",
    },
    timeout = provider_conf.timeout,
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
  }

  local function handle_response(response)
    if response.status == 200 then
      M.state.github_token = vim.json.decode(response.body)
      local file = Path:new(copilot_path)
      file:write(vim.json.encode(M.state.github_token), "w")
      if not vim.g.avante_login then vim.g.avante_login = true end

      -- If triggered synchronously, reset timer
      if not async and M._refresh_timer then M.setup_timer() end

      return true
    else
      error("Failed to get success response: " .. vim.inspect(response))
      return false
    end
  end

  if async then
    curl.get(
      H.chat_auth_url,
      vim.tbl_deep_extend("force", {
        callback = handle_response,
      }, curl_opts)
    )
  else
    local response = curl.get(H.chat_auth_url, curl_opts)
    handle_response(response)
  end
end

---@private
---@class AvanteCopilotState
---@field oauth_token string
---@field github_token CopilotToken?
M.state = nil

M.api_key_name = ""
M.tokenizer_id = "gpt-4o"
M.role_map = {
  user = "user",
  assistant = "assistant",
}

function M:is_disable_stream() return false end

setmetatable(M, { __index = OpenAI })

function M:list_models()
  if M._model_list_cache then return M._model_list_cache end
  if not M._is_setup then M.setup() end
  -- refresh token synchronously, only if it has expired
  -- (this should rarely happen, as we refresh the token in the background)
  H.refresh_token(false, false)
  local provider_conf = Providers.parse_config(self)
  local headers = self:build_headers()
  local curl_opts = {
    headers = Utils.tbl_override(headers, self.extra_headers),
    timeout = provider_conf.timeout,
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
  }

  local function handle_response(response)
    if response.status == 200 then
      local body = vim.json.decode(response.body)
      -- ref: https://github.com/CopilotC-Nvim/CopilotChat.nvim/blob/16d897fd43d07e3b54478ccdb2f8a16e4df4f45a/lua/CopilotChat/config/providers.lua#L171-L187
      local models = vim
        .iter(body.data)
        :filter(function(model) return model.capabilities.type == "chat" and not vim.endswith(model.id, "paygo") end)
        :map(
          function(model)
            return {
              id = model.id,
              display_name = model.name,
              name = "copilot/" .. model.name .. " (" .. model.id .. ")",
              provider_name = "copilot",
              tokenizer = model.capabilities.tokenizer,
              max_input_tokens = model.capabilities.limits.max_prompt_tokens,
              max_output_tokens = model.capabilities.limits.max_output_tokens,
              policy = not model["policy"] or model["policy"]["state"] == "enabled",
              version = model.version,
            }
          end
        )
        :totable()
      M._model_list_cache = models
      return models
    else
      error("Failed to get success response: " .. vim.inspect(response))
      return {}
    end
  end

  local response = curl.get((M.state.github_token.endpoints.api or "") .. "/models", curl_opts)
  return handle_response(response)
end

function M:build_headers()
  return {
    ["Authorization"] = "Bearer " .. M.state.github_token.token,
    ["User-Agent"] = "GitHubCopilotChat/0.26.7",
    ["Editor-Version"] = "vscode/1.105.1",
    ["Editor-Plugin-Version"] = "copilot-chat/0.26.7",
    ["Copilot-Integration-Id"] = "vscode-chat",
    ["Openai-Intent"] = "conversation-edits",
  }
end

function M:parse_curl_args(prompt_opts)
  -- refresh token synchronously, only if it has expired
  -- (this should rarely happen, as we refresh the token in the background)
  H.refresh_token(false, false)

  local provider_conf, request_body = Providers.parse_config(self)
  local use_response_api = Providers.resolve_use_response_api(provider_conf, prompt_opts)
  local disable_tools = provider_conf.disable_tools or false

  -- Apply OpenAI's set_allowed_params for Response API compatibility
  OpenAI.set_allowed_params(provider_conf, request_body)

  local use_ReAct_prompt = provider_conf.use_ReAct_prompt == true

  local tools = nil
  if not disable_tools and prompt_opts.tools and not use_ReAct_prompt then
    tools = {}
    for _, tool in ipairs(prompt_opts.tools) do
      local transformed_tool = OpenAI:transform_tool(tool)
      -- Response API uses flattened tool structure
      if use_response_api then
        if transformed_tool.type == "function" and transformed_tool["function"] then
          transformed_tool = {
            type = "function",
            name = transformed_tool["function"].name,
            description = transformed_tool["function"].description,
            parameters = transformed_tool["function"].parameters,
          }
        end
      end
      table.insert(tools, transformed_tool)
    end
  end

  local headers = self:build_headers()

  if prompt_opts.messages and #prompt_opts.messages > 0 then
    local last_message = prompt_opts.messages[#prompt_opts.messages]
    local initiator = last_message.role == "user" and "user" or "agent"
    headers["X-Initiator"] = initiator
  end

  local parsed_messages = self:parse_messages(prompt_opts)

  -- Build base body
  local base_body = {
    model = provider_conf.model,
    stream = true,
    tools = tools,
  }

  -- Response API uses 'input' instead of 'messages'
  -- NOTE: Copilot doesn't support previous_response_id, always send full history
  if use_response_api then
    base_body.input = parsed_messages

    -- Response API uses max_output_tokens instead of max_tokens/max_completion_tokens
    if request_body.max_completion_tokens then
      request_body.max_output_tokens = request_body.max_completion_tokens
      request_body.max_completion_tokens = nil
    end
    if request_body.max_tokens then
      request_body.max_output_tokens = request_body.max_tokens
      request_body.max_tokens = nil
    end
    -- Response API doesn't use stream_options
    base_body.stream_options = nil
    base_body.include = { "reasoning.encrypted_content" }
    base_body.reasoning = {
      summary = "detailed",
    }
    base_body.truncation = "disabled"
  else
    base_body.messages = parsed_messages
    base_body.stream_options = {
      include_usage = true,
    }
  end

  local base_url = M.state.github_token.endpoints.api or provider_conf.endpoint
  local build_url = use_response_api and H.response_url or H.chat_completion_url

  return {
    url = build_url(base_url),
    timeout = provider_conf.timeout,
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = vim.tbl_deep_extend("force", base_body, request_body),
  }
end

M._refresh_timer = nil

function M.setup_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
  end

  -- Calculate time until token expires
  local now = math.floor(os.time())
  local expires_at = M.state.github_token and M.state.github_token.expires_at or now
  local time_until_expiry = math.max(0, expires_at - now)
  -- Refresh 2 minutes before expiration
  local initial_interval = math.max(0, (time_until_expiry - 120) * 1000)
  -- Regular interval of 28 minutes after the first refresh
  local repeat_interval = 28 * 60 * 1000

  M._refresh_timer = vim.uv.new_timer()
  M._refresh_timer:start(
    initial_interval,
    repeat_interval,
    vim.schedule_wrap(function() H.refresh_token(true, true) end)
  )
end

function M.setup_file_watcher()
  if M._file_watcher then return end

  local copilot_token_file = Path:new(copilot_path)
  M._file_watcher = vim.uv.new_fs_event()

  M._file_watcher:start(
    copilot_path,
    {},
    vim.schedule_wrap(function()
      -- Reload token from file
      if copilot_token_file:exists() then
        local ok, token = pcall(vim.json.decode, copilot_token_file:read())
        if ok then M.state.github_token = token end
      end
    end)
  )
end

M._is_setup = false

function M.is_env_set()
  local ok = pcall(function() H.get_oauth_token() end)
  return ok
end

function M.setup()
  local copilot_token_file = Path:new(copilot_path)

  if not M.state then M.state = {
    github_token = nil,
    oauth_token = H.get_oauth_token(),
  } end

  -- Load and validate existing token
  if copilot_token_file:exists() then
    local ok, token = pcall(vim.json.decode, copilot_token_file:read())
    if ok and token.expires_at and token.expires_at > math.floor(os.time()) then M.state.github_token = token end
  end

  -- Setup timer management
  local timer_lock_acquired = try_acquire_timer_lock()
  if timer_lock_acquired then
    M.setup_timer()
  else
    vim.schedule(function() H.refresh_token(true, false) end)
  end

  M.setup_file_watcher()

  start_manager_check_timer()

  require("avante.tokenizers").setup(M.tokenizer_id)
  vim.g.avante_login = true
  M._is_setup = true
end

function M.cleanup()
  -- Cleanup refresh timer
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil

    -- Remove lockfile if we were the manager
    local lockfile = Path:new(lockfile_path)
    if lockfile:exists() then
      local content = lockfile:read()
      local pid = tonumber(content)
      if pid and pid == vim.fn.getpid() then vim.fs.rm(tostring(lockfile)) end
    end
  end

  -- Cleanup manager check timer
  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
    M._manager_check_timer = nil
  end

  -- Cleanup file watcher
  if M._file_watcher then
    ---@diagnostic disable-next-line: param-type-mismatch
    M._file_watcher:stop()
    M._file_watcher = nil
  end
end

-- Register cleanup on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() M.cleanup() end,
})

return M
