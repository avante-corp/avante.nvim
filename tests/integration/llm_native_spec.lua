local native_dir = vim.env.AVANTE_LLM_TEST_NATIVE_DIR

-- The regular Lua suite does not build native modules.
if not native_dir or native_dir == "" then return end

package.preload.avante_llm = assert(package.loadlib(native_dir .. "/avante_llm.so", "luaopen_avante_llm"))
package.loaded.avante_llm = nil

local Config = require("avante.config")
Config.setup({})
local Llm = require("avante.llm")
local RigClient = require("avante.libs.rig_client")
local History = require("avante.history")
local uv = vim.uv or vim.loop

assert.same(2, require("avante_llm").api_version)

describe("LLM native integration", function()
  local server
  local clients
  local original_mode
  local original_use_cwd_as_project_root
  local original_history_storage_path
  local original_cwd = vim.fn.getcwd()
  local test_cwd
  local original_aws_env
  local original_proxy_env

  before_each(function()
    clients = {}
    original_mode = Config.mode
    original_use_cwd_as_project_root = Config.behaviour.use_cwd_as_project_root
    original_history_storage_path = Config.history.storage_path
    Config.behaviour.use_cwd_as_project_root = true
    test_cwd = vim.fn.tempname()
    original_aws_env = nil
    -- Local servers must observe the native connection, including its cancellation.
    original_proxy_env = {}
    for _, name in ipairs({ "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" }) do
      original_proxy_env[name] = vim.env[name] or false
      vim.env[name] = nil
    end
    vim.fn.mkdir(test_cwd, "p")
    vim.fn.chdir(test_cwd)
  end)

  after_each(function()
    for name, value in pairs(original_proxy_env) do
      vim.env[name] = value or nil
    end
    for name, value in pairs(original_aws_env or {}) do
      vim.env[name] = value or nil
    end
    Config.mode = original_mode
    for _, client in ipairs(clients) do
      if not client:is_closing() then client:close() end
    end
    if server and not server:is_closing() then server:close() end
    server = nil
    vim.fn.chdir(original_cwd)
    vim.fn.delete(test_cwd, "rf")
    test_cwd = nil
    Config.behaviour.use_cwd_as_project_root = original_use_cwd_as_project_root
    Config.history.storage_path = original_history_storage_path
  end)

  local function fake_openai(response_bodies, response_options)
    if type(response_bodies) == "string" then response_bodies = { response_bodies } end
    response_options = response_options or {}
    local requests = {}
    server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    local address = assert(server:getsockname())
    assert(server:listen(16, function(err)
      assert.is_nil(err)
      local client = assert(uv.new_tcp())
      clients[#clients + 1] = client
      assert(server:accept(client))
      local buffer = ""
      client:read_start(function(read_err, data)
        assert.is_nil(read_err)
        if not data then return end
        buffer = buffer .. data
        local header_end = buffer:find("\r\n\r\n", 1, true)
        if not header_end then return end
        local content_length = tonumber(buffer:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
        if #buffer < header_end + 3 + content_length then return end
        requests[#requests + 1] = buffer
        local response_body = assert(response_bodies[#requests], "unexpected request")
        client:read_stop()
        local response_headers = {
          "HTTP/1.1 " .. (response_options.status or "200 OK"),
          "Content-Type: text/event-stream",
          "Connection: close",
          "Content-Length: " .. #response_body,
        }
        for name, value in pairs(response_options.headers or {}) do
          response_headers[#response_headers + 1] = name .. ": " .. value
        end
        local response_head = table.concat(response_headers, "\r\n") .. "\r\n\r\n"
        client:write(response_head .. response_body, function()
          client:shutdown(function() client:close() end)
        end)
      end)
    end))
    return "http://127.0.0.1:" .. address.port .. "/v1", function(index) return requests[index or #requests] end
  end

  local function sse(events)
    return table.concat(vim.tbl_map(function(event) return "data: " .. vim.json.encode(event) .. "\n\n" end, events))
  end

  it("does not expose the Gemini API key in a connection failure", function()
    server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    assert(server:listen(1, function(err)
      assert.is_nil(err)
      local client = assert(uv.new_tcp())
      clients[#clients + 1] = client
      assert(server:accept(client))
      client:close_reset()
    end))
    local secret = "test-gemini-secret-must-not-appear"
    local stopped
    local request = RigClient.start({
      _name = "gemini",
      _protocol = "gemini",
      model = "gemini-2.5-flash",
      endpoint = "http://127.0.0.1:" .. server:getsockname().port .. "/v1beta/models",
      api_key_name = "TEST_KEY",
      parse_api_key = function() return secret end,
    }, {
      system_prompt = "Be concise.",
      messages = { { role = "user", content = "hello" } },
    }, {
      on_stop = function(result) stopped = result end,
    })

    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("error", stopped.reason)
    assert.is_string(stopped.error)
    assert.is_not.equal("", stopped.error)
    assert.is_nil(stopped.error:find(secret, 1, true), "connection errors must not expose credentials")
  end)

  for _, case in ipairs({
    { name = "defaults to 10 seconds without Retry-After", headers = {}, expected = 10 },
    { name = "respects Retry-After", headers = { ["Retry-After"] = "7" }, expected = 7 },
  }) do
    it("native rate limiting " .. case.name, function()
      local endpoint = fake_openai('{"error":{"message":"rate limited","type":"rate_limit_error"}}', {
        status = "429 Too Many Requests",
        headers = case.headers,
      })
      local stopped
      local request = RigClient.start({
        _name = "openai",
        _protocol = "openai",
        model = "custom-chat-model",
        endpoint = endpoint,
      }, {
        system_prompt = "Be concise.",
        messages = { { role = "user", content = "hello" } },
      }, {
        on_stop = function(result) stopped = result end,
      })

      assert.is_not_nil(request, stopped and stopped.error)
      assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
      assert.same("rate_limit", stopped.reason)
      assert.same(case.expected, stopped.retry_after)
    end)
  end

  it("closes a stalled native stream when a Lua callback fails", function()
    server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    local disconnected = false
    assert(server:listen(1, function(err)
      assert.is_nil(err)
      local client = assert(uv.new_tcp())
      clients[#clients + 1] = client
      assert(server:accept(client))
      local received, replied = "", false
      client:read_start(function(read_err, data)
        assert.is_nil(read_err)
        if not data then
          disconnected = true
          return
        end
        received = received .. data
        if not replied and received:find("\r\n\r\n", 1, true) then
          replied = true
          client:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        end
      end)
    end))
    local stops = {}
    local request = RigClient.start({
      _name = "openai",
      _protocol = "openai",
      model = "test-model",
      endpoint = "http://127.0.0.1:" .. server:getsockname().port .. "/v1",
      parse_api_key = function() return "test-token" end,
    }, {
      system_prompt = "Be concise.",
      messages = { { role = "user", content = "hello" } },
    }, {
      on_stop = function(result) stops[#stops + 1] = result end,
    }, function() error("response header callback failed") end)

    assert.is_not_nil(request)
    assert.is_true(vim.wait(10000, function() return #stops > 0 end, 10))
    assert.same("error", stops[1].reason)
    assert.matches("response header callback failed", stops[1].error, nil, true)
    assert.is_true(vim.wait(2000, function() return disconnected end, 10), "cancelled worker must close its stream")
    request:cancel()
    assert.same(1, #stops)
  end)

  local function anthropic_reply(blocks, reason)
    local events = {
      {
        type = "message_start",
        message = {
          id = "msg-test",
          role = "assistant",
          model = "test-model",
          content = {},
          usage = { input_tokens = 1, output_tokens = 0 },
        },
      },
    }
    for index, block in ipairs(blocks) do
      events[#events + 1] = { type = "content_block_start", index = index - 1, content_block = block }
      events[#events + 1] = { type = "content_block_stop", index = index - 1 }
    end
    events[#events + 1] = { type = "message_delta", delta = { stop_reason = reason }, usage = { output_tokens = 1 } }
    events[#events + 1] = { type = "message_stop" }
    return sse(events)
  end

  local function stream_reply(provider, messages)
    local history = {}
    local stopped
    local request = RigClient.start(provider, {
      system_prompt = "Be concise.",
      messages = messages,
      tools = { { name = "lookup", description = "Look something up", param = { fields = {} } } },
    }, {
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          local replaced = false
          for index, previous in ipairs(history) do
            if previous.uuid == item.uuid then
              history[index] = item
              replaced = true
              break
            end
          end
          if not replaced then history[#history + 1] = item end
        end
      end,
      on_stop = function(result)
        if not result.streaming_tool_use then stopped = result end
      end,
    })
    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.is_nil(stopped.error)
    return History.get_history_messages({ messages = history }), stopped.reason
  end

  local function chat_reply()
    return sse({
      {
        id = "chatcmpl-test",
        object = "chat.completion.chunk",
        created = 1,
        model = "gpt-6-luna",
        choices = { { index = 0, delta = { content = "ok" }, finish_reason = "stop" } },
      },
    }) .. "data: [DONE]\n\n"
  end

  for _, case in ipairs({
    { endpoint = "/v1/models", path = "/v1/models" },
    { endpoint = "/v1beta/models", path = "/v1beta/models" },
    { endpoint = "", path = "/v1beta/models" },
    { endpoint = "/gateway", path = "/gateway/v1beta/models" },
    { endpoint = "/gateway/v1/models/", path = "/gateway/v1/models" },
  }) do
    it("preserves the Gemini endpoint path for " .. (case.endpoint ~= "" and case.endpoint or "the root"), function()
      local endpoint, get_request = fake_openai(sse({
        { candidates = { { content = { role = "model", parts = { { text = "ok" } } }, finishReason = "STOP" } } },
      }))
      stream_reply({
        _name = "gemini",
        _protocol = "gemini",
        model = "gemini-2.5-flash",
        endpoint = endpoint:gsub("/v1$", "") .. case.endpoint,
        api_key_name = "TEST_KEY",
        parse_api_key = function() return "test-key" end,
      }, { { role = "user", content = "hello" } })
      local request = assert(get_request())
      local request_path = request:match("^POST ([^ ]+) HTTP/")
      assert.same(case.path .. "/gemini-2.5-flash:streamGenerateContent?alt=sse", request_path)
      assert.is_not_nil(request:lower():find("x-goog-api-key: test-key", 1, true))
    end)
  end

  it("preserves null tool arguments through streaming, saved history, and replay", function()
    local arguments_json = '{"query":"rust","include_pattern":null,"values":[null,"middle",null],"options":{}}'
    local expected = vim.json.decode(arguments_json)
    local endpoint, get_request = fake_openai({
      sse({
        {
          id = "chatcmpl-nulls",
          model = "custom-chat-model",
          choices = {
            {
              index = 0,
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call-nulls",
                    type = "function",
                    ["function"] = { name = "lookup", arguments = arguments_json },
                  },
                },
              },
            },
          },
        },
        { choices = { { index = 0, delta = vim.empty_dict(), finish_reason = "tool_calls" } } },
      }) .. "data: [DONE]\n\n",
      chat_reply(),
    })
    local provider = { _name = "openai", _protocol = "openai", model = "custom-chat-model", endpoint = endpoint }
    local history = {
      filename = "null-arguments.json",
      title = "Conversation before the tool call",
      timestamp = "2026-10-25T00:00:00Z",
      entries = {},
      todos = {},
      messages = { History.Message:new("user", "hello") },
    }
    local stopped, partial_input
    local request = RigClient.start(provider, {
      system_prompt = "Be concise.",
      messages = { history.messages[1].message },
      tools = {
        {
          name = "lookup",
          description = "Look something up",
          param = {
            fields = {
              { name = "query", type = "string" },
              { name = "include_pattern", type = { "string", "null" }, optional = true },
              { name = "values", type = "array", items = { name = "value", type = { "string", "null" } } },
              { name = "options", type = "object", fields = {} },
            },
          },
        },
      },
    }, {
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          local input = item.message.content[1].input
          if item.state == "generating" and input.query and not partial_input then partial_input = input end
          local replaced = false
          for index, previous in ipairs(history.messages) do
            if previous.uuid == item.uuid then
              history.messages[index] = item
              replaced = true
              break
            end
          end
          if not replaced then history.messages[#history.messages + 1] = item end
        end
      end,
      on_stop = function(result)
        if not result.streaming_tool_use then stopped = result end
      end,
    })
    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("tool_use", stopped.reason)

    local Path = require("avante.path")
    Config.history.storage_path = test_cwd .. "/history"
    Path.history.save(0, history, test_cwd)
    local loaded = Path.history.load(0, history.filename, test_cwd)
    assert.same(history.title, loaded.title, "saving a null argument must not lose the conversation")
    assert.same(2, #loaded.messages)
    assert.same(expected, loaded.messages[2].message.content[1].input)
    assert.is_not_nil(partial_input)
    assert.same(expected, vim.json.decode(vim.json.encode(partial_input)))

    local messages = vim.tbl_map(function(item) return item.message end, loaded.messages)
    messages[#messages + 1] = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = "call-nulls", content = "found" } },
    }
    local _, reason = stream_reply(provider, messages)
    assert.same("complete", reason)
    local body = vim.json.decode(assert(get_request(2)):match("\r\n\r\n(.*)"))
    local replayed_arguments
    for _, message in ipairs(body.messages) do
      if message.tool_calls then replayed_arguments = vim.json.decode(message.tool_calls[1]["function"].arguments) end
    end
    assert.same(expected, replayed_arguments)
  end)

  it("keeps Azure deployment routing separate from reasoning model parameters", function()
    local endpoint, get_request = fake_openai(chat_reply())
    stream_reply({
      _name = "private_azure",
      _protocol = "azure",
      endpoint = endpoint,
      model = "gpt-6-luna",
      deployment = "production-deployment",
      api_version = "2025-04-01-preview",
      extra_request_body = { max_completion_tokens = 128, reasoning_effort = "low" },
    }, { { role = "user", content = "hello" } })
    local raw = get_request()
    assert.matches("/deployments/production-deployment/chat/completions", raw, nil, true)
    local body = vim.json.decode(raw:match("\r\n\r\n(.*)"))
    assert.same(128, body.max_completion_tokens)
    assert.is_nil(body.max_tokens)
    assert.same("low", body.reasoning_effort)
  end)

  local function azure_responses_reply()
    return sse({
      {
        type = "response.completed",
        sequence_number = 1,
        response = {
          id = "resp-azure",
          object = "response",
          created_at = 1,
          status = "completed",
          model = "gpt-6-luna",
          output = {},
          tools = {},
          usage = { input_tokens = 1, output_tokens = 0, total_tokens = 1 },
        },
      },
    })
  end

  for _, case in ipairs({
    { name = "xai", route = false, path = "/v1/chat/completions" },
    { name = "xai", route = true, path = "/v1/responses", responses = true },
    { name = "openai", model = "gpt-6-luna", path = "/v1/responses", responses = true },
    { name = "openai", model = "gpt-6-luna", route = false, path = "/v1/chat/completions" },
    { name = "deepseek", effort = "none", path = "/responses", responses = true },
    { name = "deepseek", effort = "max", path = "/responses", responses = true },
    { name = "moonshot", path = "/v1/chat/completions" },
    { name = "copilot", path = "/responses", responses = true },
  }) do
    it("maps provider defaults to the wire for " .. vim.inspect(case), function()
      local endpoint, get_request = fake_openai(case.responses and azure_responses_reply() or chat_reply())
      local provider = vim.deepcopy(require("avante.providers")[case.name])
      provider.endpoint = provider.endpoint:gsub("^https?://[^/]+", endpoint:gsub("/v1$", ""))
      provider.parse_api_key = function() return "test-key" end
      if case.name == "copilot" then
        provider.get_session_token = function(callback)
          if callback then callback() end
          return { token = "test-key", endpoints = { api = provider.endpoint } }
        end
      end
      if case.model then provider.model = case.model end
      if case.route ~= nil then provider.use_response_api = case.route end
      if case.effort then provider.extra_request_body.reasoning_effort = case.effort end
      stream_reply(provider, { { role = "user", content = "hello" } })
      local raw = get_request()
      assert.same("POST " .. case.path .. " HTTP/1.1", raw:match("^[^\r\n]+"))
      local body = vim.json.decode(raw:match("\r\n\r\n(.*)"))
      assert.same(provider.model, body.model)
      if case.name == "moonshot" then
        assert.is_nil(body.temperature)
        assert.same("high", body.reasoning_effort)
        assert.same(16384, body.max_tokens)
        assert.is_nil(body.max_completion_tokens)
      end
      if case.model == "gpt-6-luna" then assert.is_nil(body.temperature) end
      if case.effort then
        assert.same(case.effort, body.reasoning.effort)
        assert.is_nil(body.reasoning_effort)
      end
    end)
  end

  for _, case in ipairs({
    {
      name = "preview Azure Responses from a resource endpoint",
      api_version = "2025-04-01-preview",
      endpoint_suffix = "",
      path = "/openai/responses?api-version=2025-04-01-preview",
    },
    {
      name = "v1 Azure Responses from a resource endpoint",
      api_version = "v1",
      endpoint_suffix = "",
      path = "/openai/v1/responses",
    },
    {
      name = "v1 Azure Responses from an endpoint already containing openai/v1",
      api_version = "v1",
      endpoint_suffix = "/openai/v1",
      path = "/openai/v1/responses",
    },
  }) do
    it("routes " .. case.name, function()
      local endpoint, get_request = fake_openai(azure_responses_reply())
      stream_reply({
        _name = "private_azure",
        _protocol = "azure",
        endpoint = endpoint:gsub("/v1$", "") .. case.endpoint_suffix,
        model = "gpt-6-luna",
        deployment = "production-deployment",
        api_version = case.api_version,
        use_response_api = true,
        extra_request_body = { max_completion_tokens = 128, reasoning_effort = "low" },
      }, { { role = "user", content = "hello" } })
      local raw = get_request()
      assert.same("POST " .. case.path .. " HTTP/1.1", raw:match("^[^\r\n]+"))
      local body = vim.json.decode(raw:match("\r\n\r\n(.*)"))
      assert.same("production-deployment", body.model)
      assert.same(128, body.max_output_tokens)
      assert.same("low", body.reasoning.effort)
      assert.same("auto", body.reasoning.summary)
    end)
  end

  for _, case in ipairs({
    { model = "gpt-6-luna", effort = "medium" },
    { model = "gpt-6-luna-2026-09-15", effort = "medium" },
    { model = "gpt-6-sol", effort = "medium" },
  }) do
    it("applies " .. case.model .. " capabilities to Azure Responses with a deployment alias", function()
      local endpoint, get_request = fake_openai(azure_responses_reply())
      stream_reply({
        _name = "private_azure",
        _protocol = "azure",
        endpoint = endpoint:gsub("/v1$", ""),
        model = case.model,
        deployment = "production-deployment",
        api_version = "2025-04-01-preview",
        use_response_api = true,
        extra_request_body = vim.deepcopy(Config.providers.azure.extra_request_body),
      }, { { role = "user", content = "hello" } })
      local raw = get_request()
      local body = vim.json.decode(raw:match("\r\n\r\n(.*)"))
      assert.same("production-deployment", body.model)
      assert.same(case.temperature, body.temperature)
      if case.effort then
        assert.same(case.effort, body.reasoning.effort)
      else
        assert.is_nil(body.reasoning)
      end
    end)
  end

  it("rejects the default Azure Chat API version for Responses before sending a request", function()
    local input = RigClient._build_request({
      _name = "private_azure",
      _protocol = "azure",
      endpoint = "http://127.0.0.1:1",
      model = "custom-chat-model",
      deployment = "production-deployment",
      api_version = Config.providers.azure.api_version,
      use_response_api = true,
      extra_request_body = vim.deepcopy(Config.providers.azure.extra_request_body),
    }, { system_prompt = "Be concise.", messages = { { role = "user", content = "hello" } } })
    local native = require("avante_llm")
    local ok, error = pcall(native.request_headers, input)
    assert.is_false(ok)
    assert.matches('api_version = "v1"', tostring(error), nil, true)
    local request = native.start(input)
    local failure
    assert.is_true(vim.wait(10000, function()
      for _, event in ipairs(request:poll()) do
        if event.type == "error" then failure = event end
      end
      return failure ~= nil
    end, 10))
    assert.matches('api_version = "v1"', failure.message, nil, true)
  end)

  for _, case in ipairs({
    { name = "claude-opus" },
    { name = "claude", model = "claude-opus-4-7" },
    { name = "claude-haiku" },
    { name = "aihubmix-claude" },
  }) do
    it("applies Claude sampling rules to " .. (case.model or case.name), function()
      local endpoint, get_request = fake_openai(anthropic_reply({ { type = "text", text = "ok" } }, "end_turn"))
      local provider = vim.deepcopy(require("avante.providers")[case.name])
      provider.endpoint = endpoint
      provider.parse_api_key = function() return "test-key" end
      if case.model then provider.model = case.model end
      stream_reply(provider, { { role = "user", content = "hello" } })
      local body = vim.json.decode(get_request():match("\r\n\r\n(.*)"))
      assert.same(provider.model, body.model)
      assert.same(case.temperature, body.temperature)
    end)
  end

  for _, case in ipairs({ { profile = "", key = "AKIAREVIEWDEFAULT" }, { profile = "named", key = "AKIAREVIEWNAMED" } }) do
    it("loads Bedrock shared credentials for profile " .. vim.inspect(case.profile), function()
      original_aws_env = {}
      for _, name in ipairs({
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_CONFIG_FILE",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "AWS_EC2_METADATA_DISABLED",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_ROLE_SESSION_NAME",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
      }) do
        original_aws_env[name] = vim.env[name] or false
        vim.env[name] = nil
      end
      vim.env.AWS_SHARED_CREDENTIALS_FILE = test_cwd .. "/credentials"
      vim.env.AWS_CONFIG_FILE = test_cwd .. "/config"
      vim.env.AWS_EC2_METADATA_DISABLED = "true"
      vim.fn.writefile({
        "[default]",
        "aws_access_key_id = AKIAREVIEWDEFAULT",
        "aws_secret_access_key = dummy-default-secret",
        "[named]",
        "aws_access_key_id = AKIAREVIEWNAMED",
        "aws_secret_access_key = dummy-named-secret",
      }, vim.env.AWS_SHARED_CREDENTIALS_FILE)
      vim.fn.writefile({}, vim.env.AWS_CONFIG_FILE)
      local endpoint, get_request = fake_openai("")
      local stopped
      local request = RigClient.start({
        _name = "bedrock",
        _protocol = "bedrock",
        model = "anthropic.claude-sonnet-4-6",
        endpoint = endpoint:gsub("/v1$", ""),
        aws_region = "us-east-1",
        aws_profile = case.profile,
        parse_api_key = function() return nil end,
        extra_request_body = { max_tokens = 128 },
      }, {
        system_prompt = "Be concise.",
        messages = { { role = "user", content = "hello" } },
      }, {
        on_stop = function(result) stopped = result end,
      })
      assert.is_not_nil(request, stopped and stopped.error)
      local finished = vim.wait(10000, function() return get_request() ~= nil or stopped ~= nil end, 10)
      request:cancel()
      vim.wait(2000, function() return stopped ~= nil end, 10)
      assert.is_true(finished, "Bedrock request timed out")
      local raw = get_request()
      assert.is_not_nil(raw, stopped and stopped.error)
      assert.matches("Credential=" .. case.key .. "/", raw, nil, true)
      assert.matches("/us-east-1/bedrock/aws4_request", raw, nil, true)
    end)
  end

  for _, protocol in ipairs({ "openai", "claude" }) do
    it("lets custom headers override Rig defaults for " .. protocol, function()
      local endpoint, get_request = fake_openai(
        protocol == "claude" and anthropic_reply({ { type = "text", text = "ok" } }, "end_turn") or chat_reply()
      )
      stream_reply({
        _name = protocol,
        _protocol = protocol,
        endpoint = endpoint,
        model = "test-model",
        api_key_name = "TEST_KEY",
        parse_api_key = function() return "default-key" end,
        extra_request_body = { max_tokens = 128 },
        extra_headers = {
          Authorization = "Bearer override-key",
          ["x-api-key"] = "override-key",
          ["anthropic-version"] = "2023-01-01",
          ["x-gateway-tenant"] = "test-tenant",
        },
      }, { { role = "user", content = "hello" } })
      local raw = get_request():lower()
      assert.matches("authorization: bearer override-key\r\n", raw, nil, true)
      assert.matches("x-api-key: override-key\r\n", raw, nil, true)
      assert.matches("anthropic-version: 2023-01-01\r\n", raw, nil, true)
      assert.matches("x-gateway-tenant: test-tenant\r\n", raw, nil, true)
      assert.matches("content-type: application/json\r\n", raw, nil, true)
      assert.is_nil(raw:find("default-key", 1, true))
    end)
  end

  for _, case in ipairs({ "modify", "whitelist", "empty" }) do
    it("applies extra_headers callback " .. case .. " to the actual request", function()
      local endpoint, get_request = fake_openai(chat_reply())
      local callbacks = 0
      stream_reply({
        _name = "gateway",
        _protocol = "openai",
        endpoint = endpoint,
        model = "test-model",
        api_key_name = "TEST_KEY",
        parse_api_key = function() return "default-key" end,
        extra_headers = function(headers)
          callbacks = callbacks + 1
          assert.same("Bearer default-key", headers.Authorization)
          assert.same("application/json", headers["Content-Type"])
          assert.same("text/event-stream", headers.Accept)
          if case == "whitelist" then return { ["Content-Type"] = headers["Content-Type"] } end
          if case == "empty" then return {} end
          headers["X-Gateway-Auth"] = headers.Authorization
          headers.Authorization = "Gateway override-key"
          return headers
        end,
      }, { { role = "user", content = "hello" } })
      local headers = get_request():match("^(.-)\r\n\r\n"):lower()
      assert.same(1, callbacks)
      if case == "modify" then
        assert.matches("authorization: gateway override-key\r\n", headers .. "\r\n", nil, true)
        assert.matches("x-gateway-auth: bearer default-key\r\n", headers .. "\r\n", nil, true)
      else
        assert.is_nil(headers:find("authorization:", 1, true))
        assert.is_nil(headers:find("accept: text/event-stream", 1, true))
        if case == "empty" then assert.is_nil(headers:find("content-type:", 1, true)) end
      end
    end)
  end

  it("replays separate signed Anthropic blocks after saving and loading history", function()
    local blocks = {
      { type = "thinking", thinking = "first", signature = "sig-1" },
      { type = "thinking", thinking = "second", signature = "sig-2" },
      { type = "redacted_thinking", data = "opaque" },
      { type = "tool_use", id = "call-1", name = "lookup", input = vim.empty_dict() },
    }
    local endpoint, get_request = fake_openai({
      anthropic_reply(blocks, "tool_use"),
      anthropic_reply({ { type = "text", text = "done" } }, "end_turn"),
    })
    local provider = {
      _name = "claude",
      _protocol = "claude",
      endpoint = endpoint,
      model = "test-model",
      extra_request_body = { max_tokens = 1024 },
      parse_api_key = function() return "test-key" end,
    }
    local messages = { { role = "user", content = "hello" } }
    local history, reason = stream_reply(provider, messages)
    assert.same("tool_use", reason)
    assert.same(4, #history)
    for _, item in ipairs(history) do
      messages[#messages + 1] = vim.json.decode(vim.json.encode(item.message))
    end
    messages[#messages + 1] = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = "call-1", content = "answer" } },
    }
    local _, final_reason = stream_reply(provider, messages)
    assert.same("complete", final_reason)
    local body = vim.json.decode(assert(get_request(2)):match("\r\n\r\n(.*)"))
    local replayed = {}
    for _, message in ipairs(body.messages) do
      if message.role == "assistant" then vim.list_extend(replayed, message.content) end
    end
    assert.same(blocks, replayed)
  end)

  it("replays Gemini text and tool signatures including terminal backfills", function()
    local endpoint, get_request = fake_openai({
      sse({
        {
          candidates = {
            {
              content = {
                role = "model",
                parts = {
                  { text = "answer", thoughtSignature = "dGV4dC1zaWc=", partMetadata = { empty = vim.empty_dict() } },
                  { functionCall = { name = "lookup", args = vim.empty_dict() } },
                },
              },
            },
          },
        },
        {
          candidates = {
            {
              content = { role = "model", parts = { { thoughtSignature = "dG9vbC1zaWc=" } } },
              finishReason = "STOP",
            },
          },
        },
      }),
      sse({
        { candidates = { { content = { role = "model", parts = { { text = "done" } } }, finishReason = "STOP" } } },
      }),
    })
    local provider = {
      _name = "gemini",
      _protocol = "gemini",
      endpoint = endpoint,
      model = "gemini-3-flash-preview",
      parse_api_key = function() return "test-key" end,
    }
    local messages = { { role = "user", content = "hello" } }
    local history, reason = stream_reply(provider, messages)
    assert.same("tool_use", reason)
    for _, item in ipairs(history) do
      messages[#messages + 1] = vim.json.decode(vim.json.encode(item.message))
    end
    local call_id = history[#history].message.content[1].id
    messages[#messages + 1] = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = call_id, content = "answer" } },
    }
    local _, final_reason = stream_reply(provider, messages)
    assert.same("complete", final_reason)
    local body = vim.json.decode(assert(get_request(2)):match("\r\n\r\n(.*)"))
    local parts = {}
    for _, content in ipairs(body.contents) do
      if content.role == "model" then vim.list_extend(parts, content.parts) end
    end
    assert.same("dGV4dC1zaWc=", parts[1].thoughtSignature)
    assert.same(vim.empty_dict(), parts[1].partMetadata.empty)
    assert.same("dG9vbC1zaWc=", parts[2].thoughtSignature)
    assert.same("lookup", parts[2].functionCall.name)
    local results = {}
    for _, content in ipairs(body.contents) do
      for _, part in ipairs(content.parts) do
        if part.functionResponse then results[#results + 1] = part.functionResponse end
      end
    end
    assert.same(1, #results)
    assert.same("lookup", results[1].name)
    assert.same({ result = "answer" }, results[1].response)
  end)

  for _, case in ipairs({
    { with_text = true, summary = "plan" },
    { with_text = false, summary = "plan" },
    { with_text = true, summary = "" },
  }) do
    local with_text = case.with_text
    it(
      "replays Responses output order and encrypted reasoning "
        .. (with_text and "with text" or "without text")
        .. (case.summary == "" and " and an empty summary" or ""),
      function()
        local output = {
          {
            type = "reasoning",
            id = "rs-1",
            encrypted_content = "cipher",
            summary = case.summary == "" and {} or { { type = "summary_text", text = case.summary } },
          },
          {
            type = "message",
            id = "msg-1",
            role = "assistant",
            status = "completed",
            phase = "commentary",
            content = { { type = "output_text", text = "answer", annotations = {} } },
          },
          {
            type = "function_call",
            id = "fc-1",
            call_id = "call-1",
            name = "lookup",
            arguments = "{}",
            status = "completed",
          },
        }
        local text_output = output[2]
        if not with_text then table.remove(output, 2) end
        local function response(items)
          local events = {}
          local last = items[#items]
          if last.type == "function_call" then
            events[#events + 1] = { type = "response.output_item.added", output_index = #items - 1, item = last }
            events[#events + 1] = { type = "response.output_item.done", output_index = #items - 1, item = last }
          end
          events[#events + 1] = {
            type = "response.completed",
            sequence_number = 1,
            response = {
              id = "resp-test",
              object = "response",
              created_at = 1,
              status = "completed",
              model = "gpt-5.6-sol",
              output = items,
              tools = {},
              usage = { input_tokens = 1, output_tokens = 1, total_tokens = 2 },
            },
          }
          return sse(events)
        end
        local endpoint, get_request = fake_openai({ response(output), response({ text_output }) })
        local provider = {
          _name = "openai",
          _protocol = "openai",
          endpoint = endpoint,
          model = "gpt-5.6-sol",
          use_response_api = true,
          parse_api_key = function() return "test-key" end,
        }
        local messages = { { role = "user", content = "hello" } }
        local history, reason = stream_reply(provider, messages)
        assert.same("tool_use", reason)
        assert.same("thinking", history[1].message.content[1].type)
        assert.same(case.summary, history[1].message.content[1].thinking)
        local rendered = require("avante.history.render").message_to_text(history[1], history)
        if case.summary == "" then
          assert.same("", rendered)
        else
          assert.matches("> " .. case.summary, rendered, nil, true)
        end
        history[#history + 1] = History.Message:new("user", {
          type = "tool_result",
          tool_use_id = "call-1",
          content = "answer",
        })
        history = History.update_tool_invocation_history(history, nil, false)
        for _, item in ipairs(history) do
          messages[#messages + 1] = vim.json.decode(vim.json.encode(item.message))
        end
        local _, final_reason = stream_reply(provider, messages)
        assert.same("complete", final_reason)
        local body = vim.json.decode(assert(get_request(2)):match("\r\n\r\n(.*)"))
        assert.same("auto", body.reasoning.summary)
        local reasoning = vim.iter(body.input):find(function(item) return item.type == "reasoning" end)
        local text = vim.iter(body.input):find(function(item) return item.id == "msg-1" end)
        assert.is_not_nil(reasoning, vim.inspect({ body = body, history = history }))
        assert.same("cipher", reasoning.encrypted_content)
        assert.same("rs-1", reasoning.id)
        if with_text then assert.same("commentary", text.phase) end
        local ids = {}
        for _, item in ipairs(body.input) do
          if item.id then ids[#ids + 1] = item.id end
        end
        assert.same(with_text and { "rs-1", "msg-1", "fc-1" } or { "rs-1", "fc-1" }, ids)
      end
    )
  end

  it("selects tools in the final output order", function()
    local first = {
      type = "function_call",
      id = "fc-1",
      call_id = "call-1",
      name = "lookup",
      arguments = "{}",
      status = "completed",
    }
    local second = {
      type = "function_call",
      id = "fc-2",
      call_id = "call-2",
      name = "lookup",
      arguments = "{}",
      status = "completed",
    }
    local endpoint = fake_openai(sse({
      { type = "response.output_item.added", output_index = 1, item = second },
      { type = "response.output_item.done", output_index = 1, item = second },
      {
        type = "response.completed",
        response = {
          id = "resp-test",
          object = "response",
          created_at = 1,
          status = "completed",
          model = "test-model",
          output = { first, second },
          tools = {},
          usage = { input_tokens = 1, output_tokens = 1, total_tokens = 2 },
        },
      },
    }))
    local history = stream_reply({
      _name = "openai",
      _protocol = "openai",
      endpoint = endpoint,
      model = "test-model",
      use_response_api = true,
      parse_api_key = function() return "test-key" end,
    }, { { role = "user", content = "hello" } })
    local tools = History.get_pending_tools(history)
    assert.same({ "call-1", "call-2" }, vim.tbl_map(function(item) return item.id end, tools))
  end)

  it("preserves the phase stored by the previous Lua transport", function()
    local endpoint, get_request = fake_openai(sse({
      {
        type = "response.completed",
        response = {
          id = "resp-test",
          object = "response",
          created_at = 1,
          status = "completed",
          model = "test-model",
          output = {
            {
              type = "message",
              id = "msg-final",
              role = "assistant",
              status = "completed",
              content = { { type = "output_text", text = "done", annotations = {} } },
            },
          },
          tools = {},
          usage = { input_tokens = 1, output_tokens = 1, total_tokens = 2 },
        },
      },
    }))
    stream_reply({
      _name = "openai",
      _protocol = "openai",
      endpoint = endpoint,
      model = "test-model",
      use_response_api = true,
      parse_api_key = function() return "test-key" end,
    }, {
      { role = "user", content = "question" },
      { role = "assistant", content = "let me check", phase = "commentary" },
      { role = "user", content = "continue" },
    })
    local body = vim.json.decode(assert(get_request()):match("\r\n\r\n(.*)"))
    local assistant_message = vim.iter(body.input):find(function(item) return item.role == "assistant" end)
    assert.same("commentary", assistant_message.phase)
  end)

  it("rejects malformed final tool arguments before marking calls executable", function()
    local endpoint = fake_openai(sse({
      {
        type = "response.completed",
        response = {
          id = "resp-invalid",
          object = "response",
          created_at = 1,
          status = "completed",
          model = "test-model",
          output = {
            {
              type = "function_call",
              id = "fc-1",
              call_id = "call-1",
              name = "lookup",
              arguments = '{"query":"unclosed',
            },
          },
          tools = {},
          usage = { input_tokens = 1, output_tokens = 1, total_tokens = 2 },
        },
      },
    }))
    local stopped
    local generated = {}
    local request = RigClient.start({
      _name = "openai",
      _protocol = "openai",
      endpoint = endpoint,
      model = "test-model",
      use_response_api = true,
      parse_api_key = function() return "test-key" end,
    }, {
      system_prompt = "Be concise.",
      messages = { { role = "user", content = "hello" } },
      tools = { { name = "lookup", description = "Look something up", param = { fields = {} } } },
    }, {
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          if item.state == "generated" then generated[#generated + 1] = item end
        end
      end,
      on_stop = function(result)
        if not result.streaming_tool_use then stopped = result end
      end,
    })
    assert.is_not_nil(request)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("error", stopped.reason)
    assert.matches("invalid JSON arguments for tool lookup", stopped.error, nil, true)
    assert.same({}, generated)
  end)

  it("streams text and structured tool arguments through Lua and Rig", function()
    local endpoint, get_request = fake_openai(table.concat({
      'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"hello"},"finish_reason":null}]}\n\n',
      'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"lookup","arguments":"{\\"query\\":\\"ru"}}]},"finish_reason":null}]}\n\n',
      'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"st\\"}"}}]},"finish_reason":null}]}\n\n',
      'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"test-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}\n\n',
      "data: [DONE]\n\n",
    }))
    local chunks = {}
    local messages = {}
    local stopped
    local request = RigClient.start({
      _name = "private_gateway",
      _protocol = "openai",
      endpoint = endpoint,
      model = "test-model",
      parse_api_key = function() return "test-key" end,
    }, {
      system_prompt = "Be concise.",
      messages = { { role = "user", content = "hello" } },
      tools = {
        {
          name = "lookup",
          description = "Look something up",
          param = {
            fields = {
              { name = "query", type = "string", description = "Query", optional = false },
            },
          },
        },
      },
    }, {
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end,
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          messages[#messages + 1] = item
        end
      end,
      on_stop = function(result) stopped = result end,
    })

    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("tool_use", stopped.reason)
    assert.same("hello", table.concat(chunks))
    local partial_tool_input
    local tool_input
    for _, message in ipairs(messages) do
      local content = message.message.content
      if type(content) == "table" and content[1] and content[1].type == "tool_use" then
        if not partial_tool_input and message.state == "generating" and content[1].input.query then
          partial_tool_input = content[1].input
        end
        tool_input = content[1].input
      end
    end
    assert.same({ query = "rust" }, partial_tool_input)
    assert.same({ query = "rust" }, tool_input)
    assert.matches("POST /v1/chat/completions", assert(get_request()), nil, true)
    assert.matches('"content":"hello"', get_request(), nil, true)
  end)

  it("replays DeepSeek reasoning, tool calls, and results on the second request", function()
    local endpoint, get_request = fake_openai({
      table.concat({
        'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"deepseek-flash","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"plan"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"lookup","arguments":"{\\"query\\":\\"rust\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1,"model":"deepseek-flash","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        "data: [DONE]\n\n",
      }),
      table.concat({
        'data: {"id":"chatcmpl-test-2","object":"chat.completion.chunk","created":2,"model":"deepseek-flash","choices":[{"index":0,"delta":{"role":"assistant","content":"done"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-test-2","object":"chat.completion.chunk","created":2,"model":"deepseek-flash","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
        "data: [DONE]\n\n",
      }),
    })
    local history = {}
    local tool_calls = 0
    local stopped
    Config.mode = "legacy"
    local provider = {
      _name = "deepseek",
      _protocol = "openai",
      dialect = "deepseek",
      endpoint = endpoint,
      model = "deepseek-flash",
      use_response_api = false,
      parse_api_key = function() return "test-key" end,
    }
    local request = Llm._stream({
      provider = provider,
      prompt_opts = {
        system_prompt = "Be concise.",
        messages = { { role = "user", content = "hello" } },
        tools = {
          {
            name = "lookup",
            description = "Look something up",
            param = {
              fields = {
                { name = "query", type = "string", description = "Query", optional = false },
              },
            },
            func = function(input)
              tool_calls = tool_calls + 1
              assert.same({ query = "rust" }, input)
              return "answer"
            end,
          },
        },
      },
      get_history_messages = function() return history end,
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          local replaced = false
          for index, previous in ipairs(history) do
            if previous.uuid == item.uuid then
              history[index] = item
              replaced = true
              break
            end
          end
          if not replaced then history[#history + 1] = item end
        end
      end,
      on_stop = function(result) stopped = result end,
      on_chunk = function() end,
      session_ctx = {},
    })

    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("complete", stopped.reason)
    assert.same(1, tool_calls)

    local raw_request = assert(get_request(2), "second request was not sent")
    local request_body = assert(raw_request:match("\r\n\r\n(.*)"))
    local body = vim.json.decode(request_body)
    local assistant = vim
      .iter(body.messages)
      :find(function(message) return message.role == "assistant" and message.tool_calls ~= nil end)
    local tool_result = vim.iter(body.messages):find(function(message) return message.role == "tool" end)

    assert.same("plan", assistant.reasoning_content)
    assert.same("call-1", assistant.tool_calls[1].id)
    assert.same("lookup", assistant.tool_calls[1]["function"].name)
    assert.same("call-1", tool_result.tool_call_id)
    assert.same("answer", tool_result.content)
  end)

  it("continues Responses with the edit result and the synthetic view pair", function()
    local endpoint, get_request = fake_openai(sse({
      {
        type = "response.completed",
        response = {
          id = "resp-test",
          object = "response",
          created_at = 1,
          status = "completed",
          model = "test-model",
          output = {},
          tools = {},
          usage = { input_tokens = 1, output_tokens = 1, total_tokens = 2 },
        },
      },
    }))
    local Message = require("avante.history.message")
    local history = History.update_tool_invocation_history({
      Message:new("user", "edit the file"),
      Message:new(
        "assistant",
        { type = "tool_use", id = "edit-1", name = "edit_file", input = { path = "test.txt" } }
      ),
      Message:new("user", { type = "tool_result", tool_use_id = "edit-1", content = "edited successfully" }),
    }, nil, false)
    local provider = {
      _name = "openai",
      _protocol = "openai",
      endpoint = endpoint,
      model = "test-model",
      use_response_api = true,
      support_previous_response_id = true,
      parse_api_key = function() return "test-key" end,
    }
    local session_ctx = { previous_response_id = "resp-previous" }
    local Path = require("avante.path")
    local stub = require("luassert.stub")
    local initialize = stub(Path.prompts, "initialize")
    local templates = stub(Path.prompts, "get_templates_dir").returns(test_cwd)
    local ok, prompt = pcall(Llm.generate_prompts, {
      provider = provider,
      history_messages = history,
      session_ctx = session_ctx,
      prompt_opts = { system_prompt = "Be concise." },
    })
    initialize:revert()
    templates:revert()
    assert.is_true(ok, prompt)
    local stopped
    local request = RigClient.start(provider, prompt, {
      on_stop = function(result) stopped = result end,
    }, nil, session_ctx)

    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.is_nil(stopped.error)
    local body = vim.json.decode(assert(get_request()):match("\r\n\r\n(.*)"))
    assert.same("resp-previous", body.previous_response_id)
    local edit_result = vim.iter(body.input):find(function(item) return item.call_id == "edit-1" end)
    assert.same("function_call_output", edit_result.type)
    assert.same("edited successfully", edit_result.output)
    local view_call = vim.iter(body.input):find(function(item) return item.type == "function_call" end)
    assert.same("view", view_call.name)
    local view_result = vim.iter(body.input):find(
      function(item) return item.type == "function_call_output" and item.call_id == view_call.call_id end
    )
    assert.is_not_nil(view_result)
  end)

  it("sends and streams an OpenAI Responses request through Lua and Rig", function()
    local endpoint, get_request = fake_openai(table.concat({
      'data: {"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"sequence_number":1,"delta":"hello"}\n\n',
      'data: {"type":"response.completed","sequence_number":2,"response":{"id":"resp-test","object":"response","created_at":1,"status":"completed","error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"test-model","usage":{"input_tokens":20,"output_tokens":10,"total_tokens":30,"input_tokens_details":{"cached_tokens":12,"cache_write_tokens":0},"output_tokens_details":{"reasoning_tokens":4}},"output":[],"tools":[]}}\n\n',
    }))
    local chunks = {}
    local stopped
    local request = RigClient.start({
      _name = "openai",
      _protocol = "openai",
      dialect = "openai",
      endpoint = endpoint,
      model = "test-model",
      use_response_api = true,
      parse_api_key = function() return "test-key" end,
    }, {
      system_prompt = "Be concise.",
      messages = { { role = "user", content = "hello" } },
    }, {
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end,
      on_stop = function(result) stopped = result end,
    })

    assert.is_not_nil(request, stopped and stopped.error)
    assert.is_true(vim.wait(10000, function() return stopped ~= nil end, 10), "native request timed out")
    assert.same("complete", stopped.reason)
    assert.same("hello", table.concat(chunks))
    assert.same({
      prompt_tokens = 20,
      completion_tokens = 10,
      total_tokens = 30,
      cached_input_tokens = 12,
      cache_creation_input_tokens = 0,
      reasoning_tokens = 4,
    }, stopped.usage)

    local raw_request = assert(get_request())
    local body = assert(raw_request:match("\r\n\r\n(.*)"))
    assert.matches("POST /v1/responses", raw_request, nil, true)
    assert.matches('"input":', body, nil, true)
    assert.matches('"stream":true', body, nil, true)
    assert.is_nil(body:find('"truncation"', 1, true))
    assert.is_nil(body:find('"context_management"', 1, true))
    assert.is_nil(body:find('"messages":', 1, true))
  end)
end)
