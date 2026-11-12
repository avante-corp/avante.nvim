---@mod avante-providers Model providers
---@brief [[
--- Avante ships with default providers and supports custom providers.
---
--- Common provider names include:
---
--- - `claude`
--- - `openai`
--- - `azure`
--- - `gemini`
--- - `vertex`
--- - `cohere`
--- - `copilot`
--- - `bedrock`
--- - `ollama`
--- - `mistral`
--- - ...
--- Please refer to the provider's help section under the tag avante-providers-NAME
---
--- Custom providers ~
---
--- Custom providers inherit another provider's configuration and implementation:
--->lua
---   require("avante").setup({
---     provider = "openai_high",
---     providers = {
---       openai_medium = {
---         __inherited_from = "openai",
---         extra_request_body = { reasoning_effort = "medium" },
---       },
---
---       openai_high = {
---         __inherited_from = "openai_medium",
---         model = "gpt-6.1-sol",
---         extra_request_body = { reasoning_effort = "high" },
---       },
---
---       chatgpt_high = {
---         __inherited_from = "openai_high",
---         auth_type = "subscription",
---       },
---     },
---   })
---<
---
--- Set `OPENAI_API_KEY` in your environment.
---
--- Both API-key providers inherit the OpenAI endpoint, API key name and dialect,
--- using the OpenAI protocol. `openai_high` sets reasoning effort to `high`
--- while retaining the other request fields.
---
--- Inheritance rules:
---
--- - Child fields override the parent's fields; request-body tables are
---   deep-merged.
--- - Inheritance chains are resolved recursively and must end at a built-in
---   provider. Missing parents and circular inheritance raise errors.
--- - Each provider's `__inherited_from` keeps its direct parent's name.
---
--- OpenAI-compatible providers inherit shared defaults from `providers.openai`.
--- Built-in provider names retain their dialect throughout custom inheritance
--- chains; provider-specific fields override the shared defaults.
---
--- Authentication:
---
--- ChatGPT subscriptions require an explicit `auth_type = "subscription"` on
--- each child provider. Set `provider = "chatgpt_high"` in the configuration above to
--- use the subscription configuration.
---
--- Run `:Avante chatgpt login` before the first subscription request.
--- The subscription provider does not require an OpenAI API key.
--- See |avante-providers-openai| for subscription setup.
---@brief ]]

local api = vim.api

local Config = require("avante.config")
local Utils = require("avante.utils")

---@class avante.Providers
---@field [string] AvanteProviderFunctor
---@field azure AvanteProviderFunctor
---@field bedrock AvanteBedrockProviderFunctor
---@field claude AvanteClaudeProviderFunctor
---@field cohere AvanteProviderFunctor
---@field copilot AvanteProviderFunctor
---@field gemini AvanteProviderFunctor
---@field mistral AvanteProviderFunctor
---@field ollama AvanteProviderFunctor
---@field openai AvanteProviderFunctor
local M = {}

local provider_protocols = {
  openai = "openai",
  claude = "claude",
  azure = "azure",
  gemini = "gemini",
  vertex = "vertex",
  cohere = "cohere",
  ollama = "ollama",
  bedrock = "bedrock",
  copilot = "copilot",
}

local openai_dialects = {
  deepseek = true,
  openrouter = true,
  moonshot = true,
  xai = true,
  zai = true,
  mistral = true,
}

---@class EnvironmentHandler
local E = {}

---@private
---@type table<string, string>
E.cache = {}

---@param Opts AvanteSupportedProvider | AvanteProviderFunctor | AvanteBedrockProviderFunctor
---@return string | nil
function E.parse_envvar(Opts)
  -- First try the scoped version (e.g., AVANTE_ANTHROPIC_API_KEY)
  local scoped_key_name = nil
  if Opts.api_key_name and type(Opts.api_key_name) == "string" and Opts.api_key_name ~= "" then
    -- Only add AVANTE_ prefix if it's a regular environment variable (not a cmd: or already prefixed)
    if not Opts.api_key_name:match("^cmd:") and not Opts.api_key_name:match("^AVANTE_") then
      scoped_key_name = "AVANTE_" .. Opts.api_key_name
    end
  end

  -- Try scoped key first if available
  if scoped_key_name then
    local scoped_value = Utils.environment.parse(scoped_key_name, Opts._shellenv)
    if scoped_value ~= nil then
      vim.g.avante_login = true
      return scoped_value
    end
  end

  -- Fall back to the original global key
  local value = Utils.environment.parse(Opts.api_key_name, Opts._shellenv)
  if value ~= nil then
    vim.g.avante_login = true
    return value
  end

  return nil
end

