local agent = vim.env.AVANTE_ACP_TEST_AGENT
local native_dir = vim.env.AVANTE_ACP_TEST_NATIVE_DIR

-- The normal Lua suite stays fast; this file is exercised by `make acp-integration-test`.
if not agent or agent == "" or not native_dir or native_dir == "" then return end

package.cpath = native_dir .. "/?.so;" .. package.cpath
package.loaded.avante_acp = nil

local ACPClient = require("avante.libs.acp_client")

describe("ACP native integration", function()
  local clients
  local workspaces

  local function wait_for(label, predicate)
    assert.is_true(vim.wait(10000, predicate, 10), "timed out waiting for " .. label)
  end

  local function operation(label, start)
    local done = false
    local values
    start(function(...)
      values = { n = select("#", ...), ... }
      done = true
    end)
    wait_for(label, function() return done end)
    return unpack(values, 1, values.n)
  end

  local function workspace()
    local directory = vim.fn.tempname()
    local root = directory .. "/root"
    vim.fn.mkdir(root, "p")
    local value = {
      directory = directory,
      root = root,
      close_marker = directory .. "/closed",
      scenario_marker = directory .. "/scenario",
    }
    table.insert(workspaces, value)
    return value
  end

  local function new_client(scenario, handlers, opts)
    opts = opts or {}
    local ws = workspace()
    local env = {
      AVANTE_ACP_TEST_SCENARIO = scenario or "",
      AVANTE_ACP_TEST_ROOT = ws.root,
      AVANTE_ACP_TEST_CLOSE_MARKER = ws.close_marker,
      AVANTE_ACP_TEST_SCENARIO_MARKER = ws.scenario_marker,
    }
    for key, value in pairs(opts.env or {}) do
      env[key] = value
    end
    local client = ACPClient:new({
      command = agent,
      args = {},
      env = env,
      auth_method = opts.auth_method,
      handlers = handlers or {},
      session_close_timeout = 1000,
    })
    table.insert(clients, client)
    return client, ws
  end

  local function connect(client)
    return operation("ACP connection", function(done) client:connect(done) end)
  end

  local function load_session(client, root, opts)
    return operation("session/load", function(done) client:load_session("s1", root, {}, done, opts) end)
  end

  local function stop(client)
    local err = operation("ACP shutdown", function(done) client:stop(done) end)
    assert.is_nil(err)
    assert.equals("disconnected", client.state)
  end

  before_each(function()
    clients = {}
    workspaces = {}
  end)

  after_each(function()
    for _, client in ipairs(clients) do
      if client.state ~= "disconnected" or client.native then
        client:stop()
        vim.wait(3000, function() return client.state == "disconnected" and client.native == nil end, 10)
      end
    end
    for _, ws in ipairs(workspaces) do
      vim.fn.delete(ws.directory, "rf")
    end
  end)

  it("loads the native module and completes an authenticated session lifecycle", function()
    local updates = {}
    local client, ws = new_client("auth-new", {
      on_session_update = function(update) table.insert(updates, update) end,
    }, { auth_method = "test-auth" })

    assert.is_nil(connect(client))
    assert.is_true(client:is_ready())
    assert.is_true(client:supports_load_session())
    assert.is_false(client:supports_list_sessions())

    local session_id, create_err = operation(
      "session/new",
      function(done) client:create_session(ws.root, {}, done) end
    )
    assert.is_nil(create_err)
    assert.equals("s1", session_id)

    local result, prompt_err = operation(
      "session/prompt",
      function(done) client:send_prompt("s1", { { type = "text", text = "hello" } }, done) end
    )
    assert.is_nil(prompt_err)
    assert.equals("end_turn", result.stopReason)
    assert.equals("live", updates[1].content.text)

    stop(client)
    assert.equals("closed", table.concat(vim.fn.readfile(ws.close_marker), ""))
  end)

  it("round trips replay, configuration, permission, read, and write events", function()
    local replayed = {}
    local live = {}
    local permission
    local read_request
    local write_request
    local config_changes = 0
    local client, ws = new_client("", {
      on_session_update = function(update) table.insert(live, update) end,
      on_config_change = function() config_changes = config_changes + 1 end,
      on_request_permission = function(tool_call, options, done)
        permission = { tool_call = tool_call, options = options }
        done("allow")
      end,
      on_read_file = function(path, line, limit, done)
        read_request = { path = path, line = line, limit = limit }
        done("from lua")
      end,
      on_write_file = function(path, content, done)
        write_request = { path = path, content = content }
        local file = assert(io.open(path, "w"))
        file:write(content)
        file:close()
        done(nil)
      end,
    }, { env = { AVANTE_ACP_TEST_EXERCISE_CLIENT_REQUESTS = "1" } })
    vim.fn.writefile({ "one", "two", "three" }, ws.root .. "/read.txt")

    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, {
      on_replay = function(update)
        table.insert(replayed, update)
        return true
      end,
    })
    assert.is_nil(load_err)
    assert.equals("replayed", replayed[1].content.text)
    assert.is_true(replayed[1]._replayed)

    local result, prompt_err = operation(
      "client request round trip",
      function(done) client:send_prompt("s1", { { type = "text", text = "exercise" } }, done) end
    )
    assert.is_nil(prompt_err)
    assert.equals("end_turn", result.stopReason)
    assert.equals("tool-1", permission.tool_call.toolCallId)
    assert.equals("allow", permission.options[1].optionId)
    local resolved_root = vim.fn.resolve(ws.root)
    assert.same({ path = resolved_root .. "/read.txt", line = 1, limit = 2 }, read_request)
    assert.same({ path = resolved_root .. "/write.txt", content = "updated" }, write_request)
    assert.equals("updated", table.concat(vim.fn.readfile(ws.root .. "/write.txt"), ""))
    assert.equals("live", live[1].content.text)
    assert.equals(1, config_changes)
    assert.is_true(client.config_options[1].currentValue)

    local options, config_err = operation(
      "session/set_config_option",
      function(done) client:set_session_option("s1", "thinking", false, done) end
    )
    assert.is_nil(config_err)
    assert.is_false(options[1].currentValue)
    stop(client)
  end)

  it("paginates session lists and reports a repeated cursor", function()
    local client, ws = new_client("list-pages")
    assert.is_nil(connect(client))
    assert.is_true(client:supports_list_sessions())

    local sessions, list_err = operation(
      "paginated session/list",
      function(done) client:list_all_sessions(ws.root, done) end
    )
    assert.is_nil(list_err)
    assert.same({ "s1", "s2" }, vim.tbl_map(function(session) return session.sessionId end, sessions))
    stop(client)

    local repeated, repeated_ws = new_client("list-repeat")
    assert.is_nil(connect(repeated))
    local partial, repeated_err = operation(
      "repeated session/list cursor",
      function(done) repeated:list_all_sessions(repeated_ws.root, done) end
    )
    assert.same({}, partial)
    assert.equals("internal", repeated_err.kind)
    assert.matches("repeated cursor", repeated_err.data)
    stop(repeated)
  end)

  it("crosses the FFI boundary for resume, close, and delete", function()
    local client, ws = new_client("session-methods")
    assert.is_nil(connect(client))

    local _, resume_err = operation(
      "session/resume",
      function(done) client:resume_session("s1", ws.root, {}, done) end
    )
    assert.is_nil(resume_err)
    assert.equals("s1", client.active_session_id)

    local close_err = operation("session/close", function(done) client:close_session("s1", done) end)
    assert.is_nil(close_err)
    assert.is_nil(client.active_session_id)
    assert.equals("closed", table.concat(vim.fn.readfile(ws.close_marker), ""))

    local _, second_resume_err = operation(
      "second session/resume",
      function(done) client:resume_session("s1", ws.root, {}, done) end
    )
    assert.is_nil(second_resume_err)
    local delete_err = operation("session/delete", function(done) client:delete_session("s1", done) end)
    assert.is_nil(delete_err)
    assert.is_nil(client.active_session_id)
    assert.equals("deleted", table.concat(vim.fn.readfile(ws.scenario_marker), ""))
    stop(client)
  end)

  it("rejects unsupported setup and unsafe file requests before Lua", function()
    local file_handler_calls = 0
    local client, ws = new_client("invalid-files", {
      on_read_file = function() file_handler_calls = file_handler_calls + 1 end,
      on_write_file = function() file_handler_calls = file_handler_calls + 1 end,
    })
    vim.fn.writefile({ "safe" }, ws.root .. "/read.txt")
    assert.is_nil(connect(client))

    local _, unsupported_err = operation(
      "unsupported additional directory",
      function(done) client:load_session("s1", ws.root, {}, done, { additional_directories = { ws.root } }) end
    )
    assert.equals("unsupported", unsupported_err.kind)

    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)
    local result, prompt_err = operation(
      "rejected file requests",
      function(done) client:send_prompt("s1", { { type = "text", text = "files" } }, done) end
    )
    assert.is_nil(prompt_err)
    assert.equals("end_turn", result.stopReason)
    assert.equals(0, file_handler_calls)
    assert.equals("invalid-files", table.concat(vim.fn.readfile(ws.scenario_marker), ""))
    stop(client)
  end)

  it("cancels a pending permission request and prompt", function()
    local permission_seen = false
    local client, ws = new_client("cancel-pending", {
      on_request_permission = function(_, _, done)
        permission_seen = true
        done(nil)
      end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_done = false
    local result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(value, err)
      result = value
      prompt_err = err
      prompt_done = true
    end)
    wait_for("permission request", function() return permission_seen end)
    client:cancel_session("s1")
    wait_for("cancelled prompt", function() return prompt_done end)
    assert.is_nil(prompt_err)
    assert.equals("cancelled", result.stopReason)
    stop(client)
  end)

  it("surfaces authentication and agent process failures", function()
    local auth_client = new_client("auth-error", {}, { auth_method = "test-auth" })
    local auth_err = connect(auth_client)
    assert.equals("authentication", auth_err.kind)
    assert.matches("Authentication required", auth_err.message)

    local fatal_error
    local failed, ws = new_client("exit-on-prompt", {
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(failed))
    local _, load_err = load_session(failed, ws.root)
    assert.is_nil(load_err)
    local _, prompt_err = operation(
      "fatal prompt failure",
      function(done) failed:send_prompt("s1", { { type = "text", text = "exit" } }, done) end
    )
    assert.equals("internal", prompt_err.kind)
    wait_for("fatal error handler", function() return fatal_error ~= nil end)
    assert.matches("connection closed", fatal_error.message .. " " .. tostring(fatal_error.data))
  end)
end)
