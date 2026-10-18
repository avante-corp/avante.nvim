local Config = require("avante.config")
Config.setup({})

local Gemini = require("avante.providers.gemini")

describe("gemini provider", function()
  describe("parse_curl_args", function()
    it("sends the API key in a header rather than in the URL", function()
      local provider = setmetatable({
        endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
        model = "gemini-test",
        parse_api_key = function() return "gm-test-SECRET123" end,
      }, { __index = Gemini })

      local spec = provider:parse_curl_args({ system_prompt = "", messages = { { role = "user", content = "hi" } } })

      assert.equals(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent?alt=sse",
        spec.url
      )
      assert.equals("gm-test-SECRET123", spec.headers["x-goog-api-key"])
    end)
  end)
end)