--- initialize the environment variable for current neovim session.
--- This will only run once and spawn a UI for users to input the envvar.
---@param opts {refresh: boolean, provider: AvanteProviderFunctor | AvanteBedrockProviderFunctor}
---@return nil
---@private
function E.setup(opts)
  opts.provider.setup()

  local var = opts.provider.api_key_name

  if not E.require_api_key(opts.provider) then
    vim.g.avante_login = true
    return
  end

  if type(var) ~= "table" and vim.env[var] ~= nil then
    vim.g.avante_login = true
    return
  end

  -- check if var is a all caps string
  if type(var) == "table" or var:match("^cmd:(.*)") then return end

  local refresh = opts.refresh or false

  ---@param value string
  ---@return nil
  local function on_confirm(value)
    if value then
      vim.fn.setenv(var, value)
      vim.g.avante_login = true
    else
      if not opts.provider.is_env_set() then
        Utils.warn("Failed to set " .. var .. ". Avante won't work as expected", { once = true })
      end
    end
  end

  local function mount_input_ui()
    vim.defer_fn(function()
      -- only mount if given buffer is not of buftype ministarter, dashboard, alpha, qf
      local exclude_filetypes = {
        "NvimTree",
        "Outline",
        "help",
        "dashboard",
        "alpha",
        "qf",
        "ministarter",
        "TelescopePrompt",
        "gitcommit",
        "gitrebase",
        "DressingInput",
        "snacks_input",
        "noice",
      }

      if not vim.tbl_contains(exclude_filetypes, vim.bo.filetype) and not opts.provider.is_env_set() then
        local Input = require("avante.ui.input")
        local input = Input:new({
          provider = Config.input.provider,
          title = "Enter " .. var .. ": ",
          default = "",
          conceal = true, -- Password input should be concealed
          provider_opts = Config.input.provider_opts,
          on_submit = on_confirm,
        })
        input:open()
      end
    end, 200)
  end

  if refresh then return mount_input_ui() end

  api.nvim_create_autocmd("User", {
    pattern = E.REQUEST_LOGIN_PATTERN,
    callback = mount_input_ui,
  })
end

E.REQUEST_LOGIN_PATTERN = "AvanteRequestLogin"

---@param provider AvanteDefaultBaseProvider
---@return boolean
function E.require_api_key(provider)
  local protocol = provider._protocol
  if protocol == "copilot" then return false end
  if protocol == "claude" and provider.auth_type == "subscription" then return false end
  if protocol == "openai" and provider.auth_type == "subscription" then return false end
  return provider.api_key_name ~= nil and provider.api_key_name ~= ""
end

M.env = E

---@param name string
---@param visiting table<string, boolean>
---@return AvanteSupportedProvider config
---@return AvanteNativeLLMProtocol protocol
---@return string dialect
local function resolve_config(name, visiting)
  if visiting[name] then error("Circular provider inheritance: " .. name, 2) end
  visiting[name] = true
  local config = M.get_config(name)
  local parent = config.__inherited_from
  ---@type AvanteNativeLLMProtocol, string
  local protocol, dialect
  if parent then
    local base
    base, protocol, dialect = resolve_config(parent, visiting)
    local auth_type = config.auth_type
    config = vim.tbl_deep_extend("force", base, config)
    -- OpenAI-compatible providers must opt in to ChatGPT subscriptions independently.
    if protocol == "openai" and base.auth_type == "subscription" then config.auth_type = auth_type end
  else
    dialect = name
    protocol = provider_protocols[name]
    if not protocol then
      error(
        string.format(
          'The configuration of provider "%s" must set `__inherited_from`. See: https://github.com/avante-corp/avante.nvim/wiki/Custom-providers',
          name
        )
      )
    end
  end
  if protocol == "openai" and openai_dialects[name] then dialect = name end
  return config, protocol, dialect
end

M = setmetatable(M, {
  ---@param t table<string, AvanteProviderFunctor>
  ---@param k avante.ProviderName
  ---@return AvanteProviderFunctor | AvanteBedrockProviderFunctor
  __index = function(t, k)
    local provider_config, protocol, dialect = resolve_config(k, {})
    ---@type AvanteDefaultBaseProvider
    local module = require("avante.providers." .. protocol)
    provider_config = vim.tbl_deep_extend("force", module, provider_config)
    local auth_type = provider_config.auth_type or (protocol == "copilot" and "subscription" or "api_key")
    if
      (auth_type ~= "api_key" and auth_type ~= "subscription")
      or (auth_type == "subscription" and protocol ~= "claude" and protocol ~= "openai" and protocol ~= "copilot")
      or (auth_type == "api_key" and protocol == "copilot")
    then
      error(string.format('Provider "%s" does not support auth_type "%s"', k, tostring(auth_type)), 2)
    end
    provider_config.auth_type = auth_type
    provider_config._name = k
    provider_config._protocol = protocol
    provider_config._dialect = protocol == "openai" and dialect or nil
    ---@cast provider_config AvanteProviderFunctor
    t[k] = provider_config

    if rawget(t[k], "parse_api_key") == nil then t[k].parse_api_key = function() return E.parse_envvar(t[k]) end end

    -- default to gpt-4o as tokenizer
    if t[k].tokenizer_id == nil then t[k].tokenizer_id = "gpt-4o" end

    if rawget(t[k], "is_env_set") == nil then
      t[k].is_env_set = function()
        if not E.require_api_key(t[k]) then return true end
        if type(t[k].api_key_name) == "string" and t[k].api_key_name:match("^cmd:") then return true end
        local ok, result = pcall(t[k].parse_api_key)
        if not ok then return false end
        return result ~= nil
      end
    end

    if rawget(t[k], "setup") == nil then
      local provider_conf = M.parse_config(t[k])
      t[k].setup = function()
        if E.require_api_key(t[k]) then
          if not (type(provider_conf.api_key_name) == "string" and provider_conf.api_key_name:match("^cmd:")) then
            t[k].parse_api_key()
          end
        end
        require("avante.tokenizers").setup(t[k].tokenizer_id)
      end
    end

    return t[k]
  end,
})

