local stub = require("luassert.stub")
local ACPClient = require("avante.libs.acp_client")
local Config = require("avante.config")
local llm = require("avante.llm")

describe("llm._continue_stream_acp", function()
  local schedule_stub, create_session_stub, restart_stream_stub, acp_new_stub, sidebar_stub
  local saved_provider, saved_acp_providers, saved_behaviour

  before_each(function()
    create_session_stub, restart_stream_stub, acp_new_stub, sidebar_stub = nil, nil, nil, nil
    saved_provider, saved_acp_providers, saved_behaviour = Config.provider, Config.acp_providers, Config.behaviour
    Config.behaviour = Config.behaviour or {}
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn) fn() end)
  end)

  after_each(function()
    schedule_stub:revert()
    if create_session_stub then create_session_stub:revert() end
    if restart_stream_stub then restart_stream_stub:revert() end
    if acp_new_stub then acp_new_stub:revert() end
    if sidebar_stub then sidebar_stub:revert() end
    Config.provider, Config.acp_providers, Config.behaviour = saved_provider, saved_acp_providers, saved_behaviour
  end)

  local function user_message(text) return { is_user_submission = true, message = { role = "user", content = text } } end

  local function fake_client()
    local client = { prompts = {} }
    function client:send_prompt(session_id, prompt, callback)
      table.insert(self.prompts, { session_id = session_id, prompt = prompt })
      callback({ stopReason = "end_turn" }, nil)
    end
    function client:cancel_session() end
    return client
  end

  it("sends only the current user message on each turn of a session", function()
    local client = fake_client()
    local first = user_message("TURN_ONE")
    local second = user_message("TURN_TWO")
    local assistant = { message = { role = "assistant", content = "REPLY_ONE" } }
    local function send(history)
      llm._continue_stream_acp({
        acp_session_id = "s1",
        history_messages = history,
        on_stop = function() end,
      }, client, "s1")
    end

    send({ first })
    send({ first, assistant, second })

    assert.same({
      { session_id = "s1", prompt = { { type = "text", text = "TURN_ONE" } } },
      { session_id = "s1", prompt = { { type = "text", text = "TURN_TWO" } } },
    }, client.prompts)
  end)

  it("keeps selected context as content blocks without resending old turns", function()
    local client = fake_client()
    local old = user_message("OLD_TURN")
    local current = user_message("CURRENT_TURN")

    llm._continue_stream_acp({
      acp_session_id = "s1",
      history_messages = { old, current },
      selected_filepaths = { "/tmp/main.lua" },
      selected_code = { path = "/tmp/main.lua", content = "return 1", file_type = "lua" },
      on_stop = function() end,
    }, client, "s1")

    assert.same({
      { type = "resource_link", uri = "file:///tmp/main.lua", name = "main.lua" },
      {
        type = "text",
        text = "<selected_code>\n<path>/tmp/main.lua</path>\n<snippet>return 1</snippet>\n</selected_code>",
      },
      { type = "text", text = "CURRENT_TURN" },
    }, client.prompts[1].prompt)
  end)

  it("sends only the generated instruction for internal flows without a submitted message", function()
    local generate_stub = stub(llm, "generate_prompts").returns({
      system_prompt = "SYSTEM",
      messages = {
        { role = "user", content = "OLD_CONTEXT" },
        { role = "assistant", content = "OLD_REPLY" },
        { role = "user", content = "EDIT_INSTRUCTION" },
      },
    })
    local client = fake_client()

    llm._continue_stream_acp({
      acp_session_id = "s1",
      history_messages = {},
      instructions = "EDIT_INSTRUCTION",
      on_stop = function() end,
    }, client, "s1")

    generate_stub:revert()
    assert.same({ { type = "text", text = "EDIT_INSTRUCTION" } }, client.prompts[1].prompt)
  end)

  it("recreates a missing session through the connected SDK client without wrapping history", function()
    create_session_stub = stub(llm, "_create_acp_session_and_continue")
    restart_stream_stub = stub(llm, "_stream_acp")
    local client = fake_client()
    function client:send_prompt(session_id, prompt, callback)
      table.insert(self.prompts, { session_id = session_id, prompt = prompt })
      callback(nil, { kind = "session_not_found", message = "Session not found" })
    end
    local saved_session_ids = {}
    local history = {
      user_message("OLD_TURN"),
      { message = { role = "assistant", content = "OLD_REPLY" } },
      user_message("CURRENT_TURN"),
    }
    local opts = {
      acp_client = client,
      acp_session_id = "missing",
      history_messages = history,
      on_save_acp_session_id = function(session_id) table.insert(saved_session_ids, session_id) end,
      on_stop = function() error("recovery should continue with session/new") end,
    }

    llm._continue_stream_acp(opts, client, "missing")

    assert.same({ { session_id = "missing", prompt = { { type = "text", text = "CURRENT_TURN" } } } }, client.prompts)
    assert.same({ "" }, saved_session_ids)
    assert.same(history, opts.history_messages)
    assert.equals(client, opts.acp_client)
    assert.stub(create_session_stub).was_called_with(opts, client)
    assert.stub(restart_stream_stub).was_not_called()
  end)

  it("reports an error instead of repeatedly recreating a missing session", function()
    create_session_stub = stub(llm, "_create_acp_session_and_continue")
    local client = fake_client()
    local missing_error = { kind = "not_found", message = "Session not found" }
    function client:send_prompt(_, _, callback) callback(nil, missing_error) end
    local stopped

    llm._continue_stream_acp({
      acp_session_id = "new-session",
      _acp_session_recreated = true,
      history_messages = { user_message("CURRENT_TURN") },
      on_stop = function(result) stopped = result end,
    }, client, "new-session")

    assert.same({ reason = "error", error = missing_error }, stopped)
    assert.stub(create_session_stub).was_not_called()
  end)

  it("cancels a permission request when the sidebar is unavailable", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local handlers
    local client = { connect = function() end }
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      handlers = config.handlers
      return client
    end)
    sidebar_stub = stub(require("avante"), "get").returns(nil)
    llm._stream_acp({})
    local selected = "not called"

    handlers.on_request_permission({}, {}, function(option_id) selected = option_id end)

    assert.is_nil(selected)
  end)

  it("completes a live tool call that arrives already completed", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local handlers
    local messages
    local client = { connect = function() end }
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      handlers = config.handlers
      return client
    end)
    llm._stream_acp({ on_messages_add = function(value) messages = value end })

    handlers.on_session_update({
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Run",
      status = "completed",
    })

    assert.equals(2, #messages)
    assert.equals("tool_use", messages[1].message.content[1].type)
    assert.equals("tool_result", messages[2].message.content[1].type)
  end)
end)
