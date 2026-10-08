local Llm = require("avante.llm")
local OpenAI = require("avante.providers.openai")
local Config = require("avante.config")
local curl = require("plenary.curl")

describe("LLM stream framing and completion", function()
  local provider, request, parsed, stops, original_post

  local function run_stream(lines, result)
    curl.post = function(_, opts)
      for _, line in ipairs(lines) do
        opts.stream(nil, line)
      end
      if result and result.stream_error then opts.stream(result.stream_error, nil) end
      opts.callback(result or { status = 200, headers = {}, body = "" })
      return { is_closing = function() return false end, shutdown = function() end }
    end
    Llm.curl({
      provider = provider,
      prompt_opts = {},
      handler_opts = {
        on_chunk = function() end,
        on_messages_add = function() end,
        on_stop = function(stop) table.insert(stops, stop) end,
      },
    })
    local drained = false
    vim.schedule(function() drained = true end)
    assert.is_true(vim.wait(1000, function() return drained end))
  end

  local function terminal_stops()
    return vim.tbl_filter(function(stop) return not stop.streaming_tool_use end, stops)
  end

  before_each(function()
    Config.setup()
    original_post = curl.post
    parsed, stops = {}, {}
    request = { url = "https://example.com/v1/responses", headers = {}, body = { stream = true, input = {} } }
    provider = vim.tbl_extend("force", OpenAI, {
      support_previous_response_id = false,
      extra_request_body = {},
      parse_curl_args = function() return request end,
      parse_response = function(self, ctx, data, event, opts)
        table.insert(parsed, { data = data, event = event })
        OpenAI.parse_response(self, ctx, data, event, opts)
      end,
      on_error = function() end,
    })
  end)

  after_each(function()
    curl.post = original_post
    vim.api.nvim_clear_autocmds({ group = "avante_llm", event = "User", pattern = Llm.CANCEL_PATTERN })
  end)

  it("reports EOF without a terminal Responses event", function()
    run_stream({ 'data: {"type":"response.created","response":{"id":"resp_1"}}', "" })
    assert.equals(1, #terminal_stops())
    assert.equals("error", terminal_stops()[1].reason)
    assert.matches("without a terminal response event", terminal_stops()[1].error)
  end)

  it("reports EOF even when no response events arrived", function()
    run_stream({})
    assert.equals(1, #terminal_stops())
    assert.equals("error", terminal_stops()[1].reason)
  end)

  it("processes queued completion events before checking EOF", function()
    run_stream({ 'data: {"type":"response.completed","response":{"output":[]}}', "" })
    assert.equals(1, #terminal_stops())
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("preserves a failed response instead of reporting EOF again", function()
    run_stream({ 'data: {"type":"response.failed","response":{"error":{"message":"upstream failure"}}}', "" })
    assert.equals(1, #terminal_stops())
    assert.matches("upstream failure", terminal_stops()[1].error)
  end)

  it("does not mistake streaming tool callbacks for terminal completion", function()
    run_stream({
      'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"test","arguments":""}}',
      "",
    })
    assert.is_true(#stops > #terminal_stops())
    assert.equals(1, #terminal_stops())
    assert.matches("without a terminal response event", terminal_stops()[1].error)
  end)

  it("joins multiple data fields and dispatches on the blank line", function()
    run_stream({
      "event: response.created",
      'data: {"type":"response.created",',
      'data: "response":{"id":"resp_1"}}',
      "",
      "event: response.completed",
      'data: {"type":"response.completed","response":{"output":[]}}',
      "",
    })
    assert.equals(2, #parsed)
    assert.equals('{"type":"response.created",\n"response":{"id":"resp_1"}}', parsed[1].data)
    assert.equals("response.created", parsed[1].event)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("discards an unterminated SSE event at EOF", function()
    run_stream({ 'data: {"type":"response.completed","response":{"output":[]}}' })
    assert.equals(0, #parsed)
    assert.equals("error", terminal_stops()[1].reason)
  end)

  it("ignores comments and control fields and resets event names", function()
    run_stream({
      "event: response.created",
      "",
      ": keepalive",
      "id: 123",
      "retry: 1000",
      "extension: ignored",
      'data: {"type":"response.created","response":{"id":"resp_1"}}',
      "",
      "event: stale",
      "event:",
      'data:{"type":"response.completed","response":{"output":[]}}',
      "",
    })
    assert.equals(2, #parsed)
    assert.is_nil(parsed[1].event)
    assert.is_nil(parsed[2].event)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("handles CRLF and removes only one optional space after the colon", function()
    run_stream({
      "event: response.completed\r",
      'data:  {"type":"response.completed","response":{"output":[]}}\r',
      "\r",
    })
    assert.equals(' {"type":"response.completed","response":{"output":[]}}', parsed[1].data)
    assert.equals("response.completed", parsed[1].event)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("dispatches an empty data field without a colon", function()
    run_stream({ "data", "" })
    assert.equals(1, #parsed)
    assert.equals("", parsed[1].data)
  end)

  it("accepts a leading UTF-8 BOM and preserves empty data fields", function()
    run_stream({
      "\239\187\191event: response.completed",
      "data:",
      'data: {"type":"response.completed","response":{"output":[]}}',
      "",
    })
    assert.equals('\n{"type":"response.completed","response":{"output":[]}}', parsed[1].data)
    assert.equals("response.completed", parsed[1].event)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("retains the JSON-lines fallback", function()
    run_stream({
      '{"type":"response.created","response":{"id":"resp_1"}}',
      '{"type":"response.completed","response":{"output":[]}}',
    })
    assert.equals(2, #parsed)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("does not add EOF validation to stateful Responses", function()
    provider.support_previous_response_id = true
    run_stream({ 'data: {"type":"response.created","response":{"id":"resp_1"}}', "" })
    assert.equals(1, #parsed)
    assert.equals(0, #stops)
  end)

  it("keeps Chat Completions SSE and DONE handling", function()
    request.body = { stream = true, messages = {} }
    run_stream({ 'data: {"choices":[{"delta":{"content":"hello"}}]}', "", "data: [DONE]", "" })
    assert.equals(2, #parsed)
    assert.equals(1, #terminal_stops())
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("does not add Responses EOF validation to Chat Completions", function()
    request.body = { stream = true, messages = {} }
    run_stream({})
    assert.equals(0, #stops)
  end)

  it("keeps non-streaming Responses completion", function()
    request.body.stream = false
    provider.extra_request_body.stream = false
    run_stream({}, {
      status = 200,
      headers = {},
      body = '{"object":"response","status":"completed","output":[]}',
    })
    assert.equals(0, #parsed)
    assert.equals(1, #terminal_stops())
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("leaves providers with custom stream parsing unchanged", function()
    local lines = {}
    request.body = { stream = true, messages = {} }
    provider.parse_stream_data = function(_, _, data, opts)
      table.insert(lines, data)
      if data == "done" then opts.on_stop({ reason = "complete" }) end
    end
    run_stream({ "custom data", "done" })
    assert.same({ "custom data", "done" }, lines)
    assert.equals(0, #parsed)
    assert.equals("complete", terminal_stops()[1].reason)
  end)

  it("does not replace stream errors with EOF errors", function()
    run_stream({}, { status = 200, headers = {}, body = "", stream_error = "connection reset" })
    assert.equals(1, #terminal_stops())
    assert.equals("connection reset", terminal_stops()[1].error)
  end)

  it("preserves rate-limit responses", function()
    run_stream({}, { status = 429, headers = { "retry-after: 2" }, body = "" })
    assert.equals(1, #terminal_stops())
    assert.equals("rate_limit", terminal_stops()[1].reason)
    assert.equals(2, terminal_stops()[1].retry_after)
  end)
end)
