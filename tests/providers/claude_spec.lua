local Claude = require("avante.providers.claude")

describe("Claude provider", function()
  it(
    "does not delay requests while the token budget is healthy",
    function()
      assert.is_nil(Claude:get_rate_limit_sleep_time({
        ["anthropic-ratelimit-tokens-remaining"] = "10001",
      }))
    end
  )
end)
