---@diagnostic disable: duplicate-set-field
local Config = require("avante.config")
Config.setup({})

describe("openai provider with ChatGPT sign in", function()
  local openai
  local Providers
  local OpenAIAuth
  local original_parse_config
  local original_get_headers
  local original_last_response_id

  local function curl_args()
    return openai:parse_curl_args({
      system_prompt = "system prompt",
      messages = { { role = "user", content = "hi" } },
    })
  end

  before_each(function()
    Providers = require("avante.providers")
    OpenAIAuth = require("avante.auth.providers.openai")
    openai = require("avante.providers.openai")
    original_parse_config = Providers.parse_config
    original_get_headers = OpenAIAuth.get_headers
    original_last_response_id = openai.last_response_id
    openai.last_response_id = nil
    Providers.parse_config = function()
      return {
        auth_type = "chatgpt",
        model = "gpt-5.5",
        endpoint = "https://example.com/v1",
        support_previous_response_id = true,
      }, {
        temperature = 0.75,
        max_completion_tokens = 16384,
        reasoning_effort = "medium",
        prompt_cache_retention = "24h",
        stream = false,
        previous_response_id = "configured-response",
      }
    end
    OpenAIAuth.get_headers = function() return { Authorization = "Bearer token" } end
  end)

  after_each(function()
    Providers.parse_config = original_parse_config
    OpenAIAuth.get_headers = original_get_headers
    openai.last_response_id = original_last_response_id
    OpenAIAuth.state = { openai_token = nil }
  end)

  it("sends Sign in with ChatGPT tokens to the OpenAI Responses API", function()
    local args = curl_args()

    assert.equals("https://api.openai.com/v1/responses", args.url)
    assert.is_false(args.body.store)
    assert.is_true(args.body.stream)
    assert.equals("Bearer token", args.headers.Authorization)
    assert.is_nil(args.body.temperature)
    assert.is_nil(args.body.max_output_tokens)
    assert.is_nil(args.body.prompt_cache_retention)
    assert.is_nil(args.body.instructions)
    assert.is_nil(args.body.previous_response_id)
    assert.is_true(vim.tbl_contains(args.body.include, "reasoning.encrypted_content"))
    assert.equals("developer", args.body.input[1].role)
    assert.equals("system prompt", args.body.input[1].content)
  end)

  it("replays encrypted reasoning and tool history without stored responses", function()
    openai:parse_response(
      {},
      vim.json.encode({ type = "response.completed", response = { id = "old-response" } }),
      "response.completed",
      { on_stop = function() end }
    )
    local prompt_opts = {
      system_prompt = "system prompt",
      session_ctx = {
        last_response_id = "old-response",
        last_response_model = "gpt-5.5",
        last_response_auth_type = "chatgpt",
      },
      messages = {
        { role = "user", content = "Read a file" },
        { role = "assistant", content = { type = "reasoning", id = "old-reasoning" } },
        {
          role = "assistant",
          content = { type = "reasoning", id = "rs_first", encrypted_content = "first-ciphertext", summary = {} },
        },
        {
          role = "assistant",
          content = {
            { type = "reasoning", id = "rs_second", encrypted_content = "second-ciphertext", summary = {} },
            { type = "tool_use", id = "call-1", name = "read_file", input = { path = "example.lua" } },
          },
        },
        { role = "user", content = { { type = "tool_result", tool_use_id = "call-1", content = "file contents" } } },
      },
    }
    local args = openai:parse_curl_args(prompt_opts)
    local call, result, reasoning = nil, nil, {}
    for _, item in ipairs(args.body.input) do
      if item.type == "reasoning" then table.insert(reasoning, item) end
      if item.type == "function_call" then call = item end
      if item.type == "function_call_output" then result = item end
    end
    assert.equals("call-1", call.call_id)
    assert.equals(call.call_id, result.call_id)
    assert.equals("file contents", result.output)
    assert.same({
      { type = "reasoning", id = "rs_first", encrypted_content = "first-ciphertext", summary = {} },
      { type = "reasoning", id = "rs_second", encrypted_content = "second-ciphertext", summary = {} },
    }, reasoning)
    assert.is_nil(args.body.previous_response_id)

    prompt_opts.session_ctx = nil
    local without_session = openai:parse_curl_args(prompt_opts)
    assert.is_nil(without_session.body.previous_response_id)
    assert.same(args.body.input, without_session.body.input)
  end)

  it("chains API tool results only within the matching session", function()
    Providers.parse_config = function()
      return {
        auth_type = "api",
        model = "gpt-4o",
        endpoint = "https://api.openai.com/v1",
        use_response_api = true,
        support_previous_response_id = true,
      }, { temperature = 0.75 }
    end
    local prompt_opts = {
      system_prompt = "system prompt",
      messages = {
        { role = "user", content = "Read a file" },
        {
          role = "assistant",
          content = { { type = "tool_use", id = "call-1", name = "read_file", input = {} } },
        },
        { role = "user", content = { { type = "tool_result", tool_use_id = "call-1", content = "contents" } } },
      },
      session_ctx = {
        last_response_id = "session-response",
        last_response_model = "gpt-4o",
        last_response_auth_type = "api",
      },
    }
    local args = openai:parse_curl_args(prompt_opts)
    assert.equals("session-response", args.body.previous_response_id)
    assert.equals("function_call_output", args.body.input[1].type)
    assert.equals(1, #args.body.input)
    assert.equals(0.75, args.body.temperature)

    openai.last_response_id = "another-session-response"
    for _, session in ipairs({
      { last_response_id = "old-model-response", last_response_model = "gpt-5.5", last_response_auth_type = "api" },
      { last_response_id = "old-auth-response", last_response_model = "gpt-4o", last_response_auth_type = "chatgpt" },
      false,
    }) do
      prompt_opts.session_ctx = session or nil
      args = openai:parse_curl_args(prompt_opts)
      assert.is_nil(args.body.previous_response_id)
      assert.same(
        { "system", "user", "function_call", "function_call_output" },
        vim.tbl_map(function(item) return item.type or item.role end, args.body.input)
      )
    end
  end)
end)

describe("ChatGPT usage limit", function()
  local openai = require("avante.providers.openai")
  local usage_limit_error = {
    code = "subscription_sharing_usage_limit_exceeded",
    message = "Usage limit reached.",
    type = "rate_limit_error",
  }

  it("recognizes the usage limit in an HTTP error body", function()
    local message = openai:get_usage_limit_error(vim.json.encode({ error = usage_limit_error }))

    assert.equals(
      "subscription_sharing_usage_limit_exceeded: Usage limit reached.\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage",
      message
    )
  end)

  it("ignores other errors", function()
    assert.is_nil(openai:get_usage_limit_error(vim.json.encode({ error = { code = "rate_limit_exceeded" } })))
    assert.is_nil(openai:get_usage_limit_error("not json"))
    assert.is_nil(openai:get_usage_limit_error(nil))
  end)

  it("stops when the stream fails with the usage limit", function()
    local stop_opts
    openai:parse_response(
      {},
      vim.json.encode({
        type = "response.failed",
        response = { id = "resp_failed", status = "failed", error = usage_limit_error },
      }),
      "response.failed",
      { on_stop = function(o) stop_opts = o end }
    )

    assert.equals("error", stop_opts.reason)
    assert.is_true(stop_opts.error:find("Check your ChatGPT usage", 1, true) ~= nil)
  end)

  describe("HTTP 429 responses", function()
    local curl = require("plenary.curl")
    local Utils = require("avante.utils")
    local original_post
    local original_error

    local function request(body)
      curl.post = function(_, opts)
        opts.callback({ status = 429, headers = {}, body = body })
        return {}
      end
      local stop_opts
      require("avante.llm").curl({
        provider = {
          parse_curl_args = function() return { url = "https://api.openai.com/v1/responses", headers = {}, body = {} } end,
          is_disable_stream = function() return false end,
          parse_response = function() end,
          get_usage_limit_error = openai.get_usage_limit_error,
        },
        prompt_opts = {},
        handler_opts = { on_stop = function(o) stop_opts = o end },
      })
      vim.wait(1000, function() return stop_opts ~= nil end)
      return stop_opts
    end

    before_each(function()
      original_post = curl.post
      original_error = Utils.error
      Utils.error = function() end
    end)

    after_each(function()
      curl.post = original_post
      Utils.error = original_error
    end)

    it("stops instead of retrying when the usage limit is reached", function()
      local stop_opts = request(vim.json.encode({ error = usage_limit_error }))

      assert.equals("error", stop_opts.reason)
      assert.is_true(stop_opts.error:find("Check your ChatGPT usage", 1, true) ~= nil)
    end)

    it("still retries other rate limits", function()
      local stop_opts = request(vim.json.encode({ error = { code = "rate_limit_exceeded" } }))

      assert.equals("rate_limit", stop_opts.reason)
    end)
  end)
end)
