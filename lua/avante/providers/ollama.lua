---@mod avante-providers-ollama Ollama provider
---Ollama is disabled by default. Configure its endpoint check to enable it:
--->lua
---   require("avante").setup({
---     provider = "ollama",
---     providers = {
---       ollama = {
---         model = "qwq:32b",
---         is_env_set = require("avante.providers.ollama").check_endpoint_alive,
---       },
---     },
---   })
---<
local Providers = require("avante.providers")
local Utils = require("avante.utils")

local M = {}

M.api_key_name = ""

---Ollama is disabled until users opt into checking or trusting their endpoint.
function M.is_env_set() return false end

local curl_errors = {
  [1] = "Unsupported protocol",
  [3] = "URL malformed",
  [5] = "Could not resolve proxy",
  [6] = "Could not resolve host",
  [7] = "Failed to connect to host",
  [23] = "Failed writing received data to disk",
  [28] = "Operation timed out",
  [35] = "SSL/TLS connection error",
  [47] = "Too many redirects",
  [52] = "Server returned empty response",
  [56] = "Failure in receiving network data",
  [60] = "Peer certificate cannot be authenticated with known CA certificates (SSL cert issue)",
}

---@param opts AvanteProviderFunctor
---@param timeout? integer
---@return table[]|nil, string|nil
local function query_models(opts, timeout)
  local provider_conf = Providers.parse_config(opts)
  if not provider_conf.endpoint then return nil, "Ollama requires endpoint configuration" end

  local response = {}
  local job = require("avante.utils.curl").get(Utils.url_join(provider_conf.endpoint, "/api/tags"), {
    headers = Utils.tbl_override({
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
    }, opts.extra_headers),
    callback = function(output) response = output end,
    on_error = function(err) response = { exit = err.exit } end,
  })
  local job_ok, err = pcall(job.wait, job, timeout or 10000)
  if not job_ok then
    return nil, "Ollama: curl command invocation failed: " .. err
  elseif response.exit ~= 0 then
    return nil, "Ollama: " .. (curl_errors[response.exit] or ("curl returned error: " .. response.exit))
  elseif response.status ~= 200 then
    return nil, "Failed to fetch Ollama models: " .. (response.body or response.status)
  end

  local ok, body = pcall(vim.json.decode, response.body)
  if not ok then return nil, "Failed to parse model list query response" end
  return body.models or {}
end

---@param timeout? integer
function M:list_models(timeout)
  if self._model_list_cache then return self._model_list_cache end
  local result, err = query_models(self, timeout)
  if not result then
    Utils.error(assert(err))
    return {}
  end

  local models = {}
  for _, model in ipairs(result) do
    local details = model.details or {}
    local display = {}
    for _, key in ipairs({ "family", "parameter_size", "quantization_level" }) do
      if details[key] then display[#display + 1] = details[key] end
    end
    models[#models + 1] = {
      id = model.name,
      name = string.format("ollama/%s (%s)", model.name, table.concat(display, ", ")),
      display_name = model.name,
      provider_name = "ollama",
      version = model.digest,
    }
  end
  self._model_list_cache = models
  return models
end

function M.check_endpoint_alive()
  local result = query_models(Providers.ollama, 1000)
  return result ~= nil
end

return M
