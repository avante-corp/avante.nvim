local agent = vim.env.AVANTE_ACP_TEST_AGENT
local native_dir = vim.env.AVANTE_ACP_TEST_NATIVE_DIR

-- The normal Lua suite stays fast; this file is exercised by `make acp-integration-test`.
if not agent or agent == "" or not native_dir or native_dir == "" then return end

local open_native = assert(package.loadlib(native_dir .. "/avante_acp.so", "luaopen_avante_acp"))
package.preload.avante_acp = open_native
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
      started_marker = directory .. "/started",
      output_gate = directory .. "/release-output",
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
      AVANTE_ACP_TEST_STARTED_MARKER = ws.started_marker,
      AVANTE_ACP_TEST_OUTPUT_GATE = ws.output_gate,
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
    assert.equals("disconnected", client.connection_state)
  end

  before_each(function()
    clients = {}
    workspaces = {}
  end)

  after_each(function()
    for _, client in ipairs(clients) do
      if client.connection_state ~= "disconnected" or client.native then
        client:stop()
        vim.wait(3000, function() return client.connection_state == "disconnected" and client.native == nil end, 10)
      end
    end
    for _, ws in ipairs(workspaces) do
      if ws.process_pid and (vim.uv or vim.loop).kill(ws.process_pid, 0) then
        (vim.uv or vim.loop).kill(ws.process_pid, 9)
        vim.wait(1000, function() return not (vim.uv or vim.loop).kill(ws.process_pid, 0) end, 10)
      end
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

  it("sends a prompt before an immediate cancellation on the wire", function()
    local client, ws = new_client("prompt-cancel-order")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local result, prompt_err = operation("immediate cancellation", function(done)
      client:send_prompt("s1", { { type = "text", text = "go" } }, done)
      client:cancel_session("s1")
    end)
    assert.is_nil(prompt_err)
    assert.equals("cancelled", result.stopReason)
    assert.same({ "session/prompt", "session/cancel" }, vim.fn.readfile(ws.scenario_marker))
    stop(client)
  end)

  it("cancels crossed permission requests without invoking the permission handler", function()
    local permission_calls = 0
    local client, ws = new_client("crossed-permission", {
      on_request_permission = function(_, _, done)
        permission_calls = permission_calls + 1
        done("allow")
      end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local result, prompt_err = operation("crossed cancellation and permission", function(done)
      client:send_prompt("s1", { { type = "text", text = "wait" } }, done)
      wait_for("permission gate", function() return vim.fn.filereadable(ws.started_marker) == 1 end)
      client:cancel_session("s1")
      -- The agent emits permission before reading the cancellation already sent by the client.
      vim.wait(100, function() return false end, 10)
      vim.fn.writefile({ "release" }, ws.output_gate)
    end)

    assert.is_nil(prompt_err)
    assert.equals("cancelled", result.stopReason)
    assert.equals(0, permission_calls)
    local response = vim.json.decode(table.concat(vim.fn.readfile(ws.scenario_marker), "\n"))
    assert.same({ outcome = "cancelled" }, response.result.outcome)
    stop(client)
  end)

  it("rejects reading a session root directory before invoking the file handler", function()
    local read_calls = 0
    local client, ws = new_client("read-directory", {
      on_read_file = function(_, _, _, done)
        read_calls = read_calls + 1
        done("directory contents must not become a file response")
      end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local result, prompt_err = operation(
      "directory read rejection",
      function(done) client:send_prompt("s1", { { type = "text", text = "read root" } }, done) end
    )
    assert.is_nil(prompt_err)
    assert.equals("end_turn", result.stopReason)
    assert.equals(0, read_calls)
    local response = vim.json.decode(table.concat(vim.fn.readfile(ws.scenario_marker), "\n"))
    assert.equals(-32602, response.error.code)
    stop(client)
  end)

  it("rejects a FIFO file request before invoking a blocking file handler", function()
    if vim.fn.has("unix") ~= 1 then return end
    local read_calls = 0
    local client, ws = new_client("read-special", {
      on_read_file = function(_, _, _, done)
        read_calls = read_calls + 1
        done("unexpected file read")
      end,
    })
    vim.fn.system({ "mkfifo", ws.root .. "/input.fifo" })
    assert.equals(0, vim.v.shell_error)
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)
    local _, prompt_err = operation(
      "prompt requesting FIFO",
      function(done) client:send_prompt("s1", { { type = "text", text = "read input" } }, done) end
    )
    assert.is_nil(prompt_err)
    assert.equals(0, read_calls)
    local response = vim.json.decode(table.concat(vim.fn.readfile(ws.scenario_marker), "\n"))
    assert.equals(-32602, response.error.code)
    stop(client)
  end)

  it("preserves configuration response ordering before a subsequent update", function()
    local changes = {}
    local client, ws = new_client("config-update-order", {
      on_config_change = function() table.insert(changes, "update") end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local _, err = operation("set option before newer config update", function(done)
      client:set_session_option("s1", "thinking", false, function(options, failure)
        table.insert(changes, "response")
        done(options, failure)
      end)
    end)
    assert.is_nil(err)
    wait_for("newer configuration update", function() return #changes == 2 end)
    assert.same({ "response", "update" }, changes)
    assert.is_true(client.config_options[1].currentValue)
    stop(client)
  end)

  it("preserves the original replay handler when a concurrent load is rejected", function()
    local replay, live = {}, {}
    local client, ws = new_client("gated-load", {
      on_session_update = function(update) table.insert(live, update.content.text) end,
    })
    assert.is_nil(connect(client))
    local loaded = false
    local load_err
    client:load_session("s1", ws.root, {}, function(_, err)
      loaded = true
      load_err = err
    end, {
      on_replay = function(update)
        table.insert(replay, update.content.text)
        return true
      end,
    })
    wait_for("first replay update", function() return #replay == 1 end)
    local _, duplicate_err = load_session(client, ws.root, {
      on_replay = function() error("rejected load must not own replay") end,
    })
    assert.equals("invalid_request", duplicate_err.kind)
    vim.fn.writefile({ "release" }, ws.output_gate)
    wait_for("original load completion", function() return loaded end)
    assert.is_nil(load_err)
    assert.same({ "1", "2" }, replay)
    assert.same({}, live)
    stop(client)
  end)

  it("settles a pending prompt once when stopping during an unanswered permission", function()
    local permission_seen = false
    local client, ws = new_client("cancel-pending", {
      on_request_permission = function() permission_seen = true end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_calls = 0
    local prompt_result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(result, err)
      prompt_calls = prompt_calls + 1
      prompt_result = result
      prompt_err = err
    end)
    wait_for("unanswered permission request", function() return permission_seen end)
    stop(client)

    assert.equals(1, prompt_calls)
    assert.is_nil(prompt_result)
    assert.equals("cancelled", prompt_err.kind)
    assert.is_nil(client.native)
    assert.equals("closed", table.concat(vim.fn.readfile(ws.close_marker), ""))
  end)

  it("settles a pending prompt on close acknowledgment and ignores its later response", function()
    local permission_seen = false
    local client, ws = new_client("close-pending", {
      on_request_permission = function() permission_seen = true end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_calls = 0
    local prompt_result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(result, err)
      prompt_calls = prompt_calls + 1
      prompt_result = result
      prompt_err = err
    end)
    wait_for("permission before session close", function() return permission_seen end)

    local close_err = operation("session close during prompt", function(done) client:close_session("s1", done) end)
    assert.is_nil(close_err)
    wait_for("prompt completion after session close", function() return prompt_calls > 0 end)
    assert.equals(1, prompt_calls)
    assert.equals("cancelled", prompt_err.kind)
    assert.is_nil(prompt_result)
    assert.is_nil(client.active_session_id)
    stop(client)
    assert.equals(1, prompt_calls)
  end)

  it("preserves a prompt response preceding close acknowledgment exactly once", function()
    local permission_seen = false
    local client, ws = new_client("close-after-prompt", {
      on_request_permission = function() permission_seen = true end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local completions = {}
    local prompt_result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(result, err)
      table.insert(completions, "prompt")
      prompt_result = result
      prompt_err = err
    end)
    wait_for("permission before prompt-first close", function() return permission_seen end)
    local close_err = operation("close after prompt response", function(done)
      client:close_session("s1", function(err)
        table.insert(completions, "close")
        done(err)
      end)
    end)
    assert.is_nil(close_err)
    assert.is_nil(prompt_err)
    assert.equals("end_turn", prompt_result.stopReason)
    assert.same({ "prompt", "close" }, completions)
    assert.is_nil(client.active_session_id)
    assert.is_true(client:is_ready())
    stop(client)
    assert.same({ "prompt", "close" }, completions)
  end)

  it("settles a prompt once and retires an unanswered request after close", function()
    local permission_seen = false
    local fatal_error
    local client, ws = new_client("close-without-prompt", {
      on_request_permission = function() permission_seen = true end,
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_calls = 0
    local prompt_result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(result, err)
      prompt_calls = prompt_calls + 1
      prompt_result = result
      prompt_err = err
    end)
    wait_for("permission before close without prompt response", function() return permission_seen end)
    local close_err = operation("close without prompt response", function(done) client:close_session("s1", done) end)
    assert.is_nil(close_err)
    assert.is_true(vim.wait(1000, function() return prompt_calls > 0 end, 10), "close must settle the pending prompt")
    assert.equals(1, prompt_calls)
    assert.is_nil(prompt_result)
    assert.equals("cancelled", prompt_err.kind)
    assert.is_nil(client.active_session_id)
    assert.is_true(
      vim.wait(3500, function() return client.native == nil and client.connection_state == "disconnected" end, 10),
      "an unanswered prompt reply must release its SDK connection within the close grace period"
    )
    assert.is_not_nil(fatal_error)
    assert.equals("timeout", fatal_error.kind)
    assert.matches("prompt", fatal_error.message)
    assert.is_true(fatal_error.message:find("reply") ~= nil or fatal_error.message:find("response") ~= nil)
    assert.equals(1, prompt_calls)
    stop(client)
    assert.equals(1, prompt_calls)
  end)

  it("delivers all updates preceding cancellation before completing the prompt", function()
    local updates = {}
    local permission_seen = false
    local client, ws = new_client("cancel-pending", {
      on_session_update = function(update) table.insert(updates, update) end,
      on_request_permission = function(_, _, done)
        permission_seen = true
        done(nil)
      end,
    }, { env = { AVANTE_ACP_TEST_CANCEL_UPDATES = "10000" } })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, { on_replay = function() return true end })
    assert.is_nil(load_err)

    local received_at_completion
    local result, prompt_err = operation("cancelled prompt with burst updates", function(done)
      client:send_prompt("s1", { { type = "text", text = "wait" } }, function(value, err)
        received_at_completion = #updates
        done(value, err)
      end)
      wait_for("permission before cancellation burst", function() return permission_seen end)
      client:cancel_session("s1")
    end)

    assert.is_nil(prompt_err)
    assert.equals("cancelled", result.stopReason)
    assert.equals(10000, received_at_completion)
    assert.equals(10000, #updates)
    for index, update in ipairs(updates) do
      assert.equals(index % 2 == 0 and "agent_thought_chunk" or "agent_message_chunk", update.sessionUpdate)
      assert.equals(tostring(index), update.content.text)
    end
    stop(client)
  end)

  it("delivers all large replay updates in order before completing session/load", function()
    local replayed = {}
    local fatal_error
    local client, ws = new_client("large-replay", {
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(client))

    local _, load_err = load_session(client, ws.root, {
      on_replay = function(update)
        table.insert(replayed, update)
        return true
      end,
    })

    assert.is_nil(load_err)
    assert.is_nil(fatal_error)
    assert.equals(20000, #replayed)
    for index, update in ipairs(replayed) do
      assert.equals(index % 2 == 0 and "agent_thought_chunk" or "agent_message_chunk", update.sessionUpdate)
      assert.equals(tostring(index), update.content.text)
      assert.is_true(update._replayed)
    end
    stop(client)
  end)

  it("rejects overlapping prompts for one session and accepts another after cancellation", function()
    local permission_count = 0
    local client, ws = new_client("cancel-pending", {
      on_request_permission = function(_, _, done)
        permission_count = permission_count + 1
        done(nil)
      end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local first_result
    local first_err
    local first_calls = 0
    client:send_prompt("s1", { { type = "text", text = "first" } }, function(result, err)
      first_result = result
      first_err = err
      first_calls = first_calls + 1
    end)
    wait_for("first prompt permission", function() return permission_count == 1 end)

    local second_result, second_err = operation(
      "overlapping prompt rejection",
      function(done) client:send_prompt("s1", { { type = "text", text = "second" } }, done) end
    )
    assert.is_nil(second_result)
    assert.equals("invalid_request", second_err.kind)
    assert.equals(0, first_calls)

    client:cancel_session("s1")
    wait_for("first prompt cancellation", function() return first_calls > 0 end)
    assert.equals(1, first_calls)
    assert.is_nil(first_err)
    assert.equals("cancelled", first_result.stopReason)

    local third_result, third_err = operation("prompt after cancellation", function(done)
      client:send_prompt("s1", { { type = "text", text = "third" } }, done)
      wait_for("third prompt permission", function() return permission_count == 2 end)
      client:cancel_session("s1")
    end)
    assert.is_nil(third_err)
    assert.equals("cancelled", third_result.stopReason)
    assert.equals(1, first_calls)
    stop(client)
  end)

  it("terminates an agent that ignores cancellation and settles its prompt within the grace period", function()
    local client, ws = new_client("ignore-cancel")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_calls = 0
    local prompt_result
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function(result, err)
      prompt_calls = prompt_calls + 1
      prompt_result = result
      prompt_err = err
    end)
    wait_for("silent agent prompt", function() return vim.fn.filereadable(ws.started_marker) == 1 end)
    client:cancel_session("s1")
    wait_for("ignored cancellation", function() return vim.fn.filereadable(ws.scenario_marker) == 1 end)

    assert.is_true(
      vim.wait(5000, function() return prompt_calls > 0 and client.connection_state == "disconnected" end, 10),
      "cancel must terminate the unresponsive agent within its grace period"
    )
    assert.equals(1, prompt_calls)
    assert.is_nil(prompt_result)
    assert.equals("timeout", prompt_err.kind)
    assert.is_nil(client.native)
  end)

  it("backpressures the agent stdout while polling is paused and then delivers every live update", function()
    local received = 0
    local invalid_update = false
    local padding = string.rep("x", 1018)
    local client, ws = new_client("large-live", {
      on_session_update = function(update)
        received = received + 1
        invalid_update = invalid_update or update.content.text ~= string.format("%05d:%s", received, padding)
      end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, { on_replay = function() return true end })
    assert.is_nil(load_err)

    local prompt_result
    local prompt_err
    local received_at_completion
    client:send_prompt("s1", { { type = "text", text = "burst" } }, function(result, err)
      prompt_result = result
      prompt_err = err
      received_at_completion = received
    end)
    client:_stop_polling()
    wait_for("live burst started", function() return vim.fn.filereadable(ws.started_marker) == 1 end)
    local emitted_while_paused = vim.wait(1000, function() return vim.fn.filereadable(ws.scenario_marker) == 1 end, 10)
    client:_start_polling()

    assert.is_false(emitted_while_paused, "the paused consumer must block the agent before it emits 40 MiB")
    wait_for("live burst completion", function() return received_at_completion ~= nil end)
    assert.is_nil(prompt_err)
    assert.equals("end_turn", prompt_result.stopReason)
    assert.equals(40000, received_at_completion)
    assert.equals(40000, received)
    assert.is_false(invalid_update)
    assert.equals(1, vim.fn.filereadable(ws.scenario_marker))
    stop(client)
  end)

  it("stops while agent stdout is blocked by a paused consumer", function()
    local client, ws = new_client("large-live")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, { on_replay = function() return true end })
    assert.is_nil(load_err)

    local prompt_calls = 0
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "burst" } }, function(_, err)
      prompt_calls = prompt_calls + 1
      prompt_err = err
    end)
    client:_stop_polling()
    wait_for("blocked burst started", function() return vim.fn.filereadable(ws.started_marker) == 1 end)
    local emitted_while_paused = vim.wait(1000, function() return vim.fn.filereadable(ws.scenario_marker) == 1 end, 10)

    local stopped = false
    local stop_err
    client:stop(function(err)
      stop_err = err
      stopped = true
    end)
    client:_start_polling()
    assert.is_true(vim.wait(3000, function() return stopped end, 10), "stopping must unblock the worker")
    assert.is_nil(stop_err)
    assert.equals("disconnected", client.connection_state)
    assert.is_nil(client.native)
    assert.equals(1, prompt_calls)
    assert.equals("cancelled", prompt_err.kind)
    assert.is_false(emitted_while_paused, "the agent must still be blocked when stop is requested")
  end)

  it("rejects an oversized stdout frame without waiting for its newline", function()
    local client, ws = new_client("oversized-frame")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_err
    client:send_prompt("s1", { { type = "text", text = "oversized" } }, function(_, err) prompt_err = err end)
    assert.is_true(
      vim.wait(3000, function() return prompt_err ~= nil and client.connection_state == "disconnected" end, 10),
      "an oversized frame must terminate the connection promptly"
    )
    assert.matches("frame exceeds 8 MiB", prompt_err.message)
  end)

  it("terminates the agent when stopping with a blocked stdin write", function()
    local client, ws = new_client("blocked-stdin")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)
    wait_for("sleeping agent PID", function() return vim.fn.filereadable(ws.scenario_marker) == 1 end)
    ws.process_pid = assert(tonumber(vim.fn.readfile(ws.scenario_marker)[1]))
    assert.is_true(ws.process_pid > 0)

    local prompt_calls = 0
    local prompt_err
    client:send_prompt("s1", { { type = "text", text = string.rep("x", 1024 * 1024) } }, function(_, err)
      prompt_calls = prompt_calls + 1
      prompt_err = err
    end)
    assert.is_false(vim.wait(150, function() return prompt_calls > 0 end, 10))

    local stop_calls = 0
    client:stop(function() stop_calls = stop_calls + 1 end)
    assert.is_true(
      vim.wait(
        3000,
        function() return stop_calls > 0 and prompt_calls > 0 and not (vim.uv or vim.loop).kill(ws.process_pid, 0) end,
        10
      ),
      "stop must kill the exact fixture process even when its stdin write is blocked"
    )
    assert.equals(1, stop_calls)
    assert.equals(1, prompt_calls)
    assert.is_not_nil(prompt_err)
    assert.equals("disconnected", client.connection_state)
    assert.is_nil(client.native)
  end)

  it("preserves replay boundaries when updates and the load response share one stdout batch", function()
    local order = {}
    local client, ws = new_client("batched-replay-live", {
      on_session_update = function(update) table.insert(order, "live:" .. update.content.text) end,
    })
    assert.is_nil(connect(client))
    local _, load_err = operation("batched session/load", function(done)
      client:load_session("s1", ws.root, {}, function(result, err)
        table.insert(order, "loaded")
        done(result, err)
      end, {
        on_replay = function(update)
          table.insert(order, "replay:" .. update.content.text)
          return true
        end,
      })
    end)

    assert.is_nil(load_err)
    wait_for("batched live updates", function() return #order == 5 end)
    assert.same({ "replay:1", "replay:2", "loaded", "live:1", "live:2" }, order)
    stop(client)
  end)

  it("delivers a replay larger than the event byte budget before completing the load", function()
    local received = 0
    local invalid_update = false
    local padding = string.rep("x", 1018)
    local client, ws = new_client("large-replay-bytes")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, {
      on_replay = function(update)
        received = received + 1
        invalid_update = invalid_update
          or not update._replayed
          or update.content.text ~= string.format("%05d:%s", received, padding)
        return true
      end,
    })

    assert.is_nil(load_err)
    assert.equals(12000, received)
    assert.is_false(invalid_update)
    stop(client)
  end)

  it("delivers the prompt result and all trailing stdout when the agent exits immediately", function()
    local updates = {}
    local client, ws = new_client("clean-exit-tail", {
      on_session_update = function(update) table.insert(updates, update.content.text) end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, { on_replay = function() return true end })
    assert.is_nil(load_err)

    local result, prompt_err = operation(
      "prompt before clean exit",
      function(done) client:send_prompt("s1", { { type = "text", text = "finish" } }, done) end
    )
    wait_for("clean agent exit", function() return client.connection_state == "disconnected" end)
    assert.is_nil(prompt_err)
    assert.equals("end_turn", result.stopReason)
    assert.equals(257, #updates)
    for index = 1, 256 do
      assert.equals(tostring(index), updates[index])
    end
    assert.equals("tail", updates[257])
  end)

  it("drains stdout after cancellation fails because the agent has closed stdin", function()
    local updates = {}
    local client, ws = new_client("closed-stdin-tail", {
      on_session_update = function(update) table.insert(updates, update.content.text) end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root, { on_replay = function() return true end })
    assert.is_nil(load_err)

    local prompt_result
    local prompt_err
    local prompt_calls = 0
    client:send_prompt("s1", { { type = "text", text = "finish" } }, function(result, err)
      prompt_result = result
      prompt_err = err
      prompt_calls = prompt_calls + 1
    end)
    wait_for("agent stdin closed", function() return vim.fn.filereadable(ws.scenario_marker) == 1 end)
    ws.process_pid = assert(tonumber(vim.fn.readfile(ws.scenario_marker)[1]))
    client:cancel_session("s1")
    -- Let the writer observe EPIPE before releasing the remaining stdout.
    vim.wait(100, function() return client.connection_state == "disconnected" end, 10)
    vim.fn.writefile({ "release" }, ws.output_gate)

    wait_for("closed-stdin agent exit", function() return client.connection_state == "disconnected" end)
    assert.equals(1, prompt_calls)
    assert.is_nil(prompt_err)
    assert.equals("end_turn", prompt_result.stopReason)
    assert.equals(257, #updates)
    for index = 1, 256 do
      assert.equals(tostring(index), updates[index])
    end
    assert.equals("tail", updates[257])
  end)

  it("stops within its deadline when the agent has closed stdin but keeps stdout open", function()
    local client, ws = new_client("closed-stdin-hang")
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local prompt_calls = 0
    client:send_prompt("s1", { { type = "text", text = "wait" } }, function() prompt_calls = prompt_calls + 1 end)
    wait_for("hanging agent stdin closed", function() return vim.fn.filereadable(ws.scenario_marker) == 1 end)
    ws.process_pid = assert(tonumber(vim.fn.readfile(ws.scenario_marker)[1]))
    client:cancel_session("s1")
    vim.wait(100, function() return client.connection_state == "disconnected" end, 10)

    local stop_calls = 0
    client:stop(function() stop_calls = stop_calls + 1 end)
    assert.is_true(
      vim.wait(
        3000,
        function() return stop_calls > 0 and prompt_calls > 0 and not (vim.uv or vim.loop).kill(ws.process_pid, 0) end,
        10
      ),
      "stop must terminate the agent even while waiting for stdout to close"
    )
    assert.equals(1, stop_calls)
    assert.equals(1, prompt_calls)
    assert.equals("disconnected", client.connection_state)
    assert.is_nil(client.native)
  end)

  it("retains stderr diagnostics when the agent exits with a nonzero status", function()
    local fatal_error
    local client, ws = new_client("nonzero-exit", {
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local _, prompt_err = operation(
      "failed process prompt",
      function(done) client:send_prompt("s1", { { type = "text", text = "fail" } }, done) end
    )
    assert.is_not_nil(prompt_err)
    wait_for("nonzero agent exit", function() return client.connection_state == "disconnected" end)
    assert.is_not_nil(fatal_error)
    assert.matches("fixture%-stderr%-before%-exit%-23", fatal_error.message)
  end)

  it("retains delayed stderr after the agent closes stdout before exiting", function()
    local fatal_error
    local client, ws = new_client("stdout-close-before-exit", {
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)

    local _, prompt_err = operation(
      "stdout closed before exit",
      function(done) client:send_prompt("s1", { { type = "text", text = "fail" } }, done) end
    )
    assert.is_not_nil(prompt_err)
    wait_for("delayed process exit", function() return client.connection_state == "disconnected" end)
    assert.is_not_nil(fatal_error)
    assert.matches("fixture%-stderr%-after%-stdout%-close", fatal_error.message)
  end)

  it("drains a stderr burst after stdout EOF while waiting for process exit", function()
    local fatal_error
    local client, ws = new_client("stdout-close-stderr-burst", {
      on_error = function(err) fatal_error = err end,
    })
    assert.is_nil(connect(client))
    local _, load_err = load_session(client, ws.root)
    assert.is_nil(load_err)
    local _, prompt_err = operation(
      "stderr burst after stdout EOF",
      function(done) client:send_prompt("s1", { { type = "text", text = "fail with stderr" } }, done) end
    )
    assert.is_not_nil(prompt_err)
    wait_for("stderr burst process exit", function() return client.connection_state == "disconnected" end)
    assert.is_not_nil(fatal_error)
    assert.matches("fixture%-stderr%-after%-stdout%-close", fatal_error.message)
    assert.matches("23", fatal_error.message)
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
