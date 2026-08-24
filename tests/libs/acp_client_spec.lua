local ACPClient = require("avante.libs.acp_client")
local stub = require("luassert.stub")

describe("ACPClient", function()
  local schedule_stub
  local setup_transport_stub

  before_each(function()
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn) fn() end)
    setup_transport_stub = stub(ACPClient, "_setup_transport")
  end)

  after_each(function()
    schedule_stub:revert()
    setup_transport_stub:revert()
  end)

  describe("_handle_read_text_file", function()
    it("should call error_callback when file read fails", function()
      local sent_error = nil
      local handler_called = false
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_read_file = function(path, line, limit, success_callback, err_callback)
            handler_called = true
            err_callback("File not found", ACPClient.ERROR_CODES.RESOURCE_NOT_FOUND)
          end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_read_text_file(123, { sessionId = "test-session", path = "/nonexistent/file.txt" })

      assert.is_true(handler_called)
      assert.is_not_nil(sent_error)
      assert.equals(123, sent_error.id)
      assert.equals("File not found", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.RESOURCE_NOT_FOUND, sent_error.code)
    end)

    it("should use default error message when error_callback called with nil", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_read_file = function(path, line, limit, success_callback, err_callback) err_callback(nil, nil) end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_read_text_file(456, { sessionId = "test-session", path = "/bad/file.txt" })

      assert.is_not_nil(sent_error)
      assert.equals(456, sent_error.id)
      assert.equals("Failed to read file", sent_error.message)
      assert.is_nil(sent_error.code)
    end)

    it("should call success_callback when file read succeeds", function()
      local sent_result = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_read_file = function(path, line, limit, success_callback, err_callback) success_callback("file contents") end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_result = stub().invokes(function(self, id, result) sent_result = { id = id, result = result } end)

      client:_handle_read_text_file(789, { sessionId = "test-session", path = "/existing/file.txt" })

      assert.is_not_nil(sent_result)
      assert.equals(789, sent_result.id)
      assert.equals("file contents", sent_result.result.content)
    end)

    it("should send error when params are invalid (missing sessionId)", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_read_file = function() end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_read_text_file(100, { path = "/file.txt" })

      assert.is_not_nil(sent_error)
      assert.equals(100, sent_error.id)
      assert.equals("Invalid fs/read_text_file params", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent_error.code)
    end)

    it("should send error when params are invalid (missing path)", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_read_file = function() end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_read_text_file(200, { sessionId = "test-session" })

      assert.is_not_nil(sent_error)
      assert.equals(200, sent_error.id)
      assert.equals("Invalid fs/read_text_file params", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent_error.code)
    end)

    it("should send error when handler is not configured", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {},
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_read_text_file(300, { sessionId = "test-session", path = "/file.txt" })

      assert.is_not_nil(sent_error)
      assert.equals(300, sent_error.id)
      assert.equals("fs/read_text_file handler not configured", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, sent_error.code)
    end)
  end)

  describe("_handle_write_text_file", function()
    it("should send error when params are invalid (missing sessionId)", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_write_file = function() end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_write_text_file(400, { path = "/file.txt", content = "data" })

      assert.is_not_nil(sent_error)
      assert.equals(400, sent_error.id)
      assert.equals("Invalid fs/write_text_file params", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent_error.code)
    end)

    it("should send error when params are invalid (missing path)", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_write_file = function() end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_write_text_file(500, { sessionId = "test-session", content = "data" })

      assert.is_not_nil(sent_error)
      assert.equals(500, sent_error.id)
      assert.equals("Invalid fs/write_text_file params", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent_error.code)
    end)

    it("should send error when params are invalid (missing content)", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_write_file = function() end,
        },
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_write_text_file(600, { sessionId = "test-session", path = "/file.txt" })

      assert.is_not_nil(sent_error)
      assert.equals(600, sent_error.id)
      assert.equals("Invalid fs/write_text_file params", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent_error.code)
    end)

    it("should send error when handler is not configured", function()
      local sent_error = nil
      local mock_config = {
        transport_type = "stdio",
        handlers = {},
      }

      local client = ACPClient:new(mock_config)
      client._send_error = stub().invokes(
        function(self, id, message, code) sent_error = { id = id, message = message, code = code } end
      )

      client:_handle_write_text_file(700, { sessionId = "test-session", path = "/file.txt", content = "data" })

      assert.is_not_nil(sent_error)
      assert.equals(700, sent_error.id)
      assert.equals("fs/write_text_file handler not configured", sent_error.message)
      assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, sent_error.code)
    end)
  end)

  --- Build a client whose _send_result/_send_error record into `sent`.
  local function client_recording_replies(config)
    local client = ACPClient:new(config or { transport_type = "stdio", handlers = {} })
    local sent = {}
    client._send_result = stub().invokes(function(_, id, result) sent[#sent + 1] = { id = id, result = result } end)
    client._send_error = stub().invokes(
      function(_, id, message, code) sent[#sent + 1] = { id = id, message = message, code = code } end
    )
    return client, sent
  end

  describe("unsupported inbound methods", function()
    -- Regression: unimplemented methods used to be answered with silence, which
    -- blocks the agent forever because it is waiting on the response.
    it("replies METHOD_NOT_FOUND to an unsupported request", function()
      local client, sent = client_recording_replies()

      client:_handle_notification(42, "terminal/create", { sessionId = "s1", command = "ls" })

      assert.equals(1, #sent)
      assert.equals(42, sent[1].id)
      assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, sent[1].code)
    end)

    it("stays silent for an unsupported notification", function()
      local client, sent = client_recording_replies()

      client:_handle_notification(nil, "some/unknown_notification", {})

      assert.equals(0, #sent)
    end)

    it("stays silent for $/cancel_request", function()
      local client, sent = client_recording_replies()

      client:_handle_notification(nil, "$/cancel_request", { requestId = 7 })

      assert.equals(0, #sent)
    end)
  end)

  describe("_handle_request_permission", function()
    it("cancels when no permission handler is configured", function()
      local client, sent = client_recording_replies()

      client:_handle_request_permission(1, { sessionId = "s1", toolCall = { toolCallId = "t1" }, options = {} })

      assert.equals(1, #sent)
      assert.equals("cancelled", sent[1].result.outcome.outcome)
    end)

    it("replies INVALID_PARAMS instead of hanging when toolCall is missing", function()
      local client, sent = client_recording_replies()

      client:_handle_request_permission(2, { sessionId = "s1" })

      assert.equals(1, #sent)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, sent[1].code)
    end)

    it("cancels when the handler raises", function()
      local client, sent = client_recording_replies({
        transport_type = "stdio",
        handlers = { on_request_permission = function() error("boom") end },
      })

      client:_handle_request_permission(3, { sessionId = "s1", toolCall = { toolCallId = "t1" }, options = {} })

      assert.equals(1, #sent)
      assert.equals("cancelled", sent[1].result.outcome.outcome)
    end)

    it("maps a nil option id to a cancelled outcome", function()
      local client, sent = client_recording_replies({
        transport_type = "stdio",
        handlers = { on_request_permission = function(_, _, cb) cb(nil) end },
      })

      client:_handle_request_permission(4, { sessionId = "s1", toolCall = { toolCallId = "t1" }, options = {} })

      assert.equals(1, #sent)
      assert.equals("cancelled", sent[1].result.outcome.outcome)
    end)

    it("ignores a duplicate response from the handler", function()
      local client, sent = client_recording_replies({
        transport_type = "stdio",
        handlers = {
          on_request_permission = function(_, _, cb)
            cb("opt-allow")
            cb("opt-reject")
          end,
        },
      })

      client:_handle_request_permission(5, { sessionId = "s1", toolCall = { toolCallId = "t1" }, options = {} })

      assert.equals(1, #sent)
      assert.equals("selected", sent[1].result.outcome.outcome)
      assert.equals("opt-allow", sent[1].result.outcome.optionId)
    end)
  end)

  describe("pending request lifecycle", function()
    it("resolves a callback only once", function()
      local client = ACPClient:new({ transport_type = "stdio", handlers = {} })
      local calls = 0
      client.callbacks[1] = function() calls = calls + 1 end

      client:_resolve_callback(1, {}, nil)
      client:_resolve_callback(1, {}, nil)

      assert.equals(1, calls)
    end)

    it("fails every in-flight request when the connection drops", function()
      local client = ACPClient:new({ transport_type = "stdio", handlers = {} })
      local errors = {}
      client.callbacks[1] = function(_, err) errors[#errors + 1] = err end
      client.callbacks[2] = function(_, err) errors[#errors + 1] = err end
      client.request_methods[1] = "session/prompt"
      client.request_methods[2] = "session/new"

      client:_fail_pending_requests("agent died")

      assert.equals(2, #errors)
      assert.equals(ACPClient.ERROR_CODES.CONNECTION_CLOSED, errors[1].code)
      assert.equals("agent died", errors[1].message)
      assert.same({}, client.callbacks)
    end)

    it("gives session/prompt no wall-clock deadline", function()
      -- Prompts are bounded by session/cancel and streamed updates, not by time.
      assert.equals(0, ACPClient.REQUEST_TIMEOUTS["session/prompt"])
    end)

    it("errors the callback when the transport refuses the send", function()
      local client = ACPClient:new({ transport_type = "stdio", handlers = {} })
      client.transport = { send = function() return false end }

      local err
      client:_send_request("session/new", {}, function(_, e) err = e end)

      assert.is_not_nil(err)
      assert.equals(ACPClient.ERROR_CODES.CONNECTION_CLOSED, err.code)
    end)
  end)
end)
