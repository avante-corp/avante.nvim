---@mod avante-providers-claude Anthropic provider
---
---@brief [[
---Set `providers.claude.auth_type = "subscription"` to use a Claude Pro or Max
---subscription on Linux or macOS. Rebuild the native libraries, then run
---`:Avante claude login`; use `:Avante claude logout` to remove the saved
---credentials. Omit `auth_type` or set it to `"api_key"` for API-key
---authentication.
---<
---   require("avante").setup({
---     provider = "claude",
---     providers = {
---       claude = {
---         auth_type = "subscription",
---         model = "claude-sonnet-5-5",
---       },
---     },
---   })
--->
---Login opens a browser and receives the OAuth callback on localhost. The normal
---cancel action stops a pending login. Credentials remain in
---`stdpath("data")/avante/claude-cloak/anthropic-oauth/` and refresh
---automatically; credentials from older Avante versions are not imported.
---
---Subscription requests use a fixed Anthropic HTTPS endpoint. Custom endpoints,
---headers, API keys, provider-level proxies and insecure TLS are unsupported.
---@brief ]]

local Utils = require("avante.utils")

local M = {}

M.api_key_name = "ANTHROPIC_API_KEY"
M.support_prompt_caching = true
M.tokenizer_id = "gpt-4o"

---@param headers table<string, string>
---@return integer|nil
function M:get_rate_limit_sleep_time(headers)
  local remaining_tokens = tonumber(headers["anthropic-ratelimit-tokens-remaining"])
  if remaining_tokens == nil or remaining_tokens > 10000 then return end
  local reset_dt_str = headers["anthropic-ratelimit-tokens-reset"]
  if remaining_tokens ~= 0 then reset_dt_str = reset_dt_str or headers["anthropic-ratelimit-requests-reset"] end
  local reset_dt, err = Utils.parse_iso8601_date(reset_dt_str)
  if err then
    Utils.warn(err)
    return
  end
  return Utils.datetime_diff(tostring(Utils.utc_now()), tostring(reset_dt))
end

return M
