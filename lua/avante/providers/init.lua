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
--- - `watsonx_code_assistant`
--- - `mistral`
--- - ...
--- Please refer to the provider's help section under the tag avante-providers-NAME
---@brief ]]

local api = vim.api

local Config = require("avante.config")
local Utils = require("avante.utils")

---@class avante.Providers
---@field azure AvanteProviderFunctor
---@field bedrock AvanteBedrockProviderFunctor
---@field claude AvanteClaudeProviderFunctor
---@field cohere AvanteProviderFunctor
---@field copilot AvanteProviderFunctor
---@field gemini AvanteProviderFunctor
---@field mistral AvanteProviderFunctor
---@field ollama AvanteProviderFunctor
---@field openai AvanteProviderFunctor
---@field vertex_claude AvanteProviderFunctor
---@field watsonx_code_assistant AvanteProviderFunctor
local M = {}

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
---@private
function E.setup(opts)
  opts.provider.setup()

  local var = opts.provider.api_key_name

  if var == nil or var == "" then
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
function E.require_api_key(provider) return provider.api_key_name ~= nil and provider.api_key_name ~= "" end

M.env = E

M = setmetatable(M, {
  ---@param t avante.Providers
  ---@param k avante.ProviderName
  __index = function(t, k)
    if Config.providers[k] == nil then error("Failed to find provider: " .. k, 2) end

    local provider_config = M.get_config(k)

    if provider_config.__inherited_from ~= nil then
      local base_provider_config = M.get_config(provider_config.__inherited_from)
      local ok, module = pcall(require, "avante.providers." .. provider_config.__inherited_from)
      if not ok then error("Failed to load provider: " .. provider_config.__inherited_from, 2) end
      provider_config = Utils.deep_extend_with_metatable("force", module, base_provider_config, provider_config)
    else
      local ok, module = pcall(require, "avante.providers." .. k)
      if ok then
        provider_config = Utils.deep_extend_with_metatable("force", module, provider_config)
      elseif provider_config.parse_curl_args == nil then
        error(
          string.format(
            'The configuration of your provider "%s" is incorrect, missing the `__inherited_from` attribute or a custom `parse_curl_args` function. Please fix your provider configuration. For more details, see: https://github.com/yetone/avante.nvim/wiki/Custom-providers',
            k
          )
        )
      end
    end

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
        if E.require_api_key(provider_conf) then
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

  if Config.acp_providers[Config.provider] then return end

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
  require("avante.config").override({ provider = provider_name })

  if Config.acp_providers[provider_name] then
    Config.provider = provider_name
  else
    ---@type AvanteProviderFunctor | AvanteBedrockProviderFunctor
    local p = M[Config.provider]
    E.setup({ provider = p, refresh = true })
  end
  local sidebar = require("avante").get()
  if sidebar and sidebar:is_open() then sidebar:render_result() end
  Utils.info("Switch to provider: " .. provider_name, { once = true, title = "Avante" })

  local provider = Providers[provider_name]
  local provider_model = provider and provider.model

  Config.save_last_model(provider_model, provider_name)
end

---@param opts AvanteProvider | AvanteSupportedProvider | AvanteAnthropicProvider | AvanteProviderFunctor | AvanteBedrockProviderFunctor
---@return AvanteDefaultBaseProvider provider_opts
---@return table<string, any> request_body
function M.parse_config(opts)
  local provider_opts = {}

  for key, value in pairs(opts) do
    if key ~= "extra_request_body" then provider_opts[key] = value end
  end

  ---@type table<string, any>
  local request_body = opts.extra_request_body or {}

  return provider_opts, request_body
end

---@param provider_conf table | nil
---@param ctx any
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

---@param provider_name avante.ProviderName
function M.get_config(provider_name)
  provider_name = provider_name or Config.provider
  local cur = Config.get_provider_config(provider_name)
  return type(cur) == "function" and cur() or cur
end

function M.get_memory_summary_provider()
  local provider_name = Config.memory_summary_provider
  if provider_name == nil then provider_name = Config.provider end
  return M[provider_name]
end

return M
