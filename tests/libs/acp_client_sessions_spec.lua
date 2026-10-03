local ACPClient = require("avante.libs.acp_client")
local stub = require("luassert.stub")

describe("ACPClient sessions", function()
  local schedule_stub
  local setup_transport_stub
  ---@type function[]
  local scheduled
  ---@type table[]
  local handled
  ---@type function[]
  local deferred
  local defer_stub

  before_each(function()
    scheduled = {}
    handled = {}
    deferred = {}
    -- Defer scheduled work like the real event loop, so tests see the order in which things happen
    schedule_stub = stub(vim, "schedule")
    schedule_stub.invokes(function(fn) table.insert(scheduled, fn) end)
    defer_stub = stub(vim, "defer_fn")
    defer_stub.invokes(function(fn, _) table.insert(deferred, fn) end)
    setup_transport_stub = stub(ACPClient, "_setup_transport")
  end)

  after_each(function()
    schedule_stub:revert()
    defer_stub:revert()
    setup_transport_stub:revert()
  end)

  local function flush()
    while #scheduled > 0 do
      table.remove(scheduled, 1)()
    end
  end

  local function flush_deferred()
    while #deferred > 0 do
      table.remove(deferred, 1)()
    end
  end

  ---@param capabilities table|nil
  ---@param respond? fun(request: table, client: avante.acp.ACPClient)
  ---@return avante.acp.ACPClient client, table[] requests
  local function new_client(capabilities, respond)
    local requests = {}
    local client
    client = ACPClient:new({
      transport_type = "stdio",
      handlers = { on_session_update = function(update) table.insert(handled, update) end },
    })
    client.transport = {
      send = function(_self, data)
        local request = vim.json.decode(data)
        table.insert(requests, request)
        if respond then respond(request, client) end
        return true
      end,
      start = function(_self, _on_message) end,
      stop = function(_self) client.transport_stop_count = (client.transport_stop_count or 0) + 1 end,
    }
    client.state = "ready"
    client.agent_capabilities = capabilities
    return client, requests
  end

  ---@param client avante.acp.ACPClient
  ---@param id integer
  ---@param result table
  local function reply(client, id, result) client:_handle_message({ jsonrpc = "2.0", id = id, result = result }) end

  ---@param client avante.acp.ACPClient
  ---@param session_id string
  ---@param update table
  local function notify(client, session_id, update)
    client:_handle_message({
      jsonrpc = "2.0",
      method = "session/update",
      params = { sessionId = session_id, update = update },
    })
  end

  local LIST_CAPABILITIES = { loadSession = true, sessionCapabilities = { list = vim.empty_dict() } }

  describe("session setup", function()
    it("sends validated setup parameters and tracks a newly created session", function()
      local capabilities = {
        mcpCapabilities = { http = true, sse = true },
        sessionCapabilities = { additionalDirectories = vim.empty_dict() },
      }
      local client, requests = new_client(
        capabilities,
        function(request, c) reply(c, request.id, { sessionId = "created" }) end
      )
      local servers = {
        {
          name = "local",
          command = "/usr/bin/local-mcp",
          args = { "--stdio" },
          env = { { name = "TOKEN", value = "secret" } },
        },
        {
          type = "http",
          name = "remote",
          url = "https://example.test/mcp",
          headers = { { name = "Authorization", value = "Bearer token" } },
        },
      }
      local session_id, err

      client:create_session("/project", servers, function(id, e)
        session_id, err = id, e
      end, { "/shared" })

      assert.is_nil(err)
      assert.equals("created", session_id)
      assert.equals("session/new", requests[1].method)
      assert.same(
        { cwd = "/project", mcpServers = servers, additionalDirectories = { "/shared" } },
        requests[1].params
      )
      assert.is_true(client.active_session_ids.created)
    end)

    it("uses configured additional directories when no per-call value is given", function()
      local client, requests = new_client(
        { sessionCapabilities = { additionalDirectories = vim.empty_dict() } },
        function(request, c) reply(c, request.id, { sessionId = "configured" }) end
      )
      client.config.additional_directories = { "/shared" }

      client:create_session("/project", {}, function() end)

      assert.same({ "/shared" }, requests[1].params.additionalDirectories)
    end)

    it("rejects invalid setup parameters without sending a request", function()
      local cases = {
        {
          run = function(client, callback) client:create_session("relative", {}, callback) end,
          code = ACPClient.ERROR_CODES.INVALID_PARAMS,
        },
        {
          run = function(client, callback)
            client:create_session(
              "/project",
              { { name = "mcp", command = "relative", args = {}, env = {} } },
              callback
            )
          end,
          code = ACPClient.ERROR_CODES.INVALID_PARAMS,
        },
        {
          run = function(client, callback) client:create_session("/project", {}, callback, { "relative" }) end,
          code = ACPClient.ERROR_CODES.INVALID_PARAMS,
        },
        {
          run = function(client, callback) client:create_session("/project", {}, callback, { "/shared" }) end,
          code = ACPClient.ERROR_CODES.INVALID_REQUEST,
        },
        {
          run = function(client, callback)
            client:create_session(
              "/project",
              { { type = "http", name = "remote", url = "https://example.test", headers = {} } },
              callback
            )
          end,
          code = ACPClient.ERROR_CODES.INVALID_REQUEST,
        },
      }

      for _, case in ipairs(cases) do
        local client, requests = new_client({ sessionCapabilities = {} })
        local err
        case.run(client, function(_, e) err = e end)
        assert.equals(case.code, err.code)
        assert.equals(0, #requests)
      end
    end)

    it("rejects setup before initialization", function()
      local client, requests = new_client({})
      client.state = "connected"
      local err

      client:create_session("/project", {}, function(_, e) err = e end)

      assert.equals(ACPClient.ERROR_CODES.INVALID_REQUEST, err.code)
      assert.equals(0, #requests)
    end)

    it("rejects an invalid session/new response", function()
      local client = new_client({}, function(request, c) reply(c, request.id, vim.empty_dict()) end)
      local session_id, err

      client:create_session("/project", {}, function(id, e)
        session_id, err = id, e
      end)

      assert.is_nil(session_id)
      assert.equals(ACPClient.ERROR_CODES.PROTOCOL_ERROR, err.code)
      assert.same({}, client.active_session_ids)
    end)

    it("requires loadSession to be explicitly true", function()
      for _, capabilities in ipairs({ {}, { loadSession = false }, { loadSession = vim.NIL } }) do
        local client, requests = new_client(capabilities)
        local err

        client:load_session("existing", "/project", {}, function(_, e) err = e end)

        assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, err.code)
        assert.equals(0, #requests)
      end
    end)

    it("resumes without replay mode when the capability is advertised", function()
      local capabilities = { sessionCapabilities = { resume = vim.empty_dict() } }
      local replay_state
      local client, requests = new_client(capabilities, function(request, c)
        replay_state = c.is_loading_session
        reply(c, request.id, vim.empty_dict())
      end)
      local result, err

      client:resume_session("existing", "/project", {}, function(res, e)
        result, err = res, e
      end)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_false(replay_state)
      assert.equals("session/resume", requests[1].method)
      assert.same({ sessionId = "existing", cwd = "/project", mcpServers = {} }, requests[1].params)
      assert.is_true(client.active_session_ids.existing)
    end)

    it("does not send session/resume when the capability is absent", function()
      local client, requests = new_client({ sessionCapabilities = {} })
      local err

      client:resume_session("existing", "/project", {}, function(_, e) err = e end)

      assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, err.code)
      assert.equals(0, #requests)
    end)

    it("rejects a non-object session/resume response", function()
      local capabilities = { sessionCapabilities = { resume = vim.empty_dict() } }
      local client = new_client(capabilities, function(request, c) reply(c, request.id, {}) end)
      local result, err

      client:resume_session("existing", "/project", {}, function(res, e)
        result, err = res, e
      end)

      assert.is_nil(result)
      assert.equals(ACPClient.ERROR_CODES.PROTOCOL_ERROR, err.code)
      assert.is_nil(client.active_session_ids.existing)
    end)

    it("closes and untracks an active session", function()
      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local client, requests = new_client(
        capabilities,
        function(request, c) reply(c, request.id, vim.empty_dict()) end
      )
      client.active_session_ids.existing = true
      local close_err = false

      client:close_session("existing", function(err) close_err = err end)

      assert.is_nil(close_err)
      assert.same({ sessionId = "existing" }, requests[1].params)
      assert.is_nil(client.active_session_ids.existing)
    end)

    it("validates session/close support, parameters, and response", function()
      local unsupported, unsupported_requests = new_client({ sessionCapabilities = {} })
      local unsupported_err
      unsupported:close_session("existing", function(err) unsupported_err = err end)
      assert.equals(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, unsupported_err.code)
      assert.equals(0, #unsupported_requests)

      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local invalid_id, invalid_id_requests = new_client(capabilities)
      local invalid_id_err
      invalid_id:close_session("", function(err) invalid_id_err = err end)
      assert.equals(ACPClient.ERROR_CODES.INVALID_PARAMS, invalid_id_err.code)
      assert.equals(0, #invalid_id_requests)

      local invalid_response = new_client(capabilities, function(request, c) reply(c, request.id, {}) end)
      invalid_response.active_session_ids.existing = true
      local response_err
      invalid_response:close_session("existing", function(err) response_err = err end)
      assert.equals(ACPClient.ERROR_CODES.PROTOCOL_ERROR, response_err.code)
      assert.is_true(invalid_response.active_session_ids.existing)
    end)
  end)

  describe("client shutdown", function()
    it("closes every active session before stopping the transport", function()
      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local client, requests = new_client(capabilities, function(request, c)
        if request.method == "session/close" then reply(c, request.id, vim.empty_dict()) end
      end)
      client.active_session_ids = { first = true, second = true }
      local stop_err = false

      client:stop(function(err) stop_err = err end)

      local closed = vim.tbl_map(function(request) return request.params.sessionId end, requests)
      table.sort(closed)
      assert.same({ "first", "second" }, closed)
      assert.is_nil(stop_err)
      assert.equals(1, client.transport_stop_count)
      assert.is_false(client.is_stopping)
      assert.same({}, client.active_session_ids)
    end)

    it("stops immediately when session/close is unsupported", function()
      local client, requests = new_client({ sessionCapabilities = {} })
      client.active_session_ids.existing = true
      local completed = false

      client:stop(function(err)
        assert.is_nil(err)
        completed = true
      end)

      assert.is_true(completed)
      assert.equals(0, #requests)
      assert.equals(1, client.transport_stop_count)
    end)

    it("forces transport shutdown after the close timeout", function()
      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local client, requests = new_client(capabilities)
      client.active_session_ids.existing = true
      local stop_err
      local second_callback = false

      client:stop(function(err) stop_err = err end)
      client:stop(function() second_callback = true end)
      assert.equals(1, #requests)
      assert.is_true(client.is_stopping)
      assert.is_false(client:is_ready())

      flush_deferred()

      assert.truthy(stop_err.message:find("Timed out", 1, true))
      assert.is_true(second_callback)
      assert.equals(1, client.transport_stop_count)
      assert.is_false(client.is_stopping)
    end)

    it("rejects non-close requests while graceful shutdown is pending", function()
      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local client, requests = new_client(capabilities)
      client.active_session_ids.existing = true
      client:stop()
      local prompt_err

      client:send_prompt("existing", { { type = "text", text = "hello" } }, function(_, err) prompt_err = err end)

      assert.equals(ACPClient.ERROR_CODES.INVALID_REQUEST, prompt_err.code)
      assert.equals(1, #requests)
    end)

    it("force-stops without sending session/close", function()
      local capabilities = { sessionCapabilities = { close = vim.empty_dict() } }
      local client, requests = new_client(capabilities)
      client.active_session_ids.existing = true

      client:force_stop()

      assert.equals(0, #requests)
      assert.equals(1, client.transport_stop_count)
      assert.is_true(client.stop_requested)
      assert.same({}, client.active_session_ids)
    end)
  end)

  describe("supports_list_sessions", function()
    it(
      "is true when the agent advertises session listing",
      function() assert.is_true(new_client(LIST_CAPABILITIES):supports_list_sessions()) end
    )

    it("is false when listing is missing or null", function()
      assert.is_false(new_client(nil):supports_list_sessions())
      assert.is_false(new_client({ loadSession = true }):supports_list_sessions())
      assert.is_false(new_client({ sessionCapabilities = vim.NIL }):supports_list_sessions())
      assert.is_false(new_client({ sessionCapabilities = { list = vim.NIL } }):supports_list_sessions())
      assert.is_false(new_client({ sessionCapabilities = { list = {} } }):supports_list_sessions())
    end)
  end)

  describe("list_sessions", function()
    it("sends session/list with the cwd, and the cursor only when given", function()
      local client, requests = new_client(
        LIST_CAPABILITIES,
        function(request, c) reply(c, request.id, { sessions = {} }) end
      )

      client:list_sessions("/project", nil, function() end)
      client:list_sessions("/project", "page-2", function() end)

      assert.equals("session/list", requests[1].method)
      assert.same({ cwd = "/project" }, requests[1].params)
      assert.same({ cwd = "/project", cursor = "page-2" }, requests[2].params)
    end)

    it("normalizes JSON nulls and drops sessions without an id", function()
      local client = new_client(
        LIST_CAPABILITIES,
        function(request, c)
          reply(c, request.id, {
            sessions = {
              { sessionId = "a", cwd = "/project", title = vim.NIL, updatedAt = "2026-09-24T23:37:10Z" },
              { sessionId = "b", cwd = vim.NIL },
              { cwd = "/project", title = "no id" },
              { sessionId = "c", cwd = 42, title = { "not a string" }, updatedAt = 7 },
            },
            nextCursor = vim.NIL,
          })
        end
      )

      local result
      client:list_sessions("/project", nil, function(res) result = res end)

      assert.same({
        sessions = {
          { sessionId = "a", cwd = "/project", updatedAt = "2026-09-24T23:37:10Z" },
          { sessionId = "b", cwd = "/project" },
          { sessionId = "c", cwd = "/project" },
        },
      }, result)
    end)

    it("returns an error without sending when listing is unsupported", function()
      local client, requests = new_client({ loadSession = true })

      local result, err
      client:list_sessions("/project", nil, function(res, e)
        result, err = res, e
      end)

      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.equals(0, #requests)
    end)
  end)

  describe("list_all_sessions", function()
    it("follows nextCursor and concatenates pages", function()
      local client, requests = new_client(LIST_CAPABILITIES, function(request, c)
        if not request.params.cursor then
          reply(c, request.id, { sessions = { { sessionId = "a", cwd = "/p" } }, nextCursor = "page-2" })
        else
          reply(c, request.id, { sessions = { { sessionId = "b", cwd = "/p" } } })
        end
      end)

      local sessions, err
      client:list_all_sessions("/p", function(s, e)
        sessions, err = s, e
      end)

      assert.is_nil(err)
      assert.same({ "a", "b" }, vim.tbl_map(function(s) return s.sessionId end, sessions))
      assert.equals(2, #requests)
      assert.equals("page-2", requests[2].params.cursor)
    end)

    it("stops when the agent repeats a cursor", function()
      local client, requests = new_client(
        LIST_CAPABILITIES,
        function(request, c) reply(c, request.id, { sessions = {}, nextCursor = "same" }) end
      )

      local done, err = false, nil
      client:list_all_sessions("/p", function(_, e)
        done, err = true, e
      end)

      assert.is_true(done)
      assert.equals(2, #requests)
      assert.truthy(err.message:find("incomplete", 1, true))
    end)

    it("stops after a page limit when cursors never end", function()
      local page = 0
      local client, requests = new_client(LIST_CAPABILITIES, function(request, c)
        page = page + 1
        reply(c, request.id, { sessions = {}, nextCursor = "page-" .. page })
      end)

      local done, err = false, nil
      client:list_all_sessions("/p", function(_, e)
        done, err = true, e
      end)

      assert.is_true(done)
      assert.equals(50, #requests)
      assert.truthy(err.message:find("50 pages", 1, true))
    end)

    it("returns the sessions collected so far with a later page's error", function()
      local client = new_client(LIST_CAPABILITIES, function(request, c)
        if not request.params.cursor then
          reply(c, request.id, { sessions = { { sessionId = "a", cwd = "/p" } }, nextCursor = "page-2" })
        else
          c:_handle_message({ jsonrpc = "2.0", id = request.id, error = { code = -32603, message = "boom" } })
        end
      end)

      local sessions, err
      client:list_all_sessions("/p", function(s, e)
        sessions, err = s, e
      end)

      assert.equals(1, #sessions)
      assert.equals("boom", err.message)
    end)
  end)

  describe("load_session replay", function()
    local user_chunk = { sessionUpdate = "user_message_chunk", content = { type = "text", text = "hi" } }
    local agent_chunk = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hello" } }
    local plan = { sessionUpdate = "plan", entries = {} }

    ---Agent that replays the given updates, then answers session/load
    ---@param updates { session_id: string, update: table }[]
    ---@param error_response? table
    local function replaying_agent(updates, error_response)
      return function(request, client)
        if request.method ~= "session/load" then return end
        for _, item in ipairs(updates) do
          notify(client, item.session_id, item.update)
        end
        if error_response then
          client:_handle_message({ jsonrpc = "2.0", id = request.id, error = error_response })
        else
          reply(client, request.id, vim.empty_dict())
        end
      end
    end

    it("hands replayed updates to on_replay before the load callback runs", function()
      local collected = {}
      local collected_at_callback
      local client = new_client(
        LIST_CAPABILITIES,
        replaying_agent({ { session_id = "s1", update = user_chunk }, { session_id = "s1", update = agent_chunk } })
      )

      client:load_session("s1", "/p", {}, function() collected_at_callback = #collected end, {
        on_replay = function(update)
          table.insert(collected, update)
          return true
        end,
      })
      flush()

      assert.equals(2, collected_at_callback)
      assert.equals(0, #handled)
      assert.is_true(client.active_session_ids.s1)
    end)

    it("passes updates it does not consume, and other sessions' updates, to the handler", function()
      local client = new_client(
        LIST_CAPABILITIES,
        replaying_agent({
          { session_id = "s1", update = plan },
          { session_id = "other", update = agent_chunk },
          { session_id = "s1", update = user_chunk },
        })
      )

      local collected = {}
      client:load_session("s1", "/p", {}, function() end, {
        on_replay = function(update)
          if update.sessionUpdate == "plan" then return false end
          table.insert(collected, update)
          return true
        end,
      })
      flush()

      assert.same({ "user_message_chunk" }, vim.tbl_map(function(u) return u.sessionUpdate end, collected))
      assert.same({ "plan", "agent_message_chunk" }, vim.tbl_map(function(u) return u.sessionUpdate end, handled))
    end)

    it("stops collecting once the load succeeds", function()
      local client = new_client(LIST_CAPABILITIES, replaying_agent({}))
      local collected = 0
      client:load_session("s1", "/p", {}, function() end, {
        on_replay = function()
          collected = collected + 1
          return true
        end,
      })

      notify(client, "s1", agent_chunk)
      flush()

      assert.equals(0, collected)
      assert.equals(1, #handled)
      assert.is_nil(client.session_replay_handlers["s1"])
    end)

    it("stops collecting when the load fails", function()
      local client = new_client(LIST_CAPABILITIES, replaying_agent({}, { code = -32603, message = "not found" }))
      local load_err
      client:load_session("s1", "/p", {}, function(_, err) load_err = err end, {
        on_replay = function() return true end,
      })
      flush()

      assert.equals("not found", load_err.message)
      assert.is_nil(client.session_replay_handlers["s1"])
    end)

    it("sends replayed updates to the handler when no on_replay is given", function()
      local client = new_client(LIST_CAPABILITIES, replaying_agent({ { session_id = "s1", update = agent_chunk } }))

      client:load_session("s1", "/p", {}, function() end)
      flush()

      assert.equals(1, #handled)
    end)
  end)
end)