function M.setup()
  vim.g.avante_login = false

  if require("avante.api").is_acp_provider() then return end

  ---@type AvanteProviderFunctor | AvanteBedrockProviderFunctor
  local provider = M[Config.provider]

  E.setup({ provider = provider })

  if Config.auto_suggestions_provider then
    local auto_suggestions_provider = M[Config.auto_suggestions_provider]
    if auto_suggestions_provider and auto_suggestions_provider ~= provider then
      E.setup({ provider = auto_suggestions_provider })
    end
  end

  if Config.memory_summary_provider then
    local memory_summary_provider = M[Config.memory_summary_provider]
    if memory_summary_provider and memory_summary_provider ~= provider then
      E.setup({ provider = memory_summary_provider })
    end
  end
end

---@param provider_name avante.ProviderName
function M.refresh(provider_name)
  local sidebar = require("avante").get()
  if sidebar and sidebar.is_generating then
    Utils.warn("Cannot switch providers during generation", { title = "Avante" })
    return
  end

  local provider_changed = Config.provider ~= provider_name
  require("avante.config").override({ provider = provider_name })

  if not require("avante.api").is_acp_provider() then
    ---@type AvanteProviderFunctor | AvanteBedrockProviderFunctor
    local p = M[Config.provider]
    E.setup({ provider = p, refresh = true })
  end
  if sidebar and sidebar:is_open() then
    if provider_changed then
      sidebar:reset_chat_history()
    else
      sidebar:render_result_header()
    end
  end
  Utils.info("Switch to provider: " .. provider_name, { once = true, title = "Avante" })
end

---@param opts AvanteProvider | AvanteSupportedProvider | AvanteProviderFunctor | AvanteBedrockProviderFunctor
---@return AvanteDefaultBaseProvider provider_opts
---@return table<string, any> request_body
function M.parse_config(opts)
  ---@type table<string, any>
  local provider_opts = {}

  ---@type table<string, any>
  local config = opts
  for key, value in pairs(config) do
    if key ~= "extra_request_body" and key ~= "_name" and key ~= "_protocol" and key ~= "_dialect" then
      provider_opts[key] = value
    end
  end

  ---@type table<string, any>
  local request_body = opts.extra_request_body or {}

  return provider_opts, --[[@as AvanteDefaultBaseProvider]]
    request_body
end

---@param provider_conf AvanteDefaultBaseProvider | nil
---@param ctx? AvantePromptOptions
---@return boolean
function M.resolve_use_response_api(provider_conf, ctx)
  if not provider_conf then return false end
  local value = provider_conf.use_response_api
  if type(value) ~= "function" then value = provider_conf._use_response_api_resolver or value end
  if type(value) == "function" then
    provider_conf._use_response_api_resolver = value
    local ok, result = pcall(value, provider_conf, ctx)
    if not ok then error("Failed to evaluate use_response_api: " .. result, 2) end
    return result == true
  end
  return value == true
end

---@param provider_conf AvanteDefaultBaseProvider | nil
---@param ctx? AvantePromptOptions
---@param protocol? AvanteNativeLLMProtocol
---@return "chat" | "responses" | nil
function M.resolve_api_route(provider_conf, ctx, protocol)
  if not provider_conf then return nil end
  protocol = protocol or provider_conf._protocol
  if protocol ~= "openai" and protocol ~= "azure" and protocol ~= "copilot" then return nil end
  return M.resolve_use_response_api(provider_conf, ctx) and "responses" or "chat"
end

---@param provider_name avante.ProviderName
---@return AvanteSupportedProvider
function M.get_config(provider_name) return Config.get_provider_config(provider_name or Config.provider) end

---@return AvanteProviderFunctor | AvanteBedrockProviderFunctor
function M.get_memory_summary_provider()
  local provider_name = Config.memory_summary_provider
  if provider_name == nil then provider_name = Config.provider end
  return M[provider_name]
end

return M
