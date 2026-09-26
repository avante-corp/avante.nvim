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

  describe("MCP tool flow", function()
    local MCP_TOOL_UUID = "mcp-test-uuid-12345-67890"

    it("receives MCP tool result via session/update when mcp_servers configured", function()
      local sent_request = nil
      local session_updates = {}
      local client

      local mock_transport = {
        send = function(self, data)
          local decoded = vim.json.decode(data)

          if decoded.method == "session/new" then
            sent_request = decoded.params

            vim.schedule(
              function()
                client:_handle_message({
                  jsonrpc = "2.0",
                  id = decoded.id,
                  result = { sessionId = "test-session-mcp" },
                })
              end
            )
          elseif decoded.method == "session/prompt" then
            vim.schedule(
              function()
                client:_handle_message({
                  jsonrpc = "2.0",
                  method = "session/update",
                  params = {
                    sessionId = "test-session-mcp",
                    update = {
                      sessionUpdate = "tool_call",
                      toolCallId = "mcp-tool-1",
                      title = "lookup__get_code",
                      kind = "other",
                      status = "completed",
                      content = {
                        {
                          type = "content",
                          content = { type = "text", text = MCP_TOOL_UUID },
                        },
                      },
                    },
                  },
                })
              end
            )

            vim.schedule(
              function()
                client:_handle_message({
                  jsonrpc = "2.0",
                  id = decoded.id,
                  result = { stopReason = "end_turn" },
                })
              end
            )
          end
        end,
        start = function(self, on_message) end,
        stop = function(self) end,
      }

      local mock_config = {
        transport_type = "stdio",
        handlers = {
          on_session_update = function(update) table.insert(session_updates, update) end,
        },
      }

      client = ACPClient:new(mock_config)
      client.transport = mock_transport
      client.state = "ready"

      local mcp_servers = {
        { type = "http", name = "lookup", url = "http://localhost:8080/mcp" },
      }
      local session_id = nil
      client:create_session("/tmp/test", mcp_servers, function(sid, _err) session_id = sid end)

      assert.is_not_nil(sent_request)
      assert.equals("/tmp/test", sent_request.cwd)
      assert.same(mcp_servers, sent_request.mcpServers)
      assert.equals("test-session-mcp", session_id)

      client:send_prompt("test-session-mcp", { { type = "text", text = "Use the get_code tool" } }, function() end)

      assert.equals(1, #session_updates)
      assert.equals("tool_call", session_updates[1].sessionUpdate)
      assert.equals("lookup__get_code", session_updates[1].title)
      assert.equals("completed", session_updates[1].status)

      local tool_content = session_updates[1].content[1].content.text
      assert.equals(MCP_TOOL_UUID, tool_content)
    end)

    it("should default mcp_servers to empty array", function()
      local sent_params = nil
      local client

      local mock_transport = {
        send = function(self, data)
          local decoded = vim.json.decode(data)
          if decoded.method == "session/new" then
            sent_params = decoded.params
            vim.schedule(
              function()
                client:_handle_message({
                  jsonrpc = "2.0",
                  id = decoded.id,
                  result = { sessionId = "test-session" },
                })
              end
            )
          end
        end,
        start = function(_self, _on_message) end,
        stop = function(_self) end,
      }

      client = ACPClient:new({ transport_type = "stdio", handlers = {} })
      client.transport = mock_transport
      client.state = "ready"

      client:create_session("/tmp/test", nil, function() end)

      assert.is_not_nil(sent_params)
      assert.same({}, sent_params.mcpServers)
    end)
  end)

  describe("session/load replay", function()
    it("stamps session updates replayed during session/load as _replayed", function()
      local session_updates = {}
      local client

      local mock_transport = {
        send = function(self, data)
          local decoded = vim.json.decode(data)
          if decoded.method == "session/load" then
            -- Agents replay the loaded conversation before answering the request
            vim.schedule(
              function()
                client:_handle_message({
                  jsonrpc = "2.0",
                  method = "session/update",
                  params = {
                    sessionId = "test-session-load",
                    update = {
                      sessionUpdate = "agent_message_chunk",
                      content = { type = "text", text = "replayed message" },
                    },
                  },
                })
              end
            )
            vim.schedule(function() client:_handle_message({ jsonrpc = "2.0", id = decoded.id, result = {} }) end)
          end
        end,
        start = function(_self, _on_message) end,
        stop = function(_self) end,
      }

      client = ACPClient:new({
        transport_type = "stdio",
        handlers = {
          on_session_update = function(update) table.insert(session_updates, update) end,
        },
      })
      client.transport = mock_transport
      client.state = "ready"
      client.agent_capabilities = { loadSession = true }

      local loaded = false
      client:load_session("test-session-load", "/tmp/test", nil, function(_result, err)
        assert.is_nil(err)
        loaded = true
      end)

      assert.is_true(loaded)
      assert.equals(1, #session_updates)
      assert.is_true(session_updates[1]._replayed)

      client:_handle_message({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "test-session-load",
          update = {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = "live message" },
          },
        },
      })

      assert.equals(2, #session_updates)
      assert.is_nil(session_updates[2]._replayed)
    end)
  end)
end)
