---@mod avante-providers-openai OpenAI provider
local Config = require("avante.config")
local Providers = require("avante.providers")
local Utils = require("avante.utils")

local M = {}

M.api_key_name = "OPENAI_API_KEY"

---Asking remote provider to list available models
---@param timeout? integer Timeout in milliseconds
---@return AvanteProviderModelList
function M:list_models(timeout)
  Utils.info("Asking remote for available models")
  if self == nil or self == M then
    local ok, provider = pcall(function() return Providers[Config.provider] end)
    if not ok or provider.list_models ~= M.list_models then provider = Providers.openai end
    self = provider
  end
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
