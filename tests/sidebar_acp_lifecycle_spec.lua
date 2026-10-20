local stub = require("luassert.stub")
local ACPClient = require("avante.libs.acp_client")
local Config = require("avante.config")
local History = require("avante.history")
local Llm = require("avante.llm")
local Path = require("avante.path")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("Sidebar ACP request lifecycle", function()
  local stubs, cleanups, provider, providers, prompt_logger, ask_opts, behaviour

  local function replace(object, name, fn)
    local replacement = stub(object, name).invokes(fn or function() end)
    table.insert(stubs, replacement)
    return replacement
  end

  before_each(function()
    stubs = {}
    cleanups = {}
    provider, providers, prompt_logger = Config.provider, Config.acp_providers, Config.prompt_logger
    ask_opts, behaviour = Config.ask_opts, Config.behaviour
    Config.ask_opts, Config.behaviour = {}, {}
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
    Config.prompt_logger = { enabled = false }
    replace(vim.keymap, "set")
    replace(vim.keymap, "del")
    replace(Path.history, "save")
  end)

  after_each(function()
    for _, cleanup in ipairs(cleanups) do
      cleanup()
    end
    for _, replacement in ipairs(stubs) do
      replacement:revert()
    end
    Config.provider, Config.acp_providers, Config.prompt_logger = provider, providers, prompt_logger
    Config.ask_opts, Config.behaviour = ask_opts, behaviour
  end)

  local function submit(opts)
    opts = opts or {}
    local captured, complete_prompts
    replace(Llm, "stream", function(stream_opts) captured = stream_opts end)
    local old_chat =
      { messages = {}, filename = "old.json", tokens_usage = { prompt_tokens = 10, completion_tokens = 2 } }
    old_chat.acp_session_id = opts.import and opts.import.session_id
    local sidebar = setmetatable({
      code = { bufnr = vim.api.nvim_get_current_buf() },
      containers = { result = { bufnr = vim.api.nvim_get_current_buf() } },
      file_selector = { get_selected_filepaths = function() return {} end },
      chat_history = old_chat,
      pending_acp_import = opts.import,
      acp_client = opts.client,
      acp_client_generation = 0,
      is_generating = false,
    }, { __index = Sidebar })
    for _, name in ipairs({
      "update_content",
      "throttled_update_content",
      "save_history",
      "clear_state",
      "render_state",
      "render_result",
      "create_todos_container",
    }) do
      sidebar[name] = function() end
    end
    sidebar.get_generate_prompts_options = function(_, _, done)
      complete_prompts = function()
        done({ history_messages = old_chat.messages })
        return captured
      end
      if not opts.defer_prompts then complete_prompts() end
    end
    sidebar.get_history_messages_for_api = function(self) return self.chat_history.messages end
    sidebar:handle_submit(opts.request or "old question")
    return sidebar, old_chat, captured, complete_prompts
  end

  it("keeps the submitted project and provider while prompt preparation is pending", function()
    local project_root = "/tmp/original-project"
    replace(Utils.root, "get", function() return project_root end)
    local original_provider = {
      command = "/bin/true",
      args = { "original-agent" },
      mcp_servers = { { name = "original-mcp", command = "/bin/true", args = {}, env = {} } },
    }
    Config.acp_providers["test-acp"] = vim.deepcopy(original_provider)
    local sidebar, _, pending, complete_prompts = submit({ defer_prompts = true })
    assert.is_nil(pending)

    project_root = "/tmp/other-project"
    Config.acp_providers["test-acp"].mcp_servers[1].name = "changed-mcp"
    Config.acp_providers["other-acp"] = { command = "/bin/false", mcp_servers = {} }
    Config.provider = "other-acp"
    local stream_options = complete_prompts()

    assert.equals(sidebar, stream_options.acp_sidebar)
    assert.same({ cwd = "/tmp/original-project", provider = original_provider }, stream_options.acp_context)
  end)

  it("keeps receiving the ACP response after an agent write reloads the attached code buffer", function()
    local original_options = Config._options
    Config.setup({})
    local code_winid = vim.api.nvim_get_current_win()
    local original_buffer = vim.api.nvim_win_get_buf(code_winid)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "return 1" }, filepath)
    local code_buffer = vim.fn.bufadd(filepath)
    local replacement_buffer
    vim.fn.bufload(code_buffer)
    vim.api.nvim_win_set_buf(code_winid, code_buffer)
    vim.bo[code_buffer].autoread = true
    local sidebar, history, callbacks = submit()
    sidebar.id = vim.api.nvim_get_current_tabpage()
    sidebar.code.winid = code_winid
    for _, name in ipairs({
      "create_input_container",
      "create_selected_files_container",
      "create_selected_code_container",
      "on_mount",
      "setup_colors",
      "update_content_with_history",
    }) do
      sidebar[name] = function() end
    end
    sidebar.get_result_container_width = function() return 30 end
    sidebar.get_result_container_height = function() return 10 end
    replace(Path.history, "load", function() return vim.deepcopy(history) end)
    table.insert(cleanups, function()
      sidebar.code.winid = nil
      if sidebar.augroup then vim.api.nvim_del_augroup_by_id(sidebar.augroup) end
      if sidebar.containers.result.unmount then sidebar.containers.result:unmount() end
      vim.api.nvim_win_set_buf(code_winid, original_buffer)
      if vim.api.nvim_buf_is_valid(code_buffer) then vim.api.nvim_buf_delete(code_buffer, { force = true }) end
      if replacement_buffer and vim.api.nvim_buf_is_valid(replacement_buffer) then
        vim.api.nvim_buf_delete(replacement_buffer, { force = true })
      end
      vim.uv.fs_unlink(filepath)
      Config._options = original_options
    end)
    sidebar:render({ win = { position = "right" } })
    local detached = false
    vim.api.nvim_buf_attach(code_buffer, false, { on_detach = function() detached = true end })
    -- Give each write a distinct timestamp even on filesystems with coarse timestamps.
    local mtime = os.time()
    assert.is_true(require("avante.utils.file").write_atomically(filepath, "return 'updated by the ACP tool'\n"))
    assert(vim.uv.fs_utime(filepath, mtime + 2, mtime + 2))

    vim.cmd("checktime " .. code_buffer)
    local flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(500, function() return flushed end, 5))
    assert.is_true(detached)
    assert.same({ "return 'updated by the ACP tool'" }, vim.api.nvim_buf_get_lines(code_buffer, 0, -1, false))
    assert.is_true(require("avante.utils.file").write_atomically(filepath, "return 'updated again by the ACP tool'\n"))
    assert(vim.uv.fs_utime(filepath, mtime + 4, mtime + 4))
    vim.cmd("checktime " .. code_buffer)
    flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(500, function() return flushed end, 5))
    assert.same({ "return 'updated again by the ACP tool'" }, vim.api.nvim_buf_get_lines(code_buffer, 0, -1, false))
    callbacks.on_messages_add({ History.Message:new("assistant", "AFTER_TOOL") })
    callbacks.on_stop({ reason = "complete" })
    local finished = false
    vim.defer_fn(function() finished = true end, 0)
    assert.is_true(vim.wait(500, function() return finished end, 5))

    assert.is_false(sidebar.is_generating)
    assert.equals("succeeded", sidebar.current_state)
    assert.equals("AFTER_TOOL", sidebar.chat_history.messages[#sidebar.chat_history.messages].message.content)

    replacement_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(code_winid, replacement_buffer)
    vim.api.nvim_buf_delete(code_buffer, { force = true })
    assert.is_true(vim.wait(500, function() return sidebar.code.bufnr == replacement_buffer end, 5))
    assert.not_equals(history, sidebar.chat_history)
  end)

  local function switch_chat(sidebar)
    sidebar:stop_acp_client()
    local new_chat = {
      messages = { History.Message:new("user", "new question", { is_user_submission = true }) },
      filename = "new.json",
      tokens_usage = { prompt_tokens = 20, completion_tokens = 4 },
      todos = { { id = "new", content = "new task", status = "todo" } },
    }
    sidebar.chat_history = new_chat
    sidebar.is_generating = true
    sidebar.current_state = "generating"
    return new_chat
  end

  it("does not append an old response or failure to the newly selected chat", function()
    local sidebar, _, callbacks = submit()
    local new_chat = switch_chat(sidebar)

    callbacks.on_messages_add({ History.Message:new("assistant", "OLD_TAIL") })
    callbacks.on_stop({ reason = "error", error = { kind = "cancelled", message = "ACP client stopped" } })

    assert.equals(1, #new_chat.messages)
    assert.equals("new question", new_chat.messages[1].message.content)
    assert.is_true(sidebar.is_generating)
    assert.equals("generating", sidebar.current_state)
  end)

  it("does not let stale state or metadata callbacks change the new chat", function()
    local sidebar, _, callbacks = submit()
    local new_chat = switch_chat(sidebar)
    local expected_todos = vim.deepcopy(new_chat.todos)
    local expected_usage = vim.deepcopy(new_chat.tokens_usage)
    local renders = 0
    sidebar.render_result = function() renders = renders + 1 end
    replace(vim, "schedule", function(fn) fn() end)

    callbacks.on_state_change("tool calling")
    callbacks.update_todos({ { id = "old", content = "old task", status = "done" } })
    callbacks.update_tokens_usage({ prompt_tokens = 99, completion_tokens = 88 })
    callbacks.on_acp_config_change()

    assert.equals("generating", sidebar.current_state)
    assert.same(expected_todos, new_chat.todos)
    assert.same(expected_usage, new_chat.tokens_usage)
    assert.equals(0, renders)
  end)

  it("keeps the new connection alive when stopping an earlier session import", function()
    replace(Utils, "error")
    replace(Utils.root, "get", function() return "/tmp" end)
    local client = ACPClient:new({ command = "agent", handlers = {} })
    client.state = "ready"
    client.native = { load_session = function() return { operationId = 1 } end, stop = function() end }
    local import = { session_id = "s1", filename = "old.json", created = false }
    local sidebar, _, callbacks = submit({ request = "", import = import, client = client })
    Llm._load_acp_session_and_continue(callbacks, client, "s1")
    local new_chat = switch_chat(sidebar)
    local replacement = { stop = stub() }
    sidebar.acp_client = replacement

    client:_handle_event({ type = "state_changed", state = "disconnected" })

    assert.equals(replacement, sidebar.acp_client)
    assert.stub(replacement.stop).was_not_called()
    assert.equals(new_chat, sidebar.chat_history)
    assert.is_true(sidebar.is_generating)
    assert.is_nil(sidebar.pending_acp_import)
  end)

  for _, outcome in ipairs({ "replay", "error" }) do
    it("ignores an import " .. outcome .. " callback after the chat changes", function()
      replace(Utils, "error")
      local import = { session_id = "s1", filename = "old.json", created = false }
      local sidebar, _, callbacks = submit({ request = "", import = import })
      local new_chat = { filename = "new.json", acp_session_id = "s2", messages = {} }
      sidebar.chat_history = new_chat
      local replacement = { stop = stub() }
      sidebar.acp_client = replacement

      if outcome == "replay" then
        callbacks.on_acp_session_replay("s1", { History.Message:new("assistant", "old response") })
      else
        callbacks.on_acp_session_load_error("s1", { kind = "cancelled", message = "old request stopped" })
      end

      assert.equals(replacement, sidebar.acp_client)
      assert.stub(replacement.stop).was_not_called()
      assert.same({}, new_chat.messages)
    end)
  end

  it("does not expose the new chat to an old request's readers", function()
    local sidebar, _, callbacks = submit()
    local new_chat = switch_chat(sidebar)
    replace(Path.history, "load", function() return new_chat end)

    local messages = callbacks.get_history_messages() or {}
    local usage = callbacks.get_tokens_usage()
    local todos = callbacks.get_todos() or {}

    for _, message in ipairs(messages) do
      assert.not_equals("new question", message.message.content)
    end
    assert.is_false(vim.deep_equal(new_chat.tokens_usage, usage))
    for _, todo in ipairs(todos) do
      assert.not_equals("new", todo.id)
    end
  end)
end)
