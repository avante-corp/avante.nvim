---@mod avante-providers-claude Anthropic provider
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
