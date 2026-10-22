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
      "force_stop",
    }) do
      native[name] = function(self, ...) table.insert(self.calls, { method = name, args = { ... } }) end
    end
    client.native = native
    client.connection_state = "ready"
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

  it("continues dispatching a polled batch after a handler throws", function()
    local reported
    local client, native = ready_client({
      on_session_update = function() error("render failed") end,
      on_error = function(err) reported = err end,
    })
    local completed = false
    client:send_prompt("s1", { { type = "text", text = "hello" } }, function() completed = true end)
    native.poll = function()
      return {
        {
          type = "session_update",
          replayed = false,
          notification = {
            sessionId = "s1",
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hi" } },
          },
        },
        { type = "operation_completed", operationId = 1, result = { stopReason = "end_turn" } },
      }
    end

    client:_poll_events()

    assert.is_true(completed)
    assert.equals("internal", reported.kind)
    assert.matches("render failed", reported.message)
  end)

  it("does not apply the rest of an old poll batch to a replacement connection", function()
    local client, native = ready_client()
    client.config.reconnect = true
    local replacement = { start = function() end, stop = stub() }
    client._native_module = { api_version = 3, new = function() return replacement end }
    client._start_polling = function() end
    client._stop_polling = function() end
    local defer_stub = stub(vim, "defer_fn")
    local fatal = { kind = "internal", message = "old agent failed" }
    local request_error
    client:send_prompt("s1", { { type = "text", text = "hello" } }, function(_, err)
      request_error = err
      client:connect(function() end)
    end)
    native.poll = function()
      return {
        { type = "fatal_error", error = fatal },
        { type = "state_changed", state = "disconnected" },
      }
    end

    client:_poll_events()

    defer_stub:revert()
    assert.same(fatal, request_error)
    assert.equals(replacement, client.native)
    assert.equals("connecting", client.connection_state)
    assert.stub(replacement.stop).was_not_called()
  end)

  it("discards remaining events when a callback stops the connection without replacing it", function()
    local updates = {}
    local client, native = ready_client({ on_session_update = function(update) table.insert(updates, update) end })
    client:send_prompt("s1", {}, function() client:force_stop() end)
    native.poll = function()
      return {
        { type = "operation_completed", operationId = 1, result = { stopReason = "end_turn" } },
        {
          type = "session_update",
          notification = {
            sessionId = "s1",
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "late" } },
          },
        },
      }
    end

    client:_poll_events()

    assert.is_nil(client.native)
    assert.same({}, updates)
  end)

  it("does not fail a new operation started by a fatal connection callback", function()
    local client = ready_client()
    client.connection_state = "connecting"
    local replacement = { start = function() end, stop = stub(), prompt = function() return { operationId = 1 } end }
    client._native_module = { api_version = 3, new = function() return replacement end }
    client._start_polling = function() end
    local fatal = { kind = "internal", message = "old connection failed" }
    local connect_error, completed, operation_error
    table.insert(client.connect_callbacks, function(err)
      connect_error = err
      client:connect(function()
        client:send_prompt("s1", { { type = "text", text = "hello" } }, function(result, failure)
          completed, operation_error = result, failure
        end)
      end)
      client:_handle_event({ type = "state_changed", state = "ready" })
    end)

    client:_handle_event({ type = "fatal_error", error = fatal })
    client:_handle_event({ type = "operation_completed", operationId = 1, result = { stopReason = "end_turn" } })

    assert.same(fatal, connect_error)
    assert.same({ stopReason = "end_turn" }, completed)
    assert.is_nil(operation_error)
    assert.equals(replacement, client.native)
    assert.stub(replacement.stop).was_not_called()
  end)

  it("finishes a ready transition when the state handler throws", function()
    local reported
    local client, native = ready_client({
      on_state_change = function() error("state render failed") end,
      on_error = function(err) reported = err end,
    })
    client.connection_state = "connecting"
    local connected = false
    table.insert(client.connect_callbacks, function() connected = true end)
    native.poll = function() return { { type = "state_changed", state = "ready" } } end

    client:_poll_events()

    assert.is_true(connected)
    assert.equals("ready", client.connection_state)
    assert.matches("state render failed", reported.message)
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
    local client, native = ready_client()
    local request_error
    client:send_prompt("s1", { { type = "text", text = "hello" } }, function(_, err) request_error = err end)
    local fatal = { code = -32603, message = "agent exited" }

    client:_handle_event({ type = "fatal_error", error = fatal })

    assert.same(fatal, request_error)
    assert.same({}, client.callbacks)
    assert.equals("error", client.connection_state)
    assert.same({ method = "stop", args = {} }, native.calls[2])
  end)

  it("reports the original fatal error once when the worker is already closed", function()
    local errors = {}
    local client = ready_client({ on_error = function(err) table.insert(errors, err) end })
    local operation_errors = {}
    client:send_prompt(
      "s1",
      { { type = "text", text = "hello" } },
      function(_, err) table.insert(operation_errors, err) end
    )
    client.native.stop = function() error("ACP client connection is closed") end
    local fatal = { code = -32603, message = "agent exited" }

    client:_handle_event({ type = "fatal_error", error = fatal })
    client:_handle_event({ type = "operation_failed", operationId = 1, error = fatal })

    assert.same({ fatal }, errors)
    assert.same({ fatal }, operation_errors)
  end)

  it("reconnects after a fatal error and restores the active session before becoming ready", function()
    local client, native = ready_client()
    client.config.reconnect = true
    client.config.additional_directories = { "/shared" }
    client:load_session("s1", "/project", { { name = "fs" } }, function() end)
    client:_handle_event({ type = "operation_completed", operationId = 1, result = {} })

    local replacement = { calls = {}, next_id = 0 }
    function replacement:start() self.started = true end
    function replacement:load_session(...)
      replacement.next_id = replacement.next_id + 1
      table.insert(replacement.calls, { ... })
      return { operationId = replacement.next_id }
    end
    function replacement:stop() end
    function replacement:poll() return {} end
    client._native_module = { api_version = 3, new = function() return replacement end }
    client._start_polling = function() end
    client._stop_polling = function() end
    local defer_stub = stub(vim, "defer_fn").invokes(function(fn) fn() end)

    client:_handle_event({ type = "fatal_error", error = { kind = "internal", message = "agent exited" } })
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:_handle_event({ type = "initialized", supportsLoadSession = true, supportsListSessions = false })
    client:_handle_event({ type = "state_changed", state = "ready" })
    local started = replacement.started
    local connection_state_during_restore = client.connection_state
    local ready_before_restore = client:is_ready()
    local restore_call = replacement.calls[1]
    client:_handle_event({ type = "operation_completed", operationId = 1, result = {} })
    local ready_after_restore = client:is_ready()
    defer_stub:revert()

    assert.is_true(started)
    assert.equals("ready", connection_state_during_restore)
    assert.is_false(ready_before_restore)
    assert.same({
      "s1",
      { cwd = "/project", mcpServers = { { name = "fs" } }, additionalDirectories = { "/shared" } },
    }, restore_call)
    assert.is_true(ready_after_restore)
    assert.equals("s1", client.active_session_id)
  end)

  it("stops after session restoration fails even when the error handler throws", function()
    local client, native = ready_client({ on_error = function() error("error UI failed") end })
    client.connection_state = "connecting"
    client.reconnect_pending = true
    client.active_session_id = "s1"
    client.active_session_setup = {
      cwd = "/project",
      mcpServers = {},
      additionalDirectories = {},
    }
    client:_handle_event({ type = "state_changed", state = "ready" })

    assert.has_no_error(
      function()
        client:_handle_event({
          type = "operation_failed",
          operationId = 1,
          error = { kind = "internal", message = "restore failed" },
        })
      end
    )

    assert.is_true(client.is_stopping)
    assert.equals("stop", native.calls[2].method)
  end)

  it("does not run a queued reconnect after an explicit stop", function()
    local client = ready_client()
    client.config.reconnect = true
    local reconnect
    local defer_stub = stub(vim, "defer_fn").invokes(function(fn) reconnect = fn end)
    local connect_stub = stub(client, "connect")

    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:stop()
    reconnect()

    defer_stub:revert()
    assert.stub(connect_stub).was_not_called()
    connect_stub:revert()
    assert.equals("disconnected", client.connection_state)
    assert.is_true(client.stop_requested)
  end)

  it("ignores a queued reconnect from a replaced native generation", function()
    local client = ready_client()
    client.config.reconnect = true
    local timers = {}
    local defer_stub = stub(vim, "defer_fn").invokes(function(fn) table.insert(timers, fn) end)
    local starts = 0
    local replacement = { start = function() starts = starts + 1 end }
    client._native_module = { api_version = 3, new = function() return replacement end }
    client._start_polling = function() end

    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:connect(function() end)
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    timers[1]()
    local starts_after_stale_timer = starts
    timers[2]()

    defer_stub:revert()
    assert.equals(1, starts_after_stale_timer)
    assert.equals(2, starts)
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

  it("compares every setting that affects a reused ACP client", function()
    local config = {
      command = "agent",
      args = { "--stdio" },
      env = { API_KEY = "one" },
      auth_method = "token",
      session_close_timeout = 500,
      transport_type = "stdio",
      reconnect = true,
      max_reconnect_attempts = 3,
    }

    assert.is_true(ACPClient.is_same_process_config(config, vim.deepcopy(config)))
    for _, field in ipairs({
      "command",
      "args",
      "env",
      "auth_method",
      "session_close_timeout",
      "transport_type",
      "reconnect",
      "max_reconnect_attempts",
    }) do
      local changed = vim.deepcopy(config)
      if field == "command" then
        changed[field] = "other"
      elseif field == "session_close_timeout" then
        changed[field] = 900
      elseif field == "transport_type" then
        changed[field] = "tcp"
      elseif field == "reconnect" then
        changed[field] = false
      elseif field == "max_reconnect_attempts" then
        changed[field] = 5
      else
        changed[field] = nil
      end
      assert.is_false(ACPClient.is_same_process_config(config, changed), field)
    end
  end)

  it(
    "normalizes default process and reconnect settings",
    function()
      assert.is_true(ACPClient.is_same_process_config({ command = "agent" }, {
        command = "agent",
        transport_type = "stdio",
        reconnect = false,
        max_reconnect_attempts = 3,
        session_close_timeout = 500,
      }))
    end
  )

  it("does not restart the ACP process for session-scoped MCP servers", function()
    local first = { command = "agent", mcp_servers = { { name = "one" } } }
    local second = { command = "agent", mcp_servers = { { name = "two" } } }

    assert.is_true(ACPClient.is_same_process_config(first, second))
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

  it("force stops the native worker and disposes the client immediately", function()
    local client, native = ready_client()
    local disposed = 0
    client.on_dispose = function() disposed = disposed + 1 end

    client:force_stop()

    assert.same({ method = "force_stop", args = {} }, native.calls[1])
    assert.equals("disconnected", client.connection_state)
    assert.is_nil(client.native)
    assert.equals(1, disposed)
  end)

  it("disposes its global registration once after stopping", function()
    local client = ready_client()
    local disposed = 0
    client.on_dispose = function() disposed = disposed + 1 end

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:stop()

    assert.equals(1, disposed)
  end)

  it("finishes a pending connection when stopped", function()
    local client = ready_client()
    client.connection_state = "connecting"
    local connect_error
    table.insert(client.connect_callbacks, function(err) connect_error = err end)

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })

    assert.equals("cancelled", connect_error.kind)
  end)

  it("finishes every pending operation once when a graceful stop disconnects", function()
    local client = ready_client()
    local completions = {}
    for _, session_id in ipairs({ "s1", "s2" }) do
      client:send_prompt(
        session_id,
        { { type = "text", text = "hello" } },
        function(result, err) table.insert(completions, { session_id = session_id, result = result, error = err }) end
      )
    end

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:_handle_event({ type = "operation_completed", operationId = 1, result = { stopReason = "cancelled" } })
    client:_handle_event({ type = "operation_failed", operationId = 2, error = { kind = "cancelled" } })
    client:stop()

    assert.equals(2, #completions)
    for _, completion in ipairs(completions) do
      assert.is_nil(completion.result)
      assert.equals("cancelled", completion.error.kind)
    end
    assert.same({}, client.callbacks)
  end)

  for _, callback_kind in ipairs({ "operation", "stop" }) do
    it("preserves a replacement started by the " .. callback_kind .. " callback while stopping", function()
      local client = ready_client()
      local replacement = { start = function() end, stop = stub(), prompt = function() return { operationId = 1 } end }
      client._native_module = { api_version = 3, new = function() return replacement end }
      client._start_polling = function() end
      local completed, failure
      local function reconnect()
        client:connect(function()
          client:send_prompt("s1", { { type = "text", text = "new request" } }, function(result, err)
            completed, failure = result, err
          end)
        end)
        client:_handle_event({ type = "state_changed", state = "ready" })
      end
      if callback_kind == "operation" then
        client:send_prompt("s1", { { type = "text", text = "old request" } }, reconnect)
        client:stop()
      else
        client:stop(reconnect)
      end

      client:_handle_event({ type = "state_changed", state = "disconnected" })
      client:_handle_event({ type = "operation_completed", operationId = 1, result = { stopReason = "end_turn" } })

      assert.equals(replacement, client.native)
      assert.equals("ready", client.connection_state)
      assert.same({ stopReason = "end_turn" }, completed)
      assert.is_nil(failure)
      assert.stub(replacement.stop).was_not_called()
    end)
  end

  it("does not let an old stop watchdog dispose a later connection", function()
    local client = ready_client()
    local timers = {}
    local defer_stub = stub(vim, "defer_fn").invokes(function(fn) table.insert(timers, fn) end)
    local replacement = { start = function() end, stop = function() end }
    client._native_module = { api_version = 3, new = function() return replacement end }
    client._start_polling = function() end

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:connect(function() end)
    client:_handle_event({ type = "state_changed", state = "ready" })
    client:stop()
    timers[1]()
    local native_after_stale_watchdog = client.native
    local still_stopping = client.is_stopping
    timers[2]()

    defer_stub:revert()
    assert.equals(replacement, native_after_stale_watchdog)
    assert.is_true(still_stopping)
    assert.is_nil(client.native)
    assert.equals("disconnected", client.connection_state)
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
    client._native_module = { api_version = 3, new = function() return native_client end }
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

    assert.equals("error", client.connection_state)
    assert.equals("internal", actual.kind)
    assert.matches("Incompatible avante_acp native module", actual.message)
    assert.matches("rebuild or reinstall", actual.message)
  end)

  for _, retry_from in ipairs({ "state", "connection" }) do
    it("preserves a retry from the " .. retry_from .. " callback after synchronous connect failure", function()
      local client = ACPClient:new({ command = "agent", handlers = {} })
      client._native_module = { api_version = 1 }
      client._start_polling = function() end
      local disposed = 0
      client.on_dispose = function() disposed = disposed + 1 end
      local replacement = { start = function() end, force_stop = function() end }
      local retried, retry_error, original_error
      local function retry()
        client._native_module = { api_version = 3, new = function() return replacement end }
        client:connect(function(err)
          retried, retry_error = true, err
        end)
      end
      client.config.handlers.on_state_change = function(state)
        if state == "error" and retry_from == "state" then retry() end
      end

      client:connect(function(err)
        original_error = err
        if retry_from == "connection" then retry() end
      end)
      local disposed_before_ready = disposed
      client:_handle_event({ type = "state_changed", state = "ready" })
      local current_native = client.native
      client:force_stop()

      assert.equals("internal", original_error.kind)
      assert.equals(replacement, current_native)
      assert.is_true(retried)
      assert.is_nil(retry_error)
      assert.equals(0, disposed_before_ready)
      assert.equals(1, disposed)
    end)
  end

  it("rejects transports not supported by the official process adapter", function()
    assert.has_error(
      function() ACPClient:new({ transport_type = "tcp" }) end,
      "The official ACP Rust process adapter only supports stdio transport (got tcp)"
    )
  end)
end)
