local ACPClient = require("avante.libs.acp_client")

describe("ACPClient sessions", function()
  local function new_client()
    local client = ACPClient:new({ command = "agent", args = {}, handlers = {} })
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
    client.native = native
    client.state = "ready"
    return client, native
  end

  it("creates sessions through the SDK-aligned native method", function()
    local client, native = new_client()
    local session_id

    client:create_session("/project", nil, function(value) session_id = value end, { "/shared" })
    client:_handle_event({
      type = "operation_completed",
      operationId = 1,
      result = { sessionId = "s1" },
    })

    assert.equals("s1", session_id)
    assert.equals("new_session", native.calls[1].method)
    assert.same({ cwd = "/project", mcpServers = {}, additionalDirectories = { "/shared" } }, native.calls[1].args[1])
  end)

  it("routes replay only for the session being loaded", function()
    local replayed, live = {}, {}
    local client = new_client()
    client.config.handlers.on_session_update = function(update) table.insert(live, update) end

    client:load_session("s1", "/project", nil, function() end, {
      on_replay = function(update)
        table.insert(replayed, update)
        return true
      end,
    })
    client:_handle_event({
      type = "session_update",
      replayed = true,
      notification = {
        sessionId = "s1",
        update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "old" } },
      },
    })
    client:_handle_event({
      type = "session_update",
      replayed = false,
      notification = {
        sessionId = "s2",
        update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "live" } },
      },
    })
    client:_handle_event({ type = "operation_completed", operationId = 1, result = {} })

    assert.is_true(replayed[1]._replayed)
    assert.equals("live", live[1].content.text)
    assert.is_nil(client.session_replay_handlers.s1)
  end)

  it("retains commands replayed while loading a different session", function()
    local client = new_client()
    client:create_session("/tmp", {}, function() end)
    client:_handle_event({ type = "operation_completed", operationId = 1, result = { sessionId = "old-session" } })
    client:load_session("loading-session", "/tmp", {}, function() end, {
      on_replay = require("avante.history.acp_replay").is_conversation_update,
    })
    local commands = { { name = "review", description = "Review this restored session" } }
    client:_handle_event({
      type = "session_update",
      replayed = true,
      notification = {
        sessionId = "loading-session",
        update = { sessionUpdate = "available_commands_update", availableCommands = commands },
      },
    })
    client:_handle_event({ type = "operation_completed", operationId = 2, result = {} })

    assert.equals("loading-session", client.active_session_id)
    assert.same(commands, client.session_commands["loading-session"])
  end)

  it("cancels a permission request for an inactive session without showing it to the current request", function()
    local client, native = new_client()
    for index, session_id in ipairs({ "old-session", "current-session" }) do
      client:create_session("/tmp", {}, function() end)
      client:_handle_event({ type = "operation_completed", operationId = index, result = { sessionId = session_id } })
    end
    local delivered, replies = false, {}
    client.config.handlers.on_request_permission = function(_, _, respond)
      delivered = true
      respond("allow")
    end
    native.respond_permission = function(_, request_id, option_id)
      table.insert(replies, { request_id = request_id, option_id = option_id })
    end
    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = {
        sessionId = "old-session",
        toolCall = { toolCallId = "old-edit", kind = "edit", title = "Edit old project", status = "pending" },
        options = { { optionId = "allow", kind = "allow_once", name = "Allow" } },
      },
    })

    assert.is_false(delivered)
    assert.same({ { request_id = 10 } }, replies)
  end)

  it("keeps permission requests for the explicitly loading session reachable", function()
    local client, native = new_client()
    client.active_session_id = "old-session"
    client:load_session("loading-session", "/tmp", {}, function() end, { on_replay = function() return true end })
    local delivered, replies = false, {}
    client.config.handlers.on_request_permission = function(_, _, respond)
      delivered = true
      respond("allow")
    end
    native.respond_permission = function(_, request_id, option_id)
      table.insert(replies, { request_id = request_id, option_id = option_id })
    end
    client:_handle_event({
      type = "permission_request",
      requestId = 10,
      request = {
        sessionId = "loading-session",
        toolCall = { toolCallId = "load-edit", kind = "edit", title = "Restore project", status = "pending" },
        options = { { optionId = "allow", kind = "allow_once", name = "Allow" } },
      },
    })

    assert.is_true(delivered)
    assert.same({ { request_id = 10, option_id = "allow" } }, replies)
  end)

  it("uses Rust capability summaries instead of the initialize protocol object", function()
    local client = new_client()

    client:_handle_event({ type = "initialized", supportsLoadSession = true, supportsListSessions = false })

    assert.is_true(client:supports_load_session())
    assert.is_false(client:supports_list_sessions())
    assert.is_nil(client.agent_capabilities)
  end)

  it("receives the fully paginated session list from Rust", function()
    local client, native = new_client()
    local sessions

    client:list_all_sessions("/project", function(value) sessions = value end)
    client:_handle_event({
      type = "operation_completed",
      operationId = 1,
      result = {
        { sessionId = "s1", cwd = "/project" },
        { sessionId = "s2", cwd = "/project" },
      },
    })

    assert.equals("list_sessions", native.calls[1].method)
    assert.same({ "/project" }, native.calls[1].args)
    assert.equals(2, #sessions)
  end)

  it("deletes sessions through a concrete native method", function()
    local client, native = new_client()
    local callback_error = "not called"

    client:delete_session("s1", function(err) callback_error = err end)
    client:_handle_event({ type = "operation_completed", operationId = 1, result = {} })

    assert.is_nil(callback_error)
    assert.same({ "s1" }, native.calls[1].args)
    assert.equals("delete_session", native.calls[1].method)
  end)

  it("uses one Rust-owned session option operation", function()
    local client, native = new_client()
    client:set_session_option("s1", "model", "opus", function() end)

    assert.equals("set_session_option", native.calls[1].method)
    assert.same({ "s1", "model", "opus" }, native.calls[1].args)
    assert.is_nil(client.set_config_option)
    assert.is_nil(client.set_mode)
    assert.is_nil(client.set_model)
  end)

  it("applies Rust-normalized configuration changes without parsing protocol updates", function()
    local changed = 0
    local client = new_client()
    client.config.handlers.on_config_change = function() changed = changed + 1 end
    local session_updates = 0
    client.config.handlers.on_session_update = function() session_updates = session_updates + 1 end
    client.active_session_id = "s1"
    client.config_options = {
      { id = "mode", category = "mode", currentValue = "code", options = {} },
    }

    client:_handle_event({
      type = "session_update",
      replayed = false,
      configValue = { id = "mode", currentValue = "plan" },
      notification = { sessionId = "s1", update = { sessionUpdate = "agent_message_chunk" } },
    })

    assert.equals("plan", client.config_options[1].currentValue)
    assert.equals(1, changed)
    assert.equals(0, session_updates)
  end)

  it("ignores configuration updates from an inactive session", function()
    local client = new_client()
    client.active_session_id = "s2"
    client.config_options = {
      { id = "mode", category = "mode", currentValue = "code", options = {} },
    }

    client:_handle_event({
      type = "session_update",
      replayed = false,
      configValue = { id = "mode", currentValue = "plan" },
      notification = { sessionId = "s1", update = { sessionUpdate = "current_mode_update" } },
    })

    assert.equals("code", client.config_options[1].currentValue)
  end)
end)
