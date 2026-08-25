--- Spawns the real Python bridge from Neovim and drives a real agent through it.
--- This is the only Lua test that exercises the whole stack, so it is the one
--- that catches wiring mistakes the unit specs cannot see.
---
--- Skipped when the Python environment is not set up (`cd python && uv sync`).

local Bridge = require("avante.acp.bridge")

local plugin_root = Bridge.plugin_root()
local FAKE_AGENT = plugin_root .. "/python/tests/fakes/agent.py"

local function python_available()
  local command = Bridge.resolve_interpreter()
  return command ~= nil and vim.fn.filereadable(FAKE_AGENT) == 1
end

--- Wait for `predicate` to become true, returning false on timeout.
local function wait_for(predicate, timeout)
  return vim.wait(timeout or 60000, predicate, 50)
end

describe("acp.bridge integration", function()
  if not python_available() then
    pending("python bridge environment not available (run: cd python && uv sync)")
    return
  end

  local bridge

  before_each(function() bridge = Bridge.new() end)

  after_each(function()
    if bridge then pcall(function() bridge:stop() end) end
  end)

  --- Start the bridge, returning the error if it failed.
  local function start()
    local done, err = false, nil
    bridge:register_default_handlers()
    bridge:start(function(e)
      err = e
      done = true
    end)
    assert.is_true(wait_for(function() return done end), "bridge did not start in time")
    return err
  end

  local function call(method, params, timeout)
    local done, result, err = false, nil, nil
    bridge:request(method, params, { timeout = timeout or 0 }, function(r, e)
      result, err = r, e
      done = true
    end)
    assert.is_true(wait_for(function() return done end, timeout or 60000), method .. " did not complete")
    return result, err
  end

  it("starts and completes the handshake", function()
    assert.is_nil(start())

    assert.is_true(bridge:is_running())
    assert.equals(1, bridge.info.bridgeProtocolVersion)
  end)

  it("advertises the cursor provider", function()
    assert.is_nil(start())

    local result = call("bridge/hello", {})

    assert.is_true(vim.tbl_contains(result.providers, "cursor"))
  end)

  it("runs a full prompt turn and streams events to Neovim", function()
    assert.is_nil(start())

    local events = {}
    bridge:on_event(function(event) table.insert(events, event) end)

    local spawned, spawn_err = call("agent/spawn", {
      provider = "fake",
      command = Bridge.resolve_interpreter(),
      args = { FAKE_AGENT },
      cwd = plugin_root,
    })
    assert.is_nil(spawn_err)

    local session = call("session/new", { agentId = spawned.agentId, cwd = plugin_root, mcpServers = {} })
    assert.is_not_nil(session.sessionId)

    local result = call("session/prompt", { sessionId = session.sessionId, prompt = "say:from neovim" })

    assert.equals("end_turn", result.stopReason)

    local texts = {}
    for _, event in ipairs(events) do
      if event.kind == "agent_message_chunk" then table.insert(texts, event.update.content.text) end
    end
    assert.is_true(vim.tbl_contains(texts, "from neovim"))
  end)

  it("answers a permission request from the editor", function()
    assert.is_nil(start())

    local asked = false
    bridge:on("ui/permission", function(_, reply)
      asked = true
      reply({ optionId = "yes" })
    end)

    local spawned = call("agent/spawn", {
      provider = "fake",
      command = Bridge.resolve_interpreter(),
      args = { FAKE_AGENT },
      cwd = plugin_root,
    })
    local session = call("session/new", { agentId = spawned.agentId, cwd = plugin_root, mcpServers = {} })

    local result = call("session/prompt", { sessionId = session.sessionId, prompt = "permission" })

    assert.equals("end_turn", result.stopReason)
    assert.is_true(asked)
  end)

  it("runs a terminal command without involving Neovim", function()
    -- The case that used to hang forever: the old Lua client never answered
    -- terminal/create at all.
    assert.is_nil(start())

    local spawned = call("agent/spawn", {
      provider = "fake",
      command = Bridge.resolve_interpreter(),
      args = { FAKE_AGENT },
      cwd = plugin_root,
    })
    local session = call("session/new", { agentId = spawned.agentId, cwd = plugin_root, mcpServers = {} })

    local events = {}
    bridge:on_event(function(event) table.insert(events, event) end)

    local result = call("session/prompt", { sessionId = session.sessionId, prompt = "shell:echo neovim_terminal" })

    assert.equals("end_turn", result.stopReason)
    local texts = {}
    for _, event in ipairs(events) do
      if event.kind == "agent_message_chunk" then table.insert(texts, event.update.content.text) end
    end
    assert.is_true(vim.tbl_contains(texts, "exit=0 out=neovim_terminal"))
  end)

  it("surfaces an unknown session as an error rather than hanging", function()
    assert.is_nil(start())

    local _, err = call("session/prompt", { sessionId = "nope", prompt = "say:hi" }, 30000)

    assert.is_not_nil(err)
    assert.equals(-32602, err.code)
  end)

  it("auto-starts when a request arrives without an explicit start", function()
    -- Several call sites (thread viewer, config option selector, session
    -- restore) reach the bridge without starting it. That used to fail with
    -- "ACP bridge is not running", which is not actionable.
    bridge:register_default_handlers()

    local done, result, err = false, nil, nil
    bridge:request("bridge/hello", {}, { timeout = 0 }, function(r, e)
      result, err = r, e
      done = true
    end)

    assert.is_true(wait_for(function() return done end), "auto-start did not complete")
    assert.is_nil(err)
    assert.equals(1, result.bridgeProtocolVersion)
    assert.is_true(bridge:is_running())
  end)

  it("restarts after the bridge process dies", function()
    assert.is_nil(start())
    bridge:stop()
    assert.is_false(bridge:is_running())

    local done, result, err = false, nil, nil
    bridge:request("bridge/hello", {}, { timeout = 0 }, function(r, e)
      result, err = r, e
      done = true
    end)

    assert.is_true(wait_for(function() return done end), "restart did not complete")
    assert.is_nil(err)
    assert.equals(1, result.bridgeProtocolVersion)
  end)

  it("fails in-flight requests when the bridge process dies", function()
    assert.is_nil(start())

    local done, err = false, nil
    bridge:request("session/prompt", { sessionId = "nope", prompt = "x" }, { timeout = 0 }, function(_, e)
      err = e
      done = true
    end)
    bridge:stop()

    assert.is_true(wait_for(function() return done end, 10000))
    assert.is_not_nil(err)
  end)
end)
