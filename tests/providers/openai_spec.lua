local OpenAI = require("avante.providers.openai")
local Config = require("avante.config")

describe("OpenAI Responses API", function()
  local provider, prompt, ctx, handlers, messages, chunks, stops

  local function event(value) provider:parse_response(ctx, vim.json.encode(value), value.type, handlers) end

  local function terminal_stops()
    return vim.tbl_filter(function(stop) return not stop.streaming_tool_use end, stops)
  end

  before_each(function()
    Config.setup()
    provider = vim.tbl_extend("force", OpenAI, {
      api_key_name = "",
      endpoint = "https://example.com/v1",
      model = "gpt-5",
      use_response_api = true,
      support_previous_response_id = false,
      last_response_id = "resp_old",
      extra_request_body = { max_tokens = 100, reasoning = { effort = "low", summary = "auto" } },
    })
    prompt = { system_prompt = "System", messages = { { role = "user", content = "Hello" } } }
    ctx, messages, chunks, stops = {}, {}, {}, {}
    handlers = {
      on_chunk = function(chunk) table.insert(chunks, chunk) end,
      on_messages_add = function(added)
        for _, message in ipairs(added) do
          messages[message.uuid] = message
        end
      end,
      on_stop = function(stop) table.insert(stops, stop) end,
    }
  end)

  it("sends full history without mutating configuration or retaining server state", function()
    prompt.messages = {
      { role = "user", content = "Hello" },
      { role = "assistant", content = { { type = "tool_use", id = "call_1", name = "test", input = {} } } },
      { role = "user", content = { { type = "tool_result", tool_use_id = "call_1", content = "result" } } },
    }
    local original = vim.deepcopy(provider.extra_request_body)
    local request = provider:parse_curl_args(prompt)
    assert.equals("https://example.com/v1/responses", request.url)
    assert.is_false(request.body.store)
    assert.is_nil(request.body.previous_response_id)
    assert.equals("function_call", request.body.input[3].type)
    assert.equals("{}", request.body.input[3].arguments)
    assert.equals("function_call_output", request.body.input[4].type)
    assert.equals(100, request.body.max_output_tokens)
    assert.same({ "reasoning.encrypted_content" }, request.body.include)
    assert.same(original, provider.extra_request_body)
    assert.same(request.body, provider:parse_curl_args(prompt).body)
  end)

  it("keeps the original stateful defaults", function()
    assert.is_true(Config.providers.openai.support_previous_response_id)
    assert.is_false(Config.providers.copilot.support_previous_response_id)
  end)

  it("keeps the original stateful tool-output continuation", function()
    provider.support_previous_response_id = true
    prompt.messages = {
      { role = "user", content = "Hello" },
      { role = "assistant", content = { { type = "tool_use", id = "call_1", name = "test", input = {} } } },
      { role = "user", content = { { type = "tool_result", tool_use_id = "call_1", content = "result" } } },
    }
    local body = provider:parse_curl_args(prompt).body
    assert.equals("resp_old", body.previous_response_id)
    assert.same({ { type = "function_call_output", call_id = "call_1", output = "result" } }, body.input)
    assert.is_nil(provider.last_response_id)
    assert.is_nil(body.store)
    assert.is_nil(body.include)
  end)

  it("keeps the original stateful input format and request options", function()
    provider.support_previous_response_id = true
    provider.extra_request_body = {
      store = true,
      background = true,
      conversation = "conv_1",
      previous_response_id = "resp_configured",
      reasoning_effort = "high",
      reasoning = { summary = "auto" },
    }
    prompt.messages = { { role = "user", content = { { type = "text", text = "Hello" } } } }
    local body = provider:parse_curl_args(prompt).body
    assert.same({ type = "text", text = "Hello" }, body.input[2].content[1])
    assert.is_true(body.store)
    assert.is_true(body.background)
    assert.equals("conv_1", body.conversation)
    assert.equals("resp_configured", body.previous_response_id)
    assert.same({ effort = "high" }, body.reasoning)
  end)

  it("keeps the original stateful response-ID handling and response.done event", function()
    provider.support_previous_response_id = true
    event({ type = "response.done", response = { id = "resp_next", usage = { input_tokens = 3, output_tokens = 4 } } })
    assert.equals("resp_next", provider.last_response_id)
    assert.equals("resp_next", ctx.last_response_id)
    assert.is_nil(ctx.response_stopped)
    assert.same({ reason = "complete", usage = { prompt_tokens = 3, completion_tokens = 4 } }, terminal_stops()[1])
  end)

  it("resolves the API using the prompt and preserves reasoning and include options", function()
    provider.use_response_api = function(_, opts) return opts == prompt end
    provider.extra_request_body.reasoning_effort = "high"
    provider.extra_request_body.include = { "message.output_text.logprobs" }
    provider.extra_request_body.stop = { "stop" }
    provider.extra_request_body.stream_options = { include_usage = true }
    provider.extra_request_body.response_format = { type = "json_object" }
    local body = provider:parse_curl_args(prompt).body
    assert.same({ effort = "high", summary = "auto" }, body.reasoning)
    assert.same({ "message.output_text.logprobs", "reasoning.encrypted_content" }, body.include)
    assert.is_nil(body.stop)
    assert.is_nil(body.stream_options)
    assert.is_nil(body.response_format)
    assert.same({ type = "json_object" }, body.text.format)
  end)

  it("rejects server-managed state and background requests", function()
    for _, field in ipairs({ "previous_response_id", "conversation", "background" }) do
      provider.extra_request_body[field] = field == "background" and true or "id"
      assert.has_error(function() provider:parse_curl_args(prompt) end)
      provider.extra_request_body[field] = nil
    end
  end)

  it("uses Responses text and image content and preserves item order", function()
    local reasoning = { type = "reasoning", id = "rs_1", encrypted_content = "encrypted", summary = {} }
    prompt.messages = {
      {
        role = "user",
        content = {
          { type = "text", text = "Image" },
          { type = "image", source = { type = "base64", media_type = "image/png", data = "abc" } },
        },
      },
      {
        role = "assistant",
        phase = "commentary",
        content = {
          reasoning,
          { type = "text", text = "Checking" },
          { type = "tool_use", id = "call_1", name = "test", input = {} },
          { type = "text", text = "After" },
        },
      },
    }
    local input = provider:parse_messages(prompt)
    assert.same({ type = "input_text", text = "Image" }, input[2].content[1])
    assert.same({ type = "input_image", image_url = "data:image/png;base64,abc" }, input[2].content[2])
    assert.same(reasoning, input[3])
    assert.equals("Checking", input[4].content[1].text)
    assert.equals("commentary", input[4].phase)
    assert.equals("function_call", input[5].type)
    assert.equals("After", input[6].content[1].text)
  end)

  it("replays canonical output items including IDs, raw arguments, summaries and phases", function()
    local output = {
      { type = "reasoning", id = "rs_1", summary = {}, encrypted_content = "encrypted", status = "completed" },
      {
        type = "message",
        id = "msg_1",
        role = "assistant",
        phase = "commentary",
        status = "completed",
        content = { { type = "output_text", text = "Checking", annotations = {} } },
      },
      {
        type = "function_call",
        id = "fc_1",
        call_id = "call_1",
        name = "test",
        arguments = '{ "value": 1 }',
        status = "completed",
      },
    }
    for index, item in ipairs(output) do
      event({ type = "response.output_item.added", output_index = index - 1, item = item })
      event({ type = "response.output_item.done", output_index = index - 1, item = item })
    end
    event({
      type = "response.completed",
      response = { id = "resp_1", output = output, usage = { input_tokens = 3, output_tokens = 4 } },
    })
    prompt.messages = {}
    for _, item in ipairs(output) do
      local found
      for _, message in pairs(messages) do
        if message.message.response_item and message.message.response_item.id == item.id then
          found = message.message
        end
      end
      assert.is_not_nil(found)
      table.insert(prompt.messages, found)
    end
    assert.same(output, vim.list_slice(provider:parse_messages(prompt), 2))
    assert.same({ reason = "tool_use", usage = { prompt_tokens = 3, completion_tokens = 4 } }, terminal_stops()[1])
    assert.equals("resp_old", provider.last_response_id)
  end)

  it("keeps streamed messages separate and finalizes phases before the next item", function()
    for index, phase in ipairs({ "commentary", "final_answer" }) do
      local item = {
        type = "message",
        id = "msg_" .. index,
        role = "assistant",
        phase = phase,
        status = "completed",
        content = { { type = "output_text", text = phase, annotations = {} } },
      }
      event({ type = "response.output_item.added", output_index = index - 1, item = item })
      event({
        type = "response.output_text.delta",
        output_index = index - 1,
        item_id = item.id,
        content_index = 0,
        delta = phase,
      })
      event({ type = "response.output_item.done", output_index = index - 1, item = item })
    end
    event({ type = "response.completed", response = { output = {} } })
    assert.equals(2, vim.tbl_count(messages))
    for _, message in pairs(messages) do
      assert.equals(message.message.phase, message.message.content)
      assert.equals("generated", message.state)
    end
    assert.same({ "commentary", "final_answer" }, chunks)
  end)

  it("streams function arguments but only executes a valid completed call", function()
    local item = {
      type = "function_call",
      id = "fc_1",
      call_id = "call_1",
      name = "test",
      arguments = "",
      status = "in_progress",
    }
    event({ type = "response.output_item.added", output_index = 0, item = item })
    event({ type = "response.function_call_arguments.delta", output_index = 0, item_id = "fc_1", delta = '{"value":' })
    event({ type = "response.function_call_arguments.delta", output_index = 0, item_id = "fc_1", delta = "1}" })
    event({
      type = "response.function_call_arguments.done",
      output_index = 0,
      item_id = "fc_1",
      arguments = '{"value":1}',
    })
    assert.equals(0, #terminal_stops())
    local message = vim.tbl_values(messages)[1]
    assert.same({ value = 1 }, message.message.content[1].input)
    item.arguments, item.status = '{"value":1}', "completed"
    event({ type = "response.output_item.done", output_index = 0, item = item })
    event({ type = "response.completed", response = { output = { item } } })
    assert.equals("tool_use", terminal_stops()[1].reason)
    assert.equals("generated", vim.tbl_values(messages)[1].state)
  end)

  it("reports invalid final arguments without executing the call", function()
    local item = {
      type = "function_call",
      id = "fc_1",
      call_id = "call_1",
      name = "test",
      arguments = "{invalid",
      status = "completed",
    }
    event({ type = "response.output_item.added", output_index = 0, item = item })
    event({ type = "response.output_item.done", output_index = 0, item = item })
    event({ type = "response.completed", response = { output = { item } } })
    assert.equals(1, #terminal_stops())
    assert.equals("error", terminal_stops()[1].reason)
  end)

  it("handles failure, incomplete and flat error events exactly once", function()
    for _, value in ipairs({
      { type = "response.failed", response = { error = { message = "Failed" } } },
      { type = "response.incomplete", response = { incomplete_details = { reason = "max_output_tokens" } } },
      { type = "error", message = "Invalid request", code = "invalid_request" },
    }) do
      ctx, stops = {}, {}
      event(value)
      provider:parse_response(ctx, "[DONE]", nil, handlers)
      assert.equals(1, #terminal_stops())
      assert.equals("error", terminal_stops()[1].reason)
      assert.is_not_nil(terminal_stops()[1].error)
    end
  end)

  it("reports malformed stream data through on_stop", function()
    assert.has_no.errors(function() provider:parse_response(ctx, "{", nil, handlers) end)
    assert.equals("error", terminal_stops()[1].reason)
  end)

  it("preserves Responses stream options and flattens JSON schemas and tool choices", function()
    provider.extra_request_body.stream_options = { include_usage = true, include_obfuscation = false }
    provider.extra_request_body.response_format = {
      type = "json_schema",
      json_schema = { name = "result", strict = true, schema = { type = "object" } },
    }
    provider.extra_request_body.tool_choice = { type = "function", ["function"] = { name = "test" } }
    provider.extra_request_body.max_output_tokens = 200
    local body = provider:parse_curl_args(prompt).body
    assert.same({ include_obfuscation = false }, body.stream_options)
    assert.same(
      { type = "json_schema", name = "result", strict = true, schema = { type = "object" } },
      body.text.format
    )
    assert.same({ type = "function", name = "test" }, body.tool_choice)
    assert.equals(200, body.max_output_tokens)
  end)

  it("keeps optional function parameters optional with flattened tool definitions", function()
    prompt.tools = {
      {
        name = "test",
        description = "Test",
        param = { fields = {
          { name = "value", type = "string", optional = true },
        } },
      },
    }
    local tool = provider:parse_curl_args(prompt).body.tools[1]
    assert.equals("test", tool.name)
    assert.is_nil(tool["function"])
    assert.is_false(tool.strict)
    assert.same({}, tool.parameters.required)
  end)

  it("uses the same stateless request rules for Copilot", function()
    local Copilot = require("avante.providers.copilot")
    local previous_state = Copilot.state
    Copilot.state = {
      github_token = {
        token = "test",
        expires_at = os.time() + 3600,
        endpoints = { api = "https://example.com" },
      },
    }
    local copilot = setmetatable(
      vim.tbl_extend("force", provider, {
        parse_curl_args = Copilot.parse_curl_args,
        build_headers = Copilot.build_headers,
      }),
      { __index = Copilot }
    )
    local ok, request = pcall(copilot.parse_curl_args, copilot, prompt)
    Copilot.state = previous_state
    assert.is_true(ok)
    assert.equals("https://example.com/responses", request.url)
    assert.is_false(request.body.store)
    assert.is_nil(request.body.previous_response_id)
    assert.equals(100, request.body.max_output_tokens)
    assert.same({ "reasoning.encrypted_content" }, request.body.include)
    assert.equals(100, provider.extra_request_body.max_tokens)
  end)

  it("keeps parallel function calls separate and preserves their call IDs", function()
    local output = {}
    for index = 0, 1 do
      output[index + 1] = {
        type = "function_call",
        id = "fc_" .. index,
        call_id = "call_" .. index,
        name = "test",
        arguments = "",
        status = "in_progress",
      }
      event({ type = "response.output_item.added", output_index = index, item = output[index + 1] })
    end
    for index = 1, 0, -1 do
      local item = output[index + 1]
      item.arguments, item.status = '{"value":' .. index .. "}", "completed"
      event({
        type = "response.function_call_arguments.delta",
        output_index = index,
        item_id = item.id,
        delta = item.arguments,
      })
      event({ type = "response.output_item.done", output_index = index, item = item })
    end
    event({ type = "response.completed", response = { output = output } })
    event({ type = "response.completed", response = { output = output } })
    provider:parse_response(ctx, "[DONE]", nil, handlers)
    assert.equals(1, #terminal_stops())
    assert.equals(2, vim.tbl_count(messages))
    for _, message in pairs(messages) do
      local call = message.message.content[1]
      assert.equals("call_" .. call.input.value, call.id)
    end
  end)

  it("closes reasoning summaries before visible output and saves only completed encrypted reasoning", function()
    local reasoning = { type = "reasoning", id = "rs_1", encrypted_content = vim.NIL, summary = {} }
    event({ type = "response.output_item.added", output_index = 0, item = reasoning })
    event({ type = "response.reasoning_summary_text.delta", output_index = 0, item_id = "rs_1", delta = "Thinking" })
    reasoning.encrypted_content = "final_encrypted"
    reasoning.summary = { { type = "summary_text", text = "Thinking" } }
    event({ type = "response.output_item.done", output_index = 0, item = reasoning })
    local item = {
      type = "message",
      id = "msg_1",
      role = "assistant",
      content = {
        { type = "output_text", text = "Answer", annotations = {} },
      },
    }
    event({ type = "response.output_item.added", output_index = 1, item = item })
    event({ type = "response.output_text.delta", output_index = 1, item_id = "msg_1", delta = "Answer" })
    event({ type = "response.output_item.done", output_index = 1, item = item })
    event({ type = "response.completed", response = { output = { reasoning, item } } })
    assert.equals("<think>\nThinking\n</think>\nAnswer", table.concat(chunks))
    for _, message in pairs(messages) do
      assert.equals("generated", message.state)
      if message.message.response_item and message.message.response_item.type == "reasoning" then
        assert.same(reasoning, message.message.response_item)
      end
    end
  end)

  it("rejects truncated streams and malformed function items without throwing", function()
    for _, item in ipairs({
      { type = "function_call", id = "fc_1", call_id = "call_1", name = "test", arguments = vim.NIL },
      { type = "function_call", id = "fc_1", name = "test", arguments = "{}" },
    }) do
      ctx, stops = {}, {}
      assert.has_no.errors(function() event({ type = "response.output_item.done", output_index = 0, item = item }) end)
      assert.equals("error", terminal_stops()[1].reason)
    end
    ctx, stops = {}, {}
    event({
      type = "response.output_item.added",
      output_index = 0,
      item = {
        type = "function_call",
        id = "fc_1",
        call_id = "call_1",
        name = "test",
        arguments = "",
      },
    })
    provider:parse_response(ctx, "[DONE]", nil, handlers)
    assert.equals("error", terminal_stops()[1].reason)
  end)

  it("keeps canonical empty output messages when generating follow-up prompts", function()
    local item = { type = "message", id = "msg_empty", role = "assistant", status = "completed", content = {} }
    event({ type = "response.output_item.done", output_index = 0, item = item })
    local history_message = vim.tbl_values(messages)[1]
    local llm = require("avante.llm")
    local Path = require("avante.path")
    local initialize, get_templates_dir = Path.prompts.initialize, Path.prompts.get_templates_dir
    Path.prompts.initialize = function() end
    Path.prompts.get_templates_dir = function() return "/tmp" end
    local ok, opts = pcall(llm.generate_prompts, {
      provider = provider,
      history_messages = { history_message },
      session_ctx = {},
      prompt_opts = { system_prompt = "System" },
    })
    Path.prompts.initialize, Path.prompts.get_templates_dir = initialize, get_templates_dir
    assert.is_true(ok)
    assert.equals(1, #opts.messages)
    assert.same(item, opts.messages[1].response_item)
  end)

  it("parses non-streaming Responses output and token usage", function()
    provider.extra_request_body.stream = false
    assert.is_true(provider:is_disable_stream())
    assert.is_false(provider:parse_curl_args(prompt).body.stream)
    local output = {
      {
        type = "message",
        id = "msg_1",
        role = "assistant",
        status = "completed",
        phase = "final_answer",
        content = { { type = "refusal", refusal = "Cannot comply" } },
      },
    }
    provider:parse_response_without_stream(
      vim.json.encode({
        object = "response",
        status = "completed",
        output = output,
        usage = { input_tokens = 2, output_tokens = 3 },
      }),
      nil,
      handlers
    )
    assert.same({ "Cannot comply" }, chunks)
    assert.same(output[1], vim.tbl_values(messages)[1].message.response_item)
    assert.same({ reason = "complete", usage = { prompt_tokens = 2, completion_tokens = 3 } }, terminal_stops()[1])
  end)

  it("keeps Chat Completions request shapes unchanged", function()
    provider.use_response_api = false
    provider.model = "gpt-4o"
    local body = provider:parse_curl_args(prompt).body
    assert.equals("Hello", body.messages[2].content)
    assert.is_nil(body.input)
    assert.is_nil(body.store)
    assert.same({ include_usage = true }, body.stream_options)
  end)
end)
