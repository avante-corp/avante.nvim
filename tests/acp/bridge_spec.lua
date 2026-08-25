local Bridge = require("avante.acp.bridge")
local stub = require("luassert.stub")

--- Build a bridge whose _send records outbound frames instead of writing to a pipe.
local function recording_bridge()
  local bridge = Bridge.new()
  bridge:register_default_handlers()
  -- Stand in for a live process: requests auto-start the bridge when it is not
  -- running, which would spawn a real one here.
  bridge.state = "running"
  local sent = {}
  bridge._send = function(_, message)
    table.insert(sent, message)
    return true
  end
  return bridge, sent
end

describe("acp.bridge", function()
  describe("interpreter resolution", function()
    it("honours an explicit acp_python setting", function()
      local Config = require("avante.config")
      local previous = Config.acp_python
      Config.acp_python = "/custom/python"

      local command, args = Bridge.resolve_interpreter()

      Config.acp_python = previous
      assert.equals("/custom/python", command)
      assert.same({ "-m", "avante_acp" }, args)
    end)

    it("points at the python project inside the plugin", function()
      assert.is_true(vim.fn.isdirectory(Bridge.plugin_root() .. "/python") == 1)
    end)
  end)

  describe("outbound requests", function()
    it("sends a JSON-RPC request with an incrementing id", function()
      local bridge, sent = recording_bridge()

      bridge:request("bridge/hello", {}, {}, function() end)
      bridge:request("agent/status", {}, {}, function() end)

      assert.equals("bridge/hello", sent[1].method)
      assert.equals(1, sent[1].id)
      assert.equals(2, sent[2].id)
    end)

    it("resolves the matching callback when a response arrives", function()
      local bridge, sent = recording_bridge()
      local got

      bridge:request("agent/status", {}, {}, function(result) got = result end)
      bridge:_handle_message({ jsonrpc = "2.0", id = sent[1].id, result = { agents = {} } })

      assert.same({ agents = {} }, got)
    end)

    it("routes concurrent responses to their own callbacks", function()
      local bridge, sent = recording_bridge()
      local first, second

      bridge:request("a", {}, {}, function(r) first = r end)
      bridge:request("b", {}, {}, function(r) second = r end)
      -- Answer out of order.
      bridge:_handle_message({ jsonrpc = "2.0", id = sent[2].id, result = "second" })
      bridge:_handle_message({ jsonrpc = "2.0", id = sent[1].id, result = "first" })

      assert.equals("first", first)
      assert.equals("second", second)
    end)

    it("surfaces error responses to the caller", function()
      local bridge, sent = recording_bridge()
      local err

      bridge:request("session/prompt", {}, {}, function(_, e) err = e end)
      bridge:_handle_message({
        jsonrpc = "2.0",
        id = sent[1].id,
        error = { code = -32602, message = "Unknown sessionId" },
      })

      assert.equals(-32602, err.code)
      assert.equals("Unknown sessionId", err.message)
    end)

    it("resolves a callback only once", function()
      local bridge, sent = recording_bridge()
      local calls = 0

      bridge:request("a", {}, {}, function() calls = calls + 1 end)
      bridge:_handle_message({ jsonrpc = "2.0", id = sent[1].id, result = {} })
      bridge:_handle_message({ jsonrpc = "2.0", id = sent[1].id, result = {} })

      assert.equals(1, calls)
    end)

    it("errors the callback when the transport refuses the send", function()
      local bridge = Bridge.new()
      bridge.state = "running"
      bridge._send = function() return false end
      local err

      bridge:request("agent/status", {}, {}, function(_, e) err = e end)

      assert.equals(Bridge.ERROR_CODES.CONNECTION_CLOSED, err.code)
    end)

    it("does not retry forever when the bridge cannot be started", function()
      -- The auto-start path must terminate, not recurse.
      local bridge = Bridge.new()
      local starts = 0
      bridge.start = function(_, cb)
        starts = starts + 1
        cb({ code = Bridge.ERROR_CODES.INTERNAL_ERROR, message = "no interpreter" })
      end
      local err

      bridge:request("agent/status", {}, {}, function(_, e) err = e end)

      assert.equals(1, starts)
      assert.equals("no interpreter", err.message)
    end)

    it("exempts prompts and authentication from deadlines", function()
      -- Both are bounded by user or agent action, so a clock would be wrong.
      assert.is_true(Bridge.NO_DEADLINE["session/prompt"])
      assert.is_true(Bridge.NO_DEADLINE["agent/authenticate"])
    end)

    it("fails every in-flight request when the bridge dies", function()
      local bridge, _ = recording_bridge()
      local errors = {}

      bridge:request("a", {}, {}, function(_, e) table.insert(errors, e) end)
      bridge:request("b", {}, {}, function(_, e) table.insert(errors, e) end)
      bridge:_fail_pending("bridge exited")

      assert.equals(2, #errors)
      assert.equals(Bridge.ERROR_CODES.CONNECTION_CLOSED, errors[1].code)
      assert.equals("bridge exited", errors[1].message)
      assert.same({}, bridge.callbacks)
    end)
  end)

  describe("inbound calls", function()
    it("replies METHOD_NOT_FOUND to an unknown request", function()
      local bridge, sent = recording_bridge()

      bridge:_handle_message({ jsonrpc = "2.0", id = 7, method = "ui/unknown", params = {} })

      assert.equals(7, sent[1].id)
      assert.equals(Bridge.ERROR_CODES.METHOD_NOT_FOUND, sent[1].error.code)
    end)

    it("stays silent for an unknown notification", function()
      local bridge, sent = recording_bridge()

      bridge:_handle_message({ jsonrpc = "2.0", method = "ui/unknown", params = {} })

      assert.equals(0, #sent)
    end)

    it("replies exactly once even if the handler answers twice", function()
      local bridge, sent = recording_bridge()
      bridge:on("ui/permission", function(_, reply)
        reply({ optionId = "yes" })
        reply({ optionId = "no" })
      end)

      bridge:_handle_message({ jsonrpc = "2.0", id = 3, method = "ui/permission", params = {} })

      assert.equals(1, #sent)
      assert.equals("yes", sent[1].result.optionId)
    end)

    it("replies with an error when the handler raises", function()
      local bridge, sent = recording_bridge()
      bridge:on("ui/permission", function() error("boom") end)

      bridge:_handle_message({ jsonrpc = "2.0", id = 4, method = "ui/permission", params = {} })

      assert.equals(1, #sent)
      assert.equals(Bridge.ERROR_CODES.INTERNAL_ERROR, sent[1].error.code)
    end)
  end)

  describe("events", function()
    it("fans out events to subscribers", function()
      local bridge = recording_bridge()
      local seen = {}
      bridge:on_event(function(event) table.insert(seen, event.kind) end)

      bridge:_handle_message({
        jsonrpc = "2.0",
        method = "event",
        params = { agentId = "agent-1", kind = "agent_message_chunk" },
      })

      assert.same({ "agent_message_chunk" }, seen)
    end)

    it("unsubscribes cleanly", function()
      local bridge = recording_bridge()
      local count = 0
      local unsubscribe = bridge:on_event(function() count = count + 1 end)

      bridge:_handle_message({ jsonrpc = "2.0", method = "event", params = { kind = "a" } })
      unsubscribe()
      bridge:_handle_message({ jsonrpc = "2.0", method = "event", params = { kind = "b" } })

      assert.equals(1, count)
    end)

    it("keeps dispatching when one subscriber raises", function()
      local bridge = recording_bridge()
      local reached = false
      bridge:on_event(function() error("bad subscriber") end)
      bridge:on_event(function() reached = true end)

      bridge:_handle_message({ jsonrpc = "2.0", method = "event", params = { kind = "a" } })

      assert.is_true(reached)
    end)
  end)

  describe("filesystem handlers", function()
    it("reads a file through the editor", function()
      local bridge, sent = recording_bridge()
      local path = vim.fn.tempname()
      local file = io.open(path, "w")
      file:write("hello from disk")
      file:close()

      bridge:_handle_message({
        jsonrpc = "2.0",
        id = 10,
        method = "fs/read",
        params = { path = path },
      })

      assert.equals("hello from disk", sent[1].result.content)
      os.remove(path)
    end)

    it("reports a missing file as an error rather than empty content", function()
      local bridge, sent = recording_bridge()

      bridge:_handle_message({
        jsonrpc = "2.0",
        id = 11,
        method = "fs/read",
        params = { path = "/definitely/not/here.txt" },
      })

      assert.is_not_nil(sent[1].error)
    end)

    it("writes a file", function()
      local bridge, sent = recording_bridge()
      local path = vim.fn.tempname()

      bridge:_handle_message({
        jsonrpc = "2.0",
        id = 12,
        method = "fs/write",
        params = { path = path, content = "written" },
      })

      assert.is_nil(sent[1].error)
      local file = io.open(path, "r")
      assert.equals("written", file:read("*a"))
      file:close()
      os.remove(path)
    end)
  end)

  describe("singleton", function()
    it("returns the same bridge and resets cleanly", function()
      local first = Bridge.get()
      assert.equals(first, Bridge.get())

      Bridge.reset()

      assert.are_not.equal(first, Bridge.get())
      Bridge.reset()
    end)
  end)
end)

describe("acp.bridge disconnect", function()
  local Bridge = require("avante.acp.bridge")

  it("notifies subscribers when the process exits", function()
    -- Agent ids belong to the bridge process; holders must be told to drop them.
    local bridge = Bridge.new()
    local reasons = {}
    bridge:on_disconnect(function(reason) table.insert(reasons, reason) end)

    bridge:_on_exit(0, 15)

    assert.equals(1, #reasons)
    assert.is_not_nil(reasons[1]:find("signal=15", 1, true))
  end)

  it("notifies subscribers on an explicit stop", function()
    local bridge = Bridge.new()
    local called = false
    bridge:on_disconnect(function() called = true end)

    bridge:stop()

    assert.is_true(called)
  end)

  it("unsubscribes cleanly", function()
    local bridge = Bridge.new()
    local count = 0
    local unsubscribe = bridge:on_disconnect(function() count = count + 1 end)

    bridge:stop()
    unsubscribe()
    bridge:_on_exit(0, 15)

    assert.equals(1, count)
  end)

  it("keeps notifying when one subscriber raises", function()
    local bridge = Bridge.new()
    local reached = false
    bridge:on_disconnect(function() error("bad subscriber") end)
    bridge:on_disconnect(function() reached = true end)

    bridge:stop()

    assert.is_true(reached)
  end)

  it("fails in-flight requests before notifying", function()
    local bridge = Bridge.new()
    bridge.state = "running"
    bridge._send = function() return true end
    local err
    bridge:request("session/prompt", {}, { timeout = 0 }, function(_, e) err = e end)

    bridge:stop()

    assert.equals(Bridge.ERROR_CODES.CONNECTION_CLOSED, err.code)
  end)
end)
