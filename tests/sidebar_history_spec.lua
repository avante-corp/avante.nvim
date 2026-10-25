local stub = require("luassert.stub")

local Config = require("avante.config")
local HistoryMessage = require("avante.history.message")
local Llm = require("avante.llm")
local Path = require("avante.path")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("Sidebar request history", function()
  local bufnr
  local saved_acp_providers
  local saved_login
  local saved_provider
  local stubs

  before_each(function()
    if not Config.windows then Config.setup({}) end
    saved_acp_providers = Config.acp_providers
    saved_login = vim.g.avante_login
    saved_provider = Config.provider
    bufnr = vim.api.nvim_create_buf(false, true)
    stubs = {
      stub(Path.history, "save"),
      stub(Path.history, "write"),
      stub(Utils, "warn"),
    }
  end)

  after_each(function()
    Config.acp_providers = saved_acp_providers
    Config.provider = saved_provider
    vim.g.avante_login = saved_login
    for _, value in ipairs(stubs) do
      value:revert()
    end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
  end)

  it("rejects direct new-chat calls while generating", function()
    local sidebar = setmetatable({
      is_generating = true,
      code = { bufnr = bufnr },
      reload_chat_history = function() end,
      update_content = function() end,
      create_todos_container = function() end,
    }, { __index = Sidebar })

    local created = sidebar:new_chat()

    assert.is_false(created)
  end)

  it("does not preconnect ACP against the previous history for a new chat", function()
    local previous = { acp_session_id = "previous-session" }
    local submitted = {}
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = {} }
    vim.g.avante_login = true
    local sidebar = setmetatable({
      chat_history = previous,
      is_open = function() return true end,
      focus = function() end,
      resume_pending_acp_import = function() error("must not resume the previous history") end,
      handle_submit = function(_, request) submitted[#submitted + 1] = request end,
    }, { __index = Sidebar })

    sidebar:open({ new_chat = true })

    assert.equals("previous-session", previous.acp_session_id)
    assert.same({}, submitted)
  end)

  it("still preconnects ACP when opening the current chat", function()
    local submitted = {}
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = {} }
    vim.g.avante_login = true
    local sidebar = setmetatable({
      is_open = function() return true end,
      focus = function() end,
      resume_pending_acp_import = function() end,
      handle_submit = function(_, request) submitted[#submitted + 1] = request end,
    }, { __index = Sidebar })

    sidebar:open({})

    assert.same({ "" }, submitted)
  end)

  it("adds request messages to the captured history", function()
    local original = { filename = "original.json", title = "untitled", messages = {} }
    local current = { filename = "current.json", title = "untitled", messages = {} }
    local sidebar = setmetatable({
      code = { bufnr = bufnr },
      chat_history = current,
      throttled_update_content = function() end,
    }, { __index = Sidebar })
    local message = HistoryMessage:new("assistant", "answer")

    sidebar:add_history_messages({ message }, { history = original, bufnr = bufnr })

    assert.same({ message }, original.messages)
    assert.same({}, current.messages)
  end)

  it("loads the same filename from another project during generation", function()
    local original = { filename = "original.json", messages = {} }
    local other = { filename = "original.json", messages = { HistoryMessage:new("user", "other project") } }
    local sidebar = setmetatable({
      is_generating = true,
      code = { bufnr = bufnr },
      chat_history = original,
      chat_history_project_root = "/original-project",
    }, { __index = Sidebar })
    stubs[#stubs + 1] = stub(Path.history, "load").returns(other)

    sidebar:reload_chat_history(other.filename, "/other-project")

    assert.equals(other, sidebar.chat_history)
    assert.equals("/other-project", sidebar.chat_history_project_root)
  end)

  it("reloads saved history when no request is generating", function()
    local original = { filename = "original.json", messages = {} }
    local updated = { filename = "original.json", messages = { HistoryMessage:new("user", "saved update") } }
    local sidebar = setmetatable({
      is_generating = false,
      code = { bufnr = bufnr },
      chat_history = original,
      chat_history_project_root = "/original-project",
    }, { __index = Sidebar })
    stubs[#stubs + 1] = stub(Path.history, "load").returns(updated)

    sidebar:reload_chat_history(original.filename, "/original-project")

    assert.equals(updated, sidebar.chat_history)
  end)

  it("reports Codex-style usage after each turn and preserves latest context usage", function()
    local history = { filename = "usage.json", messages = {} }
    local stream_opts
    local sidebar = setmetatable({
      code = { bufnr = bufnr },
      chat_history = history,
      containers = { result = { bufnr = bufnr } },
      file_selector = { get_selected_filepaths = function() return {} end },
      update_content = function() end,
      throttled_update_content = function() end,
      clear_state = function() end,
      render_state = function() end,
      get_generate_prompts_options = function(self, _, cb)
        cb({ session_ctx = { project_root = self.chat_history_project_root } })
      end,
    }, { __index = Sidebar })
    stubs[#stubs + 1] = stub(Llm, "stream").invokes(function(opts) stream_opts = opts end)

    sidebar:handle_submit("first task")
    stream_opts.update_tokens_usage({
      prompt_tokens = 100,
      completion_tokens = 10,
      total_tokens = 110,
      cached_input_tokens = 60,
      cache_creation_input_tokens = 0,
      reasoning_tokens = 4,
    })
    local latest = {
      prompt_tokens = 40,
      completion_tokens = 6,
      total_tokens = 46,
      cached_input_tokens = 20,
      cache_creation_input_tokens = 0,
      reasoning_tokens = 2,
    }
    stream_opts.update_tokens_usage(latest)
    stream_opts.on_messages_add({ HistoryMessage:new("assistant", "Task Completed") })
    stream_opts.on_stop({ reason = "complete" })

    local summary = history.messages[#history.messages]
    assert.is_true(summary.just_for_display)
    assert.is_true(summary.is_usage_summary)
    assert.same(latest, stream_opts.get_tokens_usage())
    assert.same(
      "\nUsage · 2 requests · tokens\nTotal        76\nInput        60\nOutput       16\nCached       80 (57.14%)\nReasoning    6",
      summary.message.content
    )
    assert.same("Task Completed", history.messages[#history.messages - 1].message.content)
    assert.same(2, #sidebar:get_history_messages_for_api({ all = true }))

    sidebar:handle_submit("second task")
    stream_opts.update_tokens_usage({
      prompt_tokens = 12345,
      completion_tokens = 2,
      total_tokens = 12347,
      cached_input_tokens = 0,
    })
    stream_opts.on_messages_add({ HistoryMessage:new("assistant", "Plain reply without a completion tool.") })
    assert.same("Plain reply without a completion tool.", history.messages[#history.messages].message.content)
    stream_opts.on_stop({ reason = "complete" })
    local second = history.messages[#history.messages].message.content
    local rendered =
      require("avante.history.render").message_to_lines(history.messages[#history.messages], history.messages)
    sidebar.expanded_message_uuids = {}
    assert.same(rendered, sidebar:_get_message_lines({}, history.messages[#history.messages], history.messages))
    assert.same("Title", rendered[2].sections[1][2])
    assert.same("Number", rendered[3].sections[2][2])
    assert.same("", tostring(rendered[1]))
    assert.same("Usage · 1 request · tokens", tostring(rendered[2]))
    assert.matches("Input        12,345", second, nil, true)
    assert.matches("Cached       0 (0.00%)", second, nil, true)
    assert.matches("Total        12,347", second, nil, true)
    assert.matches("Output       2", second, nil, true)
    assert.matches("Reasoning    not reported", second, nil, true)

    sidebar:handle_submit("partially reported task")
    stream_opts.update_tokens_usage(latest)
    stream_opts.update_tokens_usage({ prompt_tokens = 5, completion_tokens = 2, total_tokens = 7 })
    stream_opts.on_stop({ reason = "complete" })
    local partial = history.messages[#history.messages].message.content
    assert.matches("Input        20 (partial)", partial, nil, true)
    assert.matches("Cached       20 (partial)", partial, nil, true)
    assert.is_nil(partial:find("%%"))
    assert.matches("Output       8", partial, nil, true)
    assert.matches("Reasoning    2 (partial)", partial, nil, true)
    assert.matches("Total        26 (partial)", partial, nil, true)

    sidebar:handle_submit("task without cache counters")
    stream_opts.update_tokens_usage({ prompt_tokens = 100, completion_tokens = 10, total_tokens = 110 })
    stream_opts.on_stop({ reason = "complete" })
    local unknown_cache = history.messages[#history.messages].message.content
    assert.matches("Total        not reported", unknown_cache, nil, true)
    assert.matches("Input        not reported", unknown_cache, nil, true)
    assert.matches("Cached       not reported", unknown_cache, nil, true)
    assert.is_nil(unknown_cache:find("%%"))
    assert.matches("Output       10", unknown_cache, nil, true)

    sidebar:handle_submit("fully cached task without a reported total")
    stream_opts.update_tokens_usage({ prompt_tokens = 100, cached_input_tokens = 100, completion_tokens = 10 })
    stream_opts.on_stop({ reason = "complete" })
    local fully_cached = history.messages[#history.messages].message.content
    assert.matches("Total        10", fully_cached, nil, true)
    assert.matches("Input        0", fully_cached, nil, true)
    assert.matches("Cached       100 (100.00%)", fully_cached, nil, true)

    sidebar:handle_submit("task without output counters")
    stream_opts.update_tokens_usage({ prompt_tokens = 100, cached_input_tokens = 60 })
    stream_opts.on_stop({ reason = "complete" })
    local unknown_output = history.messages[#history.messages].message.content
    assert.matches("Total        not reported", unknown_output, nil, true)
    assert.matches("Input        40", unknown_output, nil, true)
    assert.matches("Cached       60 (60.00%)", unknown_output, nil, true)

    sidebar:handle_submit("task without input tokens")
    stream_opts.update_tokens_usage({ prompt_tokens = 0, cached_input_tokens = 0, completion_tokens = 1 })
    stream_opts.on_stop({ reason = "complete" })
    local zero_input = history.messages[#history.messages].message.content
    assert.matches("Cached       0\n", zero_input, nil, true)
    assert.is_nil(zero_input:find("%%"))

    sidebar:handle_submit("task with only cache counters")
    stream_opts.update_tokens_usage({ cached_input_tokens = 60 })
    stream_opts.on_stop({ reason = "complete" })
    local cache_only = history.messages[#history.messages].message.content
    assert.matches("Cached       60\n", cache_only, nil, true)
    assert.is_nil(cache_only:find("%%"))

    sidebar:handle_submit("cancelled task")
    stream_opts.update_tokens_usage(latest)
    local count = #history.messages
    stream_opts.on_stop({ reason = "cancelled" })
    assert.same(count, #history.messages)

    sidebar:handle_submit("task without reported usage")
    stream_opts.update_tokens_usage({})
    stream_opts.on_stop({ reason = "complete" })
    local missing = history.messages[#history.messages].message.content
    assert.matches("Input        not reported", missing, nil, true)
    assert.matches("Total        not reported", missing, nil, true)
  end)

  it("clears a finished request state after the visible history changes", function()
    local original = { filename = "original.json", messages = {} }
    local current = { filename = "current.json", messages = {} }
    local stream_opts
    local cleared = 0
    local sidebar = setmetatable({
      code = { bufnr = bufnr },
      chat_history = original,
      containers = { result = { bufnr = bufnr } },
      file_selector = { get_selected_filepaths = function() return {} end },
      update_content = function() end,
      clear_state = function() cleared = cleared + 1 end,
      render_state = function() end,
      add_history_messages = function() end,
      get_generate_prompts_options = function(self, _, cb)
        cb({ session_ctx = { project_root = self.chat_history_project_root } })
      end,
    }, { __index = Sidebar })
    stubs[#stubs + 1] = stub(Llm, "stream").invokes(function(opts) stream_opts = opts end)

    sidebar:handle_submit("hello")
    sidebar.chat_history = current
    stream_opts.on_stop({ reason = "complete" })

    assert.is_false(sidebar.is_generating)
    assert.is_nil(sidebar.current_state)
    assert.equals(2, cleared)
  end)

  it("saves to the captured project and refreshes a reloaded copy of the same history", function()
    local project_root = "/original-project"
    local original = { filename = "original.json", messages = {} }
    local reloaded = { filename = "original.json", messages = {} }
    local stream_opts
    local saved_history
    local saved_root
    local sidebar = setmetatable({
      code = { bufnr = bufnr },
      chat_history = original,
      chat_history_project_root = project_root,
      containers = { result = { bufnr = bufnr } },
      file_selector = { get_selected_filepaths = function() return {} end },
      update_content = function() end,
      clear_state = function() end,
      render_state = function() end,
      get_generate_prompts_options = function(self, _, cb)
        cb({ session_ctx = { project_root = self.chat_history_project_root } })
      end,
    }, { __index = Sidebar })
    stubs[#stubs + 1] = stub(Llm, "stream").invokes(function(opts) stream_opts = opts end)
    Path.history.save:revert()
    stubs[1] = stub(Path.history, "save").invokes(function(_, history, root)
      saved_history = vim.deepcopy(history)
      saved_root = root
    end)
    stubs[#stubs + 1] = stub(Path.history, "load").invokes(function() return vim.deepcopy(saved_history) end)

    sidebar:handle_submit("hello")
    vim.api.nvim_buf_delete(bufnr, { force = true })
    sidebar.chat_history = reloaded
    stream_opts.on_messages_add({ HistoryMessage:new("assistant", "answer") })
    stream_opts.on_stop({ reason = "complete" })

    assert.equals(project_root, saved_root)
    assert.equals("answer", sidebar.chat_history.messages[#sidebar.chat_history.messages].message.content)
  end)
end)
