--- Verifies the Python-backed client is a drop-in for the Lua ACPClient.
---
--- It is driven through exactly the interface sidebar.lua and llm.lua use --
--- the same `config.handlers` table, the same method names, the same callback
--- shapes -- against a real agent through the real bridge.

local Config = require("avante.config")
local ACP = require("avante.acp")
local ACPBridge = require("avante.acp.bridge")

local plugin_root = ACPBridge.plugin_root()
local FAKE_AGENT = plugin_root .. "/python/tests/fakes/agent.py"

local function wait_for(predicate, timeout) return vim.wait(timeout or 60000, predicate, 50) end

describe("acp cutover", function()
  local python = ACPBridge.resolve_interpreter()
  if not python or vim.fn.filereadable(FAKE_AGENT) ~= 1 then
    pending("python bridge environment not available (run: cd python && uv sync)")
    return
  end

  local client

  before_each(function()
    Config.setup({})
    Config.acp_backend = "python"
  end)

  after_each(function()
    if client then pcall(function() client:stop() end) end
    client = nil
    ACPBridge.reset()
  end)

  --- Connect a client configured the way sidebar.lua configures one.
  ---@return table handlers_state
  local function connect(handler_overrides)
    local state = {
      updates = {},
      texts = {},
      permission_asked = false,
    }

    local handlers = vim.tbl_extend("force", {
      on_session_update = function(update)
        table.insert(state.updates, update)
        if update.sessionUpdate == "agent_message_chunk" then
          table.insert(state.texts, update.content and update.content.text or "")
        end
      end,
      on_request_permission = function(_tool_call, options, callback)
        state.permission_asked = true
        callback(options[1] and options[1].optionId or nil)
      end,
    }, handler_overrides or {})

    client = ACP.new({
      provider = "fake",
      command = python,
      args = { FAKE_AGENT },
      cwd = plugin_root,
      handlers = handlers,
    })

    local done, err = false, nil
    client:connect(function(e)
      err = e
      done = true
    end)
    assert.is_true(wait_for(function() return done end), "connect timed out")
    assert.is_nil(err)

    return state
  end

  local function create_session()
    local done, session_id, err = false, nil, nil
    client:create_session(plugin_root, {}, function(id, e)
      session_id, err = id, e
      done = true
    end)
    assert.is_true(wait_for(function() return done end), "create_session timed out")
    assert.is_nil(err)
    return session_id
  end

  local function prompt(session_id, text)
    local done, result, err = false, nil, nil
    client:send_prompt(session_id, { { type = "text", text = text } }, nil, function(r, e)
      result, err = r, e
      done = true
    end)
    assert.is_true(wait_for(function() return done end), "prompt timed out")
    return result, err
  end

  it("selects the python backend when the environment is present", function()
    assert.equals("python", ACP.backend())
  end)

  it("connects and reports agent capabilities", function()
    connect()

    assert.is_true(client:is_ready())
    assert.is_true(client.agent_capabilities.loadSession)
  end)

  it("creates a session and exposes modes through the legacy interface", function()
    connect()

    local session_id = create_session()

    assert.is_not_nil(session_id)
    assert.is_true(client:has_modes())
    assert.equals("agent", client:current_mode())
    assert.is_not_nil(client:mode_by_id("plan"))
    assert.equals(2, #client:all_modes())
  end)

  it("delivers session updates in the shape llm.lua expects", function()
    local state = connect()
    local session_id = create_session()

    local result, err = prompt(session_id, "say:cutover works")

    assert.is_nil(err)
    assert.equals("end_turn", result.stopReason)
    assert.is_true(vim.tbl_contains(state.texts, "cutover works"))
  end)

  it("routes permission requests to the configured handler", function()
    local state = connect()
    local session_id = create_session()

    local result = prompt(session_id, "permission")

    assert.equals("end_turn", result.stopReason)
    assert.is_true(state.permission_asked)
    assert.is_true(vim.tbl_contains(state.texts, "permission=yes"))
  end)

  it("cancels a permission request when the handler passes nil", function()
    local state = connect({
      on_request_permission = function(_tool_call, _options, callback) callback(nil) end,
    })
    local session_id = create_session()

    local result = prompt(session_id, "permission")

    assert.equals("end_turn", result.stopReason)
    assert.is_true(vim.tbl_contains(state.texts, "permission=cancelled"))
  end)

  it("runs terminal commands, which the lua backend cannot", function()
    local state = connect()
    local session_id = create_session()

    local result = prompt(session_id, "shell:echo cutover_terminal")

    assert.equals("end_turn", result.stopReason)
    assert.is_true(vim.tbl_contains(state.texts, "exit=0 out=cutover_terminal"))
  end)

  it("reads files through the editor so unsaved buffers win", function()
    local state = connect()
    local session_id = create_session()

    local path = vim.fn.tempname()
    local file = io.open(path, "w")
    file:write("on disk")
    file:close()

    prompt(session_id, "read:" .. path)

    assert.is_true(vim.tbl_contains(state.texts, "read=on disk"))
    os.remove(path)
  end)

  it("picks up handlers reassigned after connect, as llm.lua does", function()
    -- llm.lua sets `acp_client.config.handlers = handlers` before each prompt.
    connect()
    local session_id = create_session()

    local late = {}
    client.config.handlers = {
      on_session_update = function(update)
        if update.sessionUpdate == "agent_message_chunk" then
          table.insert(late, update.content.text)
        end
      end,
    }

    prompt(session_id, "say:late binding")

    assert.is_true(vim.tbl_contains(late, "late binding"))
  end)

  it("lists sessions, following pagination cursors", function()
    -- The fake agent paginates one session per page, so a client that ignored
    -- nextCursor would return only the first.
    connect()

    local done, sessions, err = false, nil, nil
    client:list_sessions({ cwd = false }, function(s, e)
      sessions, err = s, e
      done = true
    end)
    assert.is_true(wait_for(function() return done end), "list_sessions timed out")

    assert.is_nil(err)
    assert.equals(3, #sessions)
    assert.equals("listed-0", sessions[1].sessionId)
    assert.equals("listed-2", sessions[3].sessionId)
    assert.equals("Thread 0", sessions[1].title)
    assert.is_not_nil(sessions[1].updatedAt)
  end)

  it("accepts the legacy single-callback form", function()
    connect()

    local done, sessions = false, nil
    client:list_sessions(function(s)
      sessions = s
      done = true
    end)
    assert.is_true(wait_for(function() return done end))

    assert.is_true(#sessions > 0)
  end)

  it("reports an unknown session as an error rather than hanging", function()
    connect()

    local _, err = prompt("no-such-session", "say:hi")

    assert.is_not_nil(err)
    assert.equals(-32602, err.code)
  end)

  it("stops cleanly and unregisters the agent", function()
    connect()
    local agent_id = client.agent_id
    assert.is_not_nil(agent_id)

    client:stop()

    assert.is_nil(client.agent_id)
    assert.equals("disconnected", client:get_state())
  end)
end)
