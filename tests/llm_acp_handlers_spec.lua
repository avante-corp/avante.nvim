local Config = require("avante.config")
local Llm = require("avante.llm")
local Avante = require("avante")
local stub = require("luassert.stub")
local Confirm = require("avante.ui.confirm")
local Helpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")

describe("ACP stream handlers", function()
  local provider, providers, behaviour, original_tab, sidebars, current, clients, created_tabs, render_stubs, saved_popups, ask_opts
  local saved_commands, saved_cmp, saved_cmp_loader, saved_commands_source

  before_each(function()
    provider, providers, behaviour = Config.provider, Config.acp_providers, Config.behaviour
    ask_opts = Config.ask_opts
    Config.ask_opts = {}
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent" } }
    Config.behaviour = { confirmation_ui_style = "inline_buttons", auto_approve_tool_permissions = false }
    original_tab = vim.api.nvim_get_current_tabpage()
    sidebars, current = vim.tbl_extend("force", {}, Avante.sidebars), vim.tbl_extend("force", {}, Avante.current)
    clients, created_tabs = {}, {}
    render_stubs, saved_popups = {}, Helpers.confirm_popups
    Helpers.confirm_popups = {}
    saved_commands, saved_cmp = Config.slash_commands, package.loaded.cmp
    saved_cmp_loader, saved_commands_source = package.preload.cmp, Avante.slash_commands_id
    Config.slash_commands = {}
  end)

  after_each(function()
    for _, client in ipairs(clients) do
      client:force_stop()
    end
    for _, replacement in ipairs(render_stubs) do
      replacement:revert()
    end
    Helpers.confirm_popups = saved_popups
    for _, tab in ipairs(created_tabs) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd("noautocmd tabclose!")
      end
    end
    vim.api.nvim_set_current_tabpage(original_tab)
    Avante.sidebars, Avante.current = sidebars, current
    Config.provider, Config.acp_providers, Config.behaviour = provider, providers, behaviour
    Config.ask_opts = ask_opts
    Config.slash_commands, package.loaded.cmp = saved_commands, saved_cmp
    package.preload.cmp, Avante.slash_commands_id = saved_cmp_loader, saved_commands_source
  end)

  local function sidebar()
    local owner = {
      update_content = function() end,
      containers = { input = { winid = vim.api.nvim_get_current_win() } },
      chat_history = { acp_session_id = "s1", messages = {} },
    }
    Avante.sidebars[vim.api.nvim_get_current_tabpage()] = owner
    return owner
  end

  local function start_request(owner, extra)
    local client
    local opts = vim.tbl_extend("force", {
      acp_sidebar = owner,
      history_messages = { { is_user_submission = true, message = { role = "user", content = "hello" } } },
      acp_session_id = "s1",
      acp_session_cwd = "/tmp",
      session_ctx = {},
      on_save_acp_client = function(value)
        client = value
        owner.acp_client = value
        if value._native_module then return true end
        table.insert(clients, value)
        local events = {
          { type = "initialized", supportsLoadSession = true },
          { type = "state_changed", state = "ready" },
        }
        local operation_id = 0
        local native = {
          start = function() end,
          force_stop = function() end,
          stop = function() table.insert(events, { type = "state_changed", state = "disconnected" }) end,
          poll = function()
            local pending = events
            events = {}
            return pending
          end,
          load_session = function()
            operation_id = operation_id + 1
            table.insert(events, { type = "operation_completed", operationId = operation_id, result = {} })
            return { operationId = operation_id }
          end,
          prompt = function()
            operation_id = operation_id + 1
            return { operationId = operation_id }
          end,
        }
        value._native_module = { api_version = 3, new = function() return native end }
        return true
      end,
    }, extra or {})
    Llm._stream_acp(opts)
    client = client or opts.acp_client
    assert.is_true(vim.wait(500, function() return client.active_session_id == "s1" end, 5))
    return client, opts
  end

  local permission_options = {
    { optionId = "approve-123", name = "Approve once", kind = "allow_once" },
    { optionId = "approve-alternative", name = "Approve with alternative scope", kind = "allow_once" },
    { optionId = "approve-all", name = "Approve always", kind = "allow_always" },
    { optionId = "deny-456", name = "Deny once", kind = "reject_once" },
    { optionId = "deny-all", name = "Deny always", kind = "reject_always" },
  }
  local tool = { toolCallId = "call1", title = "Write settings", kind = "edit", status = "pending" }

  for _, selected in ipairs({ "approve-123", "approve-alternative", "approve-all", "deny-456", "deny-all" }) do
    it("returns the selected ACP permission ID unchanged: " .. selected, function()
      local owner = sidebar()
      local client, opts = start_request(owner)
      local replied, response = false, nil
      client.config.handlers.on_request_permission(tool, permission_options, function(id)
        replied, response = true, id
      end)

      owner.permission_handler(selected)

      assert.is_true(vim.wait(500, function() return replied end, 5))
      assert.equals(selected, response)
      assert.is_not_true(opts.session_ctx.always_yes)
    end)
  end

  it("does not approve a reject_once option with an allow-looking ID", function()
    local owner = sidebar()
    local client = start_request(owner)
    local replied, response = false, nil
    client.config.handlers.on_request_permission(tool, {
      { optionId = "approve-123", name = "Approve", kind = "allow_once" },
      { optionId = "allow_once", name = "Reject", kind = "reject_once" },
    }, function(id)
      replied, response = true, id
    end)

    owner.permission_handler("allow_once")

    assert.is_true(vim.wait(500, function() return replied end, 5))
    assert.equals("allow_once", response)
  end)

  it("keeps permission controls on the owning tab without replacing another tab's pending request", function()
    local owner = sidebar()
    local client = start_request(owner)
    vim.cmd("noautocmd tabnew")
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
    local other = sidebar()
    local other_handler = function() end
    local other_options = { { id = "other-approval", name = "Other approval" } }
    other.permission_handler, other.permission_button_options = other_handler, other_options
    local replied, response = false, nil

    client.config.handlers.on_request_permission(tool, permission_options, function(id)
      replied, response = true, id
    end)

    assert.equals(other_handler, other.permission_handler)
    assert.equals(other_options, other.permission_button_options)
    assert.is_function(owner.permission_handler)
    owner.permission_handler("approve-123")
    assert.is_true(vim.wait(500, function() return replied end, 5))
    assert.equals("approve-123", response)
  end)

  for _, separator in ipairs({ "tool", "thinking" }) do
    it("delivers all text and subsequent increments after " .. separator .. " separates assistant messages", function()
      local chunks = {}
      local client = start_request(sidebar(), { on_chunk = function(chunk) table.insert(chunks, chunk) end })
      local update = client.config.handlers.on_session_update
      update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Before." } })
      if separator == "tool" then
        update({ sessionUpdate = "tool_call", toolCallId = "read1", kind = "read", status = "completed" })
      else
        update({ sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "Thinking." } })
      end
      update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "After." } })
      update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = " More." } })

      assert.same({ "Before.", "After.", " More." }, chunks)
    end)
  end

  it("keeps simultaneous permission popups in different tabs available for independent answers", function()
    Config.behaviour.confirmation_ui_style = "popup"
    local popups = {}
    table.insert(
      render_stubs,
      stub(Confirm, "open").invokes(function(self)
        self.visible = true
        table.insert(popups, self)
      end)
    )
    table.insert(render_stubs, stub(Confirm, "close").invokes(function(self) self.visible = false end))
    local first = start_request(sidebar())
    local first_answer, second_answer
    first.config.handlers.on_request_permission(tool, permission_options, function(id) first_answer = id end)
    vim.cmd("noautocmd tabnew")
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
    local second = start_request(sidebar())
    second.config.handlers.on_request_permission(tool, permission_options, function(id) second_answer = id end)

    assert.is_true(popups[1].visible)
    assert.is_true(popups[2].visible)
    popups[1].callback("no")
    popups[2].callback("all")
    assert.is_true(vim.wait(500, function() return first_answer ~= nil and second_answer ~= nil end, 5))
    assert.equals("deny-456", first_answer)
    assert.equals("approve-all", second_answer)
  end)

  it("routes text to the next request when reusing a connected client", function()
    local owner = sidebar()
    local first_chunks, second_chunks = {}, {}
    local client = start_request(owner, { on_chunk = function(chunk) table.insert(first_chunks, chunk) end })
    client.config.handlers.on_session_update({
      sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "First reply." },
    })
    client:_handle_event({ type = "operation_completed", operationId = 2, result = { stopReason = "end_turn" } })
    start_request(owner, {
      acp_client = client,
      on_chunk = function(chunk) table.insert(second_chunks, chunk) end,
    })
    client.config.handlers.on_session_update({
      sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "Next." },
    })

    assert.same({ "First reply." }, first_chunks)
    assert.same({ "Next." }, second_chunks)
  end)

  it("does not append another session's updates to the active conversation", function()
    local chunks = {}
    local client = start_request(sidebar(), { on_chunk = function(chunk) table.insert(chunks, chunk) end })
    client:_handle_event({
      type = "session_update",
      notification = {
        sessionId = "different-session",
        update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Foreign reply" } },
      },
    })

    assert.same({}, chunks)
  end)

  it("does not deliver a queued plan to the next request on a reused client", function()
    local owner = sidebar()
    local client = start_request(owner, { update_todos = function() end })
    client:_handle_event({
      type = "session_update",
      notification = {
        sessionId = "s1",
        update = {
          sessionUpdate = "plan",
          entries = { { content = "Original request task", status = "pending", priority = "medium" } },
        },
      },
    })
    client:_handle_event({ type = "operation_completed", operationId = 2, result = { stopReason = "end_turn" } })
    local received = {}
    start_request(owner, {
      acp_client = client,
      update_todos = function(todos) table.insert(received, todos) end,
    })
    local flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(500, function() return flushed end, 5))

    assert.same({}, received)
  end)

  it("does not send a user prompt while the sidebar's session is still loading", function()
    local owner = sidebar()
    local client, premature_prompt = nil, false
    local function save_client(value)
      client = value
      if not value._native_module then
        table.insert(clients, value)
        local native = {
          start = function() end,
          stop = function() end,
          force_stop = function() end,
          poll = function() return {} end,
          load_session = function() return { operationId = 1 } end,
          prompt = function()
            premature_prompt = true
            return { operationId = 2 }
          end,
        }
        value._native_module = { api_version = 3, new = function() return native end }
      end
      return true
    end
    Llm._stream_acp({
      acp_sidebar = owner,
      acp_session_id = "s1",
      just_connect_acp_client = true,
      on_save_acp_client = save_client,
    })
    client:_handle_event({ type = "initialized", supportsLoadSession = true })
    client:_handle_event({ type = "state_changed", state = "ready" })
    Llm._stream_acp({
      acp_sidebar = owner,
      acp_client = client,
      acp_session_id = "s1",
      history_messages = { { is_user_submission = true, message = { role = "user", content = "Hello" } } },
      on_save_acp_client = save_client,
    })

    assert.is_false(premature_prompt)
  end)

  local function fake_completion_source()
    package.loaded.cmp = {
      register_source = function() return 1 end,
      unregister_source = function() end,
    }
  end

  local function agent_command_names()
    local names = {}
    for _, command in ipairs(Utils.get_commands()) do
      if command.name:match("^agent%-") then table.insert(names, command.name) end
    end
    table.sort(names)
    return names
  end

  local function update_commands(client, commands)
    client:_handle_event({
      type = "session_update",
      notification = {
        sessionId = client.active_session_id,
        update = { sessionUpdate = "available_commands_update", availableCommands = commands },
      },
    })
  end

  it("makes agent slash commands available without nvim-cmp", function()
    package.loaded.cmp = nil
    package.preload.cmp = function() error("nvim-cmp is not installed") end
    local client = start_request(sidebar())
    update_commands(client, { { name = "agent-review", description = "Review changes" } })

    assert.same({ "agent-review" }, agent_command_names())
  end)

  it("replaces agent slash commands when the available list changes", function()
    fake_completion_source()
    local client = start_request(sidebar())
    for _, name in ipairs({ "agent-old", "agent-current" }) do
      update_commands(client, { { name = name, description = name } })
    end

    assert.same({ "agent-current" }, agent_command_names())
  end)

  it("does not expose one tab's agent slash commands in another tab", function()
    fake_completion_source()
    local client = start_request(sidebar())
    update_commands(client, { { name = "agent-private", description = "Owner session command" } })
    vim.cmd("noautocmd tabnew")
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
    sidebar()

    assert.same({}, agent_command_names())
  end)

  for _, operation in ipairs({ "create", "load" }) do
    it("keeps the original project and MCP servers when " .. operation .. " follows delayed initialization", function()
      Config.behaviour.use_cwd_as_project_root = true
      Config.acp_providers["test-acp"].mcp_servers =
        { { name = "original", command = "/bin/true", args = {}, env = {} } }
      Config.acp_providers.other =
        { command = "/bin/true", mcp_servers = { { name = "other", command = "/bin/true", args = {}, env = {} } } }
      local cwd = Utils.root.get()
      local expected_servers = vim.deepcopy(Config.acp_providers["test-acp"].mcp_servers)
      local client, setup
      local native = {
        start = function() end,
        force_stop = function() end,
        poll = function() return {} end,
        new_session = function(_, params)
          setup = params
          return { operationId = 1 }
        end,
        load_session = function(_, _, params)
          setup = params
          return { operationId = 1 }
        end,
      }
      Llm._stream_acp({
        acp_sidebar = sidebar(),
        just_connect_acp_client = true,
        acp_session_id = operation == "load" and "s1" or nil,
        on_save_acp_client = function(value)
          if not client then table.insert(clients, value) end
          client = value
          value._native_module = { api_version = 3, new = function() return native end }
          return true
        end,
      })
      vim.cmd("noautocmd tabnew")
      table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
      vim.cmd("tcd /tmp")
      Config.provider = "other"

      client:_handle_event({ type = "initialized", supportsLoadSession = true })
      client:_handle_event({ type = "state_changed", state = "ready" })

      assert.is_not_nil(setup)
      assert.equals(cwd, setup.cwd)
      assert.same(expected_servers, setup.mcpServers)
    end)
  end

  it("keeps selected relative file links in the submitted project after delayed initialization", function()
    Config.behaviour.use_cwd_as_project_root = true
    local cwd = Utils.root.get()
    local client, prompt
    local native = {
      start = function() end,
      force_stop = function() end,
      poll = function() return {} end,
      new_session = function() return { operationId = 1 } end,
      prompt = function(_, _, blocks)
        prompt = blocks
        return { operationId = 2 }
      end,
    }
    Llm._stream_acp({
      acp_sidebar = sidebar(),
      selected_filepaths = { "src/original.lua" },
      history_messages = { { is_user_submission = true, message = { role = "user", content = "Review this file" } } },
      on_save_acp_client = function(value)
        if not client then table.insert(clients, value) end
        client = value
        value._native_module = { api_version = 3, new = function() return native end }
        return true
      end,
    })
    vim.cmd("noautocmd tabnew")
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
    vim.cmd("tcd /tmp")
    client:_handle_event({ type = "initialized", supportsLoadSession = true })
    client:_handle_event({ type = "state_changed", state = "ready" })
    client:_handle_event({ type = "operation_completed", operationId = 1, result = { sessionId = "s1" } })

    assert.equals("file://" .. cwd .. "/src/original.lua", prompt[1].uri)
  end)

  it("does not follow an agent edit in an unrelated tab's code window", function()
    Config.behaviour.acp_follow_agent_locations = true
    local original_navigation_time = vim.g.avante_last_auto_nav
    vim.g.avante_last_auto_nav = nil
    local owner = sidebar()
    owner.code = { winid = vim.api.nvim_get_current_win() }
    local owner_original_buffer = vim.api.nvim_win_get_buf(owner.code.winid)
    owner.is_open = function() return true end
    local client = start_request(owner)
    vim.cmd("noautocmd tabnew")
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
    local other = sidebar()
    other.code = { winid = vim.api.nvim_get_current_win() }
    other.is_open = function() return true end
    local original_buffer = vim.api.nvim_win_get_buf(other.code.winid)
    local target_buffer = vim.api.nvim_create_buf(false, true)
    local target_path = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(target_buffer, target_path)
    client.config.handlers.on_session_update({
      sessionUpdate = "tool_call",
      toolCallId = "edit-other-tab",
      title = "Edit owner file",
      kind = "edit",
      status = "in_progress",
      locations = { { path = target_path, line = 1 } },
    })
    local flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(500, function() return flushed end, 5))
    local actual_buffer = vim.api.nvim_win_get_buf(other.code.winid)
    vim.api.nvim_win_set_buf(owner.code.winid, owner_original_buffer)
    vim.api.nvim_buf_delete(target_buffer, { force = true })
    vim.g.avante_last_auto_nav = original_navigation_time

    assert.equals(original_buffer, actual_buffer)
  end)

  it("discards queued navigation when its sidebar stops the old client", function()
    Config.behaviour.acp_follow_agent_locations = true
    local owner = sidebar()
    owner.acp_client_generation = 0
    owner.code = { winid = vim.api.nvim_get_current_win() }
    owner.is_open = function() return true end
    local original_buffer = vim.api.nvim_win_get_buf(owner.code.winid)
    local client = start_request(owner)
    local target_buffer = vim.api.nvim_create_buf(false, true)
    local target_path = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(target_buffer, target_path)
    client:_handle_event({
      type = "session_update",
      notification = {
        sessionId = "s1",
        update = {
          sessionUpdate = "tool_call",
          toolCallId = "edit-before-stop",
          title = "Edit old chat file",
          kind = "edit",
          status = "in_progress",
          locations = { { path = target_path, line = 1 } },
        },
      },
    })
    require("avante.sidebar").stop_acp_client(owner)
    owner.chat_history = { acp_session_id = "new-chat", messages = {} }
    local flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(500, function() return flushed end, 5))
    local actual_buffer = vim.api.nvim_win_get_buf(owner.code.winid)
    vim.api.nvim_win_set_buf(owner.code.winid, original_buffer)
    vim.api.nvim_buf_delete(target_buffer, { force = true })

    assert.equals(original_buffer, actual_buffer)
  end)

  it("cancels a superseded inline permission exactly once", function()
    local owner = sidebar()
    local client = start_request(owner)
    local first, second = {}, {}
    client.config.handlers.on_request_permission(
      tool,
      permission_options,
      function(id) table.insert(first, { id = id }) end
    )
    local stale_handler = owner.permission_handler
    client.config.handlers.on_request_permission(
      vim.tbl_extend("force", tool, { toolCallId = "call2" }),
      permission_options,
      function(id) table.insert(second, { id = id }) end
    )
    assert.is_true(vim.wait(500, function() return #first == 1 end, 5))
    assert.is_nil(first[1].id)
    stale_handler("approve-123")
    owner.permission_handler("approve-123")
    assert.is_true(vim.wait(500, function() return #second == 1 end, 5))
    assert.equals(1, #first)
    assert.equals("approve-123", second[1].id)
  end)

  it("does not let a stale inline click clear the replacement permission", function()
    local owner = sidebar()
    local client = start_request(owner)
    local first = {}
    client.config.handlers.on_request_permission(
      tool,
      permission_options,
      function(id) table.insert(first, { id = id }) end
    )
    local stale_handler = owner.permission_handler
    client.config.handlers.on_request_permission(
      vim.tbl_extend("force", tool, { toolCallId = "call2" }),
      permission_options,
      function() end
    )
    local replacement = owner.permission_handler

    stale_handler("approve-123")

    assert.equals(replacement, owner.permission_handler)
    assert.is_not_nil(owner.permission_button_options)
    assert.is_true(vim.wait(500, function() return #first > 0 end, 5))
    assert.same({ {} }, first)
  end)

  for _, cancel_before_request in ipairs({ true, false }) do
    it(
      "suppresses automatic permission approval when cancellation occurs "
        .. (cancel_before_request and "before delivery" or "before the scheduled reply"),
      function()
        Config.behaviour.auto_approve_tool_permissions = true
        local owner = sidebar()
        local client = start_request(owner)
        local replies = {}
        local function cancel() vim.api.nvim_exec_autocmds("User", { pattern = Llm.CANCEL_PATTERN }) end
        if cancel_before_request then cancel() end
        client.config.handlers.on_request_permission(
          tool,
          permission_options,
          function(id) table.insert(replies, { id = id }) end
        )
        if not cancel_before_request then cancel() end

        assert.is_true(vim.wait(500, function() return #replies > 0 end, 5))
        assert.same({ {} }, replies)
        assert.is_nil(owner.permission_handler)
      end
    )
  end
end)
