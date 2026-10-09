local ACPClient = require("avante.libs.acp_client")
local stub = require("luassert.stub")

describe("ACPClient native adapter", function()
  local schedule_stub

  before_each(function()
    schedule_stub = stub(vim, "schedule").invokes(function(fn) fn() end)
  end)

  after_each(function() schedule_stub:revert() end)

  local function ready_client(handlers)
    local client = ACPClient:new({ command = "agent", args = {}, handlers = handlers or {} })
    local native = { calls = {}, next_id = 0 }
    local function operation(name)
      native[name] = function(self, ...)
        self.next_id = self.next_id + 1
        table.insert(self.calls, { method = name, args = { ... }, operation_id = self.next_id })
        return { operationId = self.next_id }
      end
    end
    for _, name in ipairs({
      "new_session",
      "load_session",
      "resume_session",
      "list_sessions",
      "close_session",
      "delete_session",
      "set_session_option",
      "prompt",
    }) do
      operation(name)
    end
    for _, name in ipairs({
      "respond_permission",
      "respond_read_text_file",
      "respond_write_text_file",
      "respond_error",
      "cancel",
      "stop",
    }) do
      native[name] = function(self, ...) table.insert(self.calls, { method = name, args = { ... } }) end
    end
    client.native = native
    client.state = "ready"
    return client, native
  end

  it("calls concrete native methods instead of sending protocol command tables", function()
    local client, native = ready_client()

    client:send_prompt("s1", { { type = "text", text = "hello" } }, function() end)

    assert.equals("prompt", native.calls[1].method)
    assert.same({ "s1", { { type = "text", text = "hello" } } }, native.calls[1].args)
    assert.equals(1, native.calls[1].operation_id)
  end)

  it("routes operation completion to the callback", function()
    local client = ready_client()
    local result
    client:send_prompt("s1", { { type = "text", text = "hello" } }, function(value) result = value end)

    client:_handle_event({ type = "operation_completed", operationId = 1, result = { stopReason = "end_turn" } })

    assert.equals("end_turn", result.stopReason)
    assert.same({}, client.callbacks)
  end)

  it("returns structured native validation errors without string parsing", function()
    local client = ready_client()
    local expected = { kind = "invalid_input", code = -32602, message = "Invalid params", data = "bad prompt" }
    client.native.prompt = function() return { error = expected } end
    local actual

    client:send_prompt("s1", {}, function(_, err) actual = err end)

    assert.same(expected, actual)
    assert.same({}, client.callbacks)
  end)

  it("fails pending operations after a fatal worker error", function()
    local client = ready_client()
    local request_error
    client:send_prompt("s1", { { type = "text", text = "hello" } }, function(_, err) request_error = err end)
    local fatal = { code = -32603, message = "agent exited" }

    client:_handle_event({ type = "fatal_error", error = fatal })

    assert.same(fatal, request_error)
    assert.same({}, client.callbacks)
    assert.equals("error", client.state)
  end)

  it("routes SDK session notifications to the existing UI handler", function()
    local updates = {}
    local client = ready_client({ on_session_update = function(update) table.insert(updates, update) end })

    client:_handle_event({
      type = "session_update",
      replayed = false,
      notification = {
        sessionId = "s1",
        update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hi" } },
      },
    })

    assert.equals("hi", updates[1].content.text)
  end)

  it("answers permission and file requests through typed native responder methods", function()
    local client, native = ready_client({
      on_request_permission = function(_, _, done) done("allow") end,
      on_read_file = function(_, _, _, done) done("contents") end,
      on_write_file = function(_, _, done) done(nil) end,
    })

    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = { toolCall = {}, options = {} },
    })
    client:_handle_event({
      type = "read_text_file_request",
      requestId = 11,
      request = { sessionId = "s1", path = "/tmp/a" },
    })
    client:_handle_event({
      type = "write_text_file_request",
      requestId = 12,
      request = { sessionId = "s1", path = "/tmp/a", content = "new" },
    })

    assert.same({ method = "respond_permission", args = { 10, "allow" } }, native.calls[1])
    assert.same({ method = "respond_read_text_file", args = { 11, "contents" } }, native.calls[2])
    assert.same({ method = "respond_write_text_file", args = { 12 } }, native.calls[3])
  end)

  it("sends semantic responder errors for Rust to map to ACP errors", function()
    local client, native = ready_client()

    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = { toolCall = {}, options = {} },
    })

    assert.same({
      method = "respond_error",
      args = { 10, "unsupported", "Permission handler not configured" },
    }, native.calls[1])
  end)

  it("turns a permission handler exception into a responder error", function()
    local client, native = ready_client({ on_request_permission = function() error("permission failed") end })

    assert.has_no_error(
      function()
        client:_handle_event({
          type = "permission_request",
          requestId = 10,
          request = { toolCall = {}, options = {} },
        })
      end
    )

    assert.equals("respond_error", native.calls[1].method)
    assert.same({ 10, "internal", "permission failed" }, native.calls[1].args)
  end)

  it("turns a read handler exception into a responder error", function()
    local client, native = ready_client({ on_read_file = function() error("read failed") end })

    assert.has_no_error(
      function()
        client:_handle_event({
          type = "read_text_file_request",
          requestId = 11,
          request = { sessionId = "s1", path = "/tmp/a" },
        })
      end
    )

    assert.equals("respond_error", native.calls[1].method)
    assert.same({ 11, "internal", "read failed" }, native.calls[1].args)
  end)

  it("turns a write handler exception into a responder error", function()
    local client, native = ready_client({ on_write_file = function() error("write failed") end })

    assert.has_no_error(
      function()
        client:_handle_event({
          type = "write_text_file_request",
          requestId = 12,
          request = { sessionId = "s1", path = "/tmp/a", content = "new" },
        })
      end
    )

    assert.equals("respond_error", native.calls[1].method)
    assert.same({ 12, "internal", "write failed" }, native.calls[1].args)
  end)

  it("sends cancellation to Rust where pending permissions are owned", function()
    local client, native = ready_client()

    client:cancel_session("s1")

    assert.same({ method = "cancel", args = { "s1" } }, native.calls[1])
  end)

  it("applies ACP line and limit semantics independently", function()
    local lines = { "one", "two", "three", "four" }

    assert.same({ "two", "three" }, ACPClient._slice_lines(lines, 2, 2))
    assert.same({ "three", "four" }, ACPClient._slice_lines(lines, 3, nil))
    assert.same({ "one", "two" }, ACPClient._slice_lines(lines, nil, 2))
    assert.same({}, ACPClient._slice_lines(lines, 2, 0))
  end)

  it("ignores a responder callback after the client has stopped", function()
    local respond
    local client = ready_client({ on_request_permission = function(_, _, done) respond = done end })
    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = { sessionId = "s1", toolCall = {}, options = {} },
    })

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    assert.has_no_error(function() respond("allow") end)
  end)

  it("keeps the UI watchdog beyond Rust's session shutdown deadline", function()
    local client = ready_client()
    client.config.session_close_timeout = 500
    local watchdog_delay
    local defer_stub = stub(vim, "defer_fn").invokes(function(_, delay) watchdog_delay = delay end)

    client:stop()

    defer_stub:revert()
    assert.equals(1500, watchdog_delay)
  end)

  it("does not send a stale responder callback to a replacement client", function()
    local respond
    local client = ready_client({ on_request_permission = function(_, _, done) respond = done end })
    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = { sessionId = "s1", toolCall = {}, options = {} },
    })
    local replacement = { calls = {}, respond_permission = function(self, ...) table.insert(self.calls, { ... }) end }
    client.native_generation = client.native_generation + 1
    client.native = replacement

    respond("allow")

    assert.same({}, replacement.calls)
  end)

  it("starts the native SDK client and completes connect on ready", function()
    local started, connected = false, false
    local native_client = {}
    function native_client:start() started = true end
    local client = ACPClient:new({ command = "agent", args = {}, handlers = {} })
    client._native_module = { api_version = 2, new = function() return native_client end }
    client._start_polling = function() end

    client:connect(function(err)
      assert.is_nil(err)
      connected = true
    end)
    client:_handle_event({ type = "initialized", supportsLoadSession = true, supportsListSessions = true })
    client:_handle_event({ type = "state_changed", state = "ready" })

    assert.is_true(started)
    assert.is_true(connected)
    assert.is_true(client:supports_load_session())
    assert.is_true(client:supports_list_sessions())
  end)

  it("rejects an incompatible native module before starting it", function()
    local client = ACPClient:new({ command = "agent", args = {}, handlers = {} })
    client._native_module = { api_version = 1, new = function() error("must not start") end }
    client._start_polling = function() end
    local actual

    client:connect(function(err) actual = err end)

    assert.equals("error", client.state)
    assert.equals("internal", actual.kind)
    assert.matches("Incompatible avante_acp native module", actual.message)
    assert.matches("rebuild or reinstall", actual.message)
  end)

  it("rejects transports not supported by the official process adapter", function()
    assert.has_error(function() ACPClient:new({ transport_type = "tcp" }) end)
  end)
end)
