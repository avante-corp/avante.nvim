local stub = require("luassert.stub")
local ACPClient = require("avante.libs.acp_client")
local Config = require("avante.config")
local FileUtils = require("avante.utils.file")
local LLMToolHelpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")
local llm = require("avante.llm")

describe("llm._continue_stream_acp", function()
  local schedule_stub, create_session_stub, restart_stream_stub, acp_new_stub, sidebar_stub, confirm_stub, root_stub
  local saved_provider, saved_acp_providers, saved_behaviour, saved_ask_opts
  local saved_cancel_autocmds

  before_each(function()
    saved_cancel_autocmds = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "User", pattern = llm.CANCEL_PATTERN })) do
      saved_cancel_autocmds[autocmd.id] = true
    end
    create_session_stub, restart_stream_stub, acp_new_stub, sidebar_stub, confirm_stub, root_stub =
      nil, nil, nil, nil, nil, nil
    saved_provider, saved_acp_providers, saved_behaviour = Config.provider, Config.acp_providers, Config.behaviour
    saved_ask_opts = Config.ask_opts
    Config.ask_opts = {}
    Config.behaviour = Config.behaviour or {}
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn) fn() end)
  end)

  after_each(function()
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "User", pattern = llm.CANCEL_PATTERN })) do
      if not saved_cancel_autocmds[autocmd.id] then vim.api.nvim_del_autocmd(autocmd.id) end
    end
    schedule_stub:revert()
    if create_session_stub then create_session_stub:revert() end
    if restart_stream_stub then restart_stream_stub:revert() end
    if acp_new_stub then acp_new_stub:revert() end
    if sidebar_stub then sidebar_stub:revert() end
    if confirm_stub then confirm_stub:revert() end
    if root_stub then root_stub:revert() end
    Config.provider, Config.acp_providers, Config.behaviour = saved_provider, saved_acp_providers, saved_behaviour
    Config.ask_opts = saved_ask_opts
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

  it("uses the submitted project's instruction file for an internal ACP request", function()
    local Path = require("avante.path")
    local Prompts = require("avante.utils.prompts")
    local original_root, other_root = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.mkdir(original_root, "p")
    vim.fn.mkdir(other_root, "p")
    vim.fn.writefile({ "ORIGINAL_PROJECT_RULES" }, original_root .. "/avante.md")
    vim.fn.writefile({ "OTHER_PROJECT_PRIVATE_RULES" }, other_root .. "/avante.md")
    local instructions_file = Config.instructions_file
    Config.instructions_file = "avante.md"
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "/bin/true" } }
    root_stub = stub(Utils.root, "get").returns(other_root)
    local replacements = {
      stub(Path.prompts, "get_templates_dir").returns(original_root),
      stub(Path.prompts, "initialize"),
      stub(Prompts, "get_agents_rules_prompt"),
      stub(Prompts, "get_cursor_rules_prompt"),
    }
    local client = fake_client()
    local ok, err = pcall(llm._continue_stream_acp, {
      acp_context = { cwd = original_root, provider = Config.acp_providers["test-acp"] },
      acp_session_id = "s1",
      history_messages = {},
      instructions = "EDIT_INSTRUCTION",
      prompt_opts = { system_prompt = "SYSTEM" },
      on_stop = function() end,
    }, client, "s1")
    for _, replacement in ipairs(replacements) do
      replacement:revert()
    end
    Config.instructions_file = instructions_file
    vim.uv.fs_unlink(original_root .. "/avante.md")
    vim.uv.fs_unlink(other_root .. "/avante.md")
    vim.uv.fs_rmdir(original_root)
    vim.uv.fs_rmdir(other_root)

    assert.is_true(ok, err)
    assert.same({ { type = "text", text = "EDIT_INSTRUCTION\nORIGINAL_PROJECT_RULES\n" } }, client.prompts[1].prompt)
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

  it("waits for cancellation acknowledgment and keeps late updates in the original turn", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local prompt_done
    local cancellations = {}
    local client = { connect = function() end, is_ready = function() return true end }
    function client:send_prompt(_, _, callback) prompt_done = callback end
    function client:cancel_session(session_id) table.insert(cancellations, session_id) end
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      client.config = config
      return client
    end)
    local first_chunks, second_chunks, stopped = {}, {}, {}
    local persist = function() return true end
    local opts = {
      acp_session_id = "s1",
      history_messages = { user_message("first turn") },
      on_save_acp_client = persist,
      on_chunk = function(chunk) table.insert(first_chunks, chunk) end,
      on_stop = function(result) table.insert(stopped, result) end,
    }
    llm._stream_acp(opts)
    llm._continue_stream_acp(opts, client, "s1")

    vim.api.nvim_exec_autocmds("User", { pattern = llm.CANCEL_PATTERN })
    local stopped_before_ack = #stopped
    client.config.handlers.on_session_update({
      sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "OLD_TAIL" },
    })
    prompt_done({ stopReason = "cancelled" }, nil)
    llm._stream_acp({
      acp_client = client,
      acp_session_id = "s1",
      history_messages = { user_message("second turn") },
      on_save_acp_client = persist,
      on_chunk = function(chunk) table.insert(second_chunks, chunk) end,
      on_stop = function(result) table.insert(stopped, result) end,
    })
    client.config.handlers.on_session_update({
      sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "NEW_TURN" },
    })
    prompt_done({ stopReason = "end_turn" }, nil)
    if client.on_dispose then client.on_dispose() end

    assert.same({ "s1" }, cancellations)
    assert.equals(0, stopped_before_ack)
    assert.matches("OLD_TAIL", table.concat(first_chunks))
    assert.same({ "NEW_TURN" }, second_chunks)
    assert.same({ { reason = "cancelled" }, { reason = "complete" } }, stopped)
  end)

  it("reports an agent-cancelled prompt as cancelled", function()
    local client = fake_client()
    function client:send_prompt(_, _, callback) callback({ stopReason = "cancelled" }, nil) end
    local stopped

    llm._continue_stream_acp({
      acp_session_id = "s1",
      history_messages = { user_message("hello") },
      on_stop = function(result) stopped = result end,
    }, client, "s1")

    assert.same({ reason = "cancelled" }, stopped)
  end)

  it("finishes a cancelled prompt once on error without recreating its session", function()
    create_session_stub = stub(llm, "_create_acp_session_and_continue")
    local client = fake_client()
    local prompt_done
    function client:send_prompt(_, _, callback) prompt_done = callback end
    local stopped = {}
    llm._continue_stream_acp({
      acp_session_id = "s1",
      history_messages = { user_message("hello") },
      on_stop = function(result) table.insert(stopped, result) end,
    }, client, "s1")

    vim.api.nvim_exec_autocmds("User", { pattern = llm.CANCEL_PATTERN })
    local stopped_before_error = #stopped
    prompt_done(nil, { kind = "session_not_found", message = "Session not found" })

    assert.equals(0, stopped_before_error)
    assert.same({ { reason = "cancelled" } }, stopped)
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

  for _, pending_stage in ipairs({ "connect", "create", "load" }) do
    it("cancels during " .. pending_stage .. " and ignores the late setup callback", function()
      Config.provider = "test-acp"
      Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
      root_stub = stub(Utils.root, "get").returns("/tmp")
      local pending
      local client = { stops = 0, prompts = 0 }
      function client:connect(done)
        if pending_stage == "connect" then
          pending = done
        else
          done(nil)
        end
      end
      function client:supports_load_session() return true end
      function client:create_session(_, _, done)
        if pending_stage == "create" then
          pending = done
        else
          done("new-session", nil)
        end
      end
      function client:load_session(_, _, _, done) pending = done end
      function client:stop(done)
        self.stops = self.stops + 1
        self.stop_requested = true
        if done then done(nil) end
      end
      function client:send_prompt(_, _, done)
        self.prompts = self.prompts + 1
        done({ stopReason = "end_turn" }, nil)
      end
      acp_new_stub = stub(ACPClient, "new").returns(client)
      local stopped, saved_sessions = {}, {}
      llm._stream_acp({
        acp_session_id = pending_stage == "load" and "saved-session" or nil,
        history_messages = { user_message("hello") },
        on_save_acp_client = function() return true end,
        on_save_acp_session_id = function(id) table.insert(saved_sessions, id) end,
        on_stop = function(result) table.insert(stopped, result) end,
      })

      llm.cancel_inflight_request()
      local stops_after_cancel = client.stops
      if pending_stage == "create" then
        pending("late-session", nil)
      else
        pending(nil, nil)
      end
      if client.on_dispose then client.on_dispose() end

      assert.equals(1, stops_after_cancel)
      assert.equals(0, client.prompts)
      assert.same({}, saved_sessions)
      assert.same({ { reason = "cancelled" } }, stopped)
    end)
  end

  for _, same_provider in ipairs({ true, false }) do
    it(
      "replaces a stale client and "
        .. (same_provider and "loads its saved session" or "clears another provider's session"),
      function()
        Config.provider = "test-acp"
        Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
        root_stub = stub(Utils.root, "get").returns("/tmp")
        local stale = {
          config = { command = same_provider and "agent" or "other-agent", args = {} },
          is_ready = function() return false end,
          update_request_context = function() end,
          stop = function() end,
        }
        local client = { created = 0, loaded = {} }
        function client:connect(done) done(nil) end
        function client:supports_load_session() return true end
        function client:create_session(_, _, done)
          self.created = self.created + 1
          done("new-session", nil)
        end
        function client:load_session(id, _, _, done)
          table.insert(self.loaded, id)
          done({}, nil)
        end
        function client:send_prompt(_, _, done) done({ stopReason = "end_turn" }, nil) end
        acp_new_stub = stub(ACPClient, "new").returns(client)
        local opts = {
          acp_client = stale,
          acp_session_id = "saved-session",
          history_messages = { user_message("hello") },
          on_save_acp_client = function() return true end,
          on_stop = function() end,
        }

        llm._stream_acp(opts)
        if client.on_dispose then client.on_dispose() end

        assert.equals(same_provider and "saved-session" or "new-session", opts.acp_session_id)
        assert.same(same_provider and { "saved-session" } or {}, client.loaded)
        assert.equals(same_provider and 0 or 1, client.created)
      end
    )
  end

  for _, importing in ipairs({ false, true }) do
    for _, failure in ipairs({ "version", "start" }) do
      it("reports a native " .. failure .. " failure to " .. (importing and "the import" or "on_stop"), function()
        Config.provider = "test-acp"
        Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
        local client = ACPClient:new({ command = "agent", handlers = {} })
        client._native_module = {
          api_version = failure == "version" and 1 or 3,
          new = function()
            return { start = function() error("native start failed") end }
          end,
        }
        client._start_polling = function() end
        acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
          client.config = config
          return client
        end)
        local stopped, failed = {}, {}
        local opts = {
          history_messages = { user_message("hello") },
          acp_session_id = importing and "s1" or nil,
          just_connect_acp_client = importing,
          on_save_acp_client = function() return true end,
          on_stop = function(result) table.insert(stopped, result) end,
          on_acp_session_load_error = importing and function(_, err) table.insert(failed, err) end or nil,
        }

        llm._stream_acp(opts)

        assert.equals(importing and 0 or 1, #stopped)
        assert.equals(importing and 1 or 0, #failed)
        local err = importing and failed[1] or stopped[1].error
        assert.equals("internal", err.kind)
        assert.matches(failure == "version" and "Incompatible avante_acp" or "native start failed", err.message)
        assert.is_true(opts.acp_request.finished)
        assert.is_nil(opts.acp_request.cancel_autocmd)
        assert.is_nil(client.on_dispose)
      end)
    end
  end

  it("exposes and registers a new client before connecting it", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local saved
    local registered
    local client = {}
    local Avante = require("avante")
    local register_stub = stub(Avante, "register_acp_client").invokes(function(_, value) registered = value end)
    local unregister_stub = stub(Avante, "unregister_acp_client")
    acp_new_stub = stub(ACPClient, "new").returns(client)
    client.connect = function()
      assert.equals(client, saved)
      assert.equals(client, registered)
    end

    llm._stream_acp({
      on_save_acp_client = function(value) saved = value end,
    })
    client.on_dispose()

    register_stub:revert()
    assert.stub(unregister_stub).was_called(1)
    unregister_stub:revert()
    assert.equals(client, saved)
  end)

  it("stops a client that has no persistent owner after the prompt", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local client = { stop = stub() }
    function client:connect(callback) callback(nil) end
    function client:supports_load_session() return false end
    function client:create_session(_, _, callback) callback("s1", nil) end
    function client:send_prompt(_, _, callback) callback({ stopReason = "end_turn" }, nil) end
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      client.config = config
      return client
    end)
    root_stub = stub(Utils.root, "get").returns(vim.uv.cwd())

    llm._stream_acp({
      acp_session_cwd = vim.uv.cwd(),
      history_messages = { user_message("hello") },
      on_stop = function() end,
    })

    assert.stub(client.stop).was_called(1)
    if client.on_dispose then client.on_dispose() end
  end)

  it("notifies on_stop once before disposing a client with an unfinished prompt", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    root_stub = stub(Utils.root, "get").returns("/tmp")
    local client = ACPClient:new({ command = "agent", handlers = {} })
    local native = {
      start = function() end,
      stop = function() end,
      new_session = function() return { operationId = 1 } end,
      prompt = function() return { operationId = 2 } end,
    }
    client._native_module = { api_version = 3, new = function() return native end }
    client._start_polling = function() end
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      client.config = config
      return client
    end)
    local stopped = {}
    llm._stream_acp({
      history_messages = { user_message("hello") },
      on_save_acp_client = function() return true end,
      on_stop = function(result) table.insert(stopped, result) end,
    })
    client:_handle_event({ type = "state_changed", state = "ready" })
    client:_handle_event({ type = "operation_completed", operationId = 1, result = { sessionId = "s1" } })

    client:stop()
    client:_handle_event({ type = "state_changed", state = "disconnected" })
    client:_handle_event({ type = "operation_failed", operationId = 2, error = { kind = "cancelled" } })

    assert.equals(1, #stopped)
    assert.equals("cancelled", stopped[1].error.kind)
    assert.is_nil(client.on_dispose)
  end)

  it("uses the current request permission context when reusing a client", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local client = {}
    function client:connect() end
    function client:is_ready() return true end
    function client:send_prompt(_, _, callback) self.prompt_callback = callback end
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      client.config = config
      return client
    end)
    sidebar_stub = stub(require("avante"), "get").returns({ update_content = function() end })
    confirm_stub = stub(LLMToolHelpers, "confirm").invokes(function(_, callback) callback(true) end)
    local persist = function() return true end

    llm._stream_acp({
      session_ctx = { always_yes = true },
      on_save_acp_client = persist,
      on_stop = function() end,
    })
    llm._stream_acp({
      acp_client = client,
      acp_session_id = "s1",
      session_ctx = {},
      history_messages = { user_message("second turn") },
      on_save_acp_client = persist,
      on_stop = function() end,
    })

    local selected
    client.config.handlers.on_request_permission({
      toolCallId = "t1",
      title = "Edit",
      kind = "edit",
      status = "pending",
    }, {
      { optionId = "once", name = "Allow", kind = "allow_once" },
      { optionId = "always", name = "Allow Always", kind = "allow_always" },
    }, function(option_id) selected = option_id end)

    assert.equals("once", selected)
    client.prompt_callback({ stopReason = "end_turn" }, nil)
    if client.on_dispose then client.on_dispose() end
  end)

  it("rejects an agent file write when the buffer has unsaved changes", function()
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    local handlers
    local client = { connect = function() end }
    acp_new_stub = stub(ACPClient, "new").invokes(function(_, config)
      handlers = config.handlers
      return client
    end)
    local write_stub = stub(FileUtils, "write_atomically").returns(true)
    local path = vim.fn.tempname()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved" })
    vim.bo[bufnr].modified = true
    local callback_error

    llm._stream_acp({})
    handlers.on_write_file(path, "agent content", function(err) callback_error = err end)

    assert.matches("unsaved changes", callback_error)
    assert.stub(write_stub).was_not_called()
    assert.is_true(vim.bo[bufnr].modified)
    assert.same({ "unsaved" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    if client.on_dispose then client.on_dispose() end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    write_stub:revert()
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
