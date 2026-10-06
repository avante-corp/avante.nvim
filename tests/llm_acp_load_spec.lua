local stub = require("luassert.stub")
local Config = require("avante.config")
local Utils = require("avante.utils")
local llm = require("avante.llm")

describe("llm._load_acp_session_and_continue", function()
  local root_stub, schedule_stub, create_stub, continue_stub
  local saved_provider, saved_acp_providers
  local mcp_servers = { { name = "fs", command = "mcp-fs", args = {} } }

  before_each(function()
    saved_provider, saved_acp_providers = Config.provider, Config.acp_providers
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {}, mcp_servers = mcp_servers } }
    root_stub = stub(Utils.root, "get").returns("/project")
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn) fn() end)
    create_stub = stub(llm, "_create_acp_session_and_continue")
    continue_stub = stub(llm, "_continue_stream_acp")
  end)

  after_each(function()
    root_stub:revert()
    schedule_stub:revert()
    create_stub:revert()
    continue_stub:revert()
    Config.provider, Config.acp_providers = saved_provider, saved_acp_providers
  end)

  ---Fake client whose session/load replays `updates` through on_replay, then answers
  ---@param updates table[]
  ---@param err? table
  local function fake_client(updates, err)
    local client = { loads = {} }
    function client:load_session(session_id, cwd, servers, callback, opts)
      table.insert(self.loads, { session_id = session_id, cwd = cwd, mcp_servers = servers, opts = opts })
      local consumed = {}
      if opts and opts.on_replay then
        for _, update in ipairs(updates) do
          table.insert(consumed, opts.on_replay(update))
        end
      end
      self.consumed = consumed
      callback(not err and {} or nil, err)
    end
    return client
  end

  local replay = {
    { sessionUpdate = "user_message_chunk", content = { type = "text", text = "Remember pineapple" } },
    { sessionUpdate = "plan", entries = {} },
    { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "OK" } },
  }

  it("delivers the replayed conversation for the loaded session before reporting it is ready", function()
    local client = fake_client(replay)
    local events = {}
    local delivered_messages

    llm._load_acp_session_and_continue({
      just_connect_acp_client = true,
      on_acp_session_replay = function(session_id, messages)
        table.insert(events, "replay:" .. session_id)
        delivered_messages = messages
      end,
      on_state_change = function(state) table.insert(events, "state:" .. state) end,
    }, client, "s1")

    assert.same({ "replay:s1", "state:initialized" }, events)
    assert.same(
      { "Remember pineapple", "OK" },
      vim.tbl_map(function(m) return m.message.content end, delivered_messages)
    )
    assert.same({ true, false, true }, client.consumed)
    assert.stub(create_stub).was_not_called()
  end)

  it("reports a failed load instead of starting a new session when the replay was requested", function()
    local client = fake_client({}, { code = -32603, message = "Session not found" })
    local load_error, replayed

    llm._load_acp_session_and_continue({
      just_connect_acp_client = true,
      on_acp_session_replay = function() replayed = true end,
      on_acp_session_load_error = function(session_id, err) load_error = { session_id = session_id, err = err } end,
    }, client, "s1")

    assert.equals("s1", load_error.session_id)
    assert.equals("Session not found", load_error.err.message)
    assert.is_nil(replayed)
    assert.stub(create_stub).was_not_called()
  end)

  it("doesn't collect the replay on a normal reload", function()
    local client = fake_client(replay)

    llm._load_acp_session_and_continue({ just_connect_acp_client = true }, client, "s1")

    -- Replayed updates then reach the normal handler, which ignores them as `_replayed`
    assert.is_nil(client.loads[1].opts)
  end)

  it("still starts a new session when a normal reopen fails to load", function()
    local client = fake_client(replay, { code = -32603, message = "Session not found" })

    llm._load_acp_session_and_continue({ just_connect_acp_client = true }, client, "s1")

    assert.stub(create_stub).was_called(1)
  end)

  it("passes the provider's MCP servers and project root to session/load", function()
    local client = fake_client({})

    llm._load_acp_session_and_continue({ just_connect_acp_client = true }, client, "s1")

    assert.equals("/project", client.loads[1].cwd)
    assert.same(mcp_servers, client.loads[1].mcp_servers)
  end)

  it("passes listed roots verbatim, including an empty list, to session/load", function()
    for _, directories in ipairs({ {}, { "/z", "/a" } }) do
      local client = fake_client({})
      llm._load_acp_session_and_continue(
        { just_connect_acp_client = true, acp_session_additional_directories = directories },
        client,
        "s1"
      )
      assert.same(directories, client.loads[1].opts.additional_directories)
    end
  end)

  it("continues the stream after loading when this is not just a preconnect", function()
    local client = fake_client({})
    local opts = { on_acp_session_replay = function() end }

    llm._load_acp_session_and_continue(opts, client, "s1")

    assert.stub(continue_stub).was_called_with(opts, client, "s1")
  end)
end)
