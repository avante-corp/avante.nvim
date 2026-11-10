---@mod avante-providers-openai OpenAI provider
---
---@brief [[
---Set `providers.openai.auth_type = "subscription"` to use ChatGPT
---subscription OAuth, then run `:Avante chatgpt login`. Omit `auth_type` or set
---it to `"api_key"` for API-key authentication. Avante uses a browser in a graphical
---session or a device code over SSH. `:Avante chatgpt logout` revokes and removes
---saved credentials; the normal cancel action stops a pending login.
---<
---   require("avante").setup({
---     provider = "openai",
---     providers = {
---       openai = {
---         auth_type = "subscription",
---         model = "gpt-6.1-sol",
---       },
---     },
---   })
--->
---
---Credentials remain in `stdpath("data")/avante/chatgpt/` and refresh automatically.
---Requests use the fixed ChatGPT Codex HTTPS endpoint and full conversation
---history. Custom endpoints, headers, API keys, provider-level proxies, insecure
---TLS and stored-response continuation are unsupported. Set `auth_type`
---explicitly on inherited subscription providers. The model picker lists a
---bundled catalog, which does not guarantee model access for your account.
---@brief ]]

local Config = require("avante.config")
local Providers = require("avante.providers")
local Utils = require("avante.utils")

local M = {}

M.api_key_name = "OPENAI_API_KEY"

---Asking remote provider to list available models
---@param timeout? integer Timeout in milliseconds
---@return AvanteProviderModelList
function M:list_models(timeout)
  if self == nil or self == M then
    local ok, provider = pcall(function() return Providers[Config.provider] end)
    if not ok or provider.list_models ~= M.list_models then provider = Providers.openai end
    self = provider
  end
  if self.auth_type == "subscription" then return require("avante.libs.rig_client").chatgpt_models() end
  Utils.info("Asking remote for available models")
  if self._model_list_cache then return self._model_list_cache end

  local provider_conf = Providers.parse_config(self)
  if not provider_conf.endpoint then
    Utils.error("OpenAI-compatible provider requires endpoint configuration")
    return {}
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if Providers.env.require_api_key(provider_conf) then
    local api_key = self.parse_api_key()
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return {}
    end
    headers["Authorization"] = "Bearer " .. api_key
  end

  local curl = require("avante.utils.curl")
  local response = curl.get(Utils.url_join(provider_conf.endpoint, "/models"), {
    headers = Utils.tbl_override(headers, self.extra_headers),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    timeout = timeout,
  })
  if response.status ~= 200 then
    Utils.error("Failed to fetch OpenAI-compatible models: " .. (response.body or response.status))
    return {}
  end

  local ok, body = pcall(vim.json.decode, response.body)
  if not ok or type(body) ~= "table" or type(body.data) ~= "table" then
    Utils.error("Failed to parse OpenAI-compatible model list response")
    return {}
  end
  local models = vim
    .iter(body.data)
    :filter(function(model) return type(model) == "table" and type(model.id) == "string" end)
    :map(
      ---@param model {id: string, created?: integer, owned_by?: string}
      ---@return AvanteProviderModel
      function(model)
        return {
          id = model.id,
          name = model.id,
          display_name = model.id,
          version = tostring(model.created or model.owned_by or ""),
        }
      end
    )
    :totable()
  self._model_list_cache = models
  return models
end

return M
