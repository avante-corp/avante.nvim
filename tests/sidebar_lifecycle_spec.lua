local stub = require("luassert.stub")

local Api = require("avante.api")
local Avante = require("avante")
local Config = require("avante.config")
local History = require("avante.history")
local Llm = require("avante.llm")
local LLMTools = require("avante.llm_tools")
local Path = require("avante.path")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("Sidebar active request lifecycle", function()
  local sidebar, storage, code_buf, other_buf, code_win, stream_opts
  local saved_storage, saved_login, saved_sidebar, saved_current, saved_cwd
  local stubs

  before_each(function()
    Config.setup({
      provider = "claude",
      mode = "legacy",
      behaviour = { enable_token_counting = false, auto_add_current_file = false },
    })
    Config.acp_providers = {}
    Config.ask_opts = {}
    saved_storage = Config.history.storage_path
    saved_login = vim.g.avante_login
    saved_current = vim.tbl_extend("force", {}, Avante.current)
    saved_cwd = vim.fn.getcwd()
    storage = vim.fn.tempname()
    Config.history.storage_path = storage .. "/history"
    for _, project in ipairs({ "a", "b" }) do
      vim.fn.mkdir(storage .. "/" .. project .. "/.git", "p")
      vim.fn.writefile({ "project " .. project }, storage .. "/" .. project .. "/test.lua")
    end
    vim.fn.chdir(storage .. "/a")
    code_buf = vim.fn.bufadd(storage .. "/a/test.lua")
    other_buf = vim.fn.bufadd(storage .. "/b/test.lua")
    vim.fn.bufload(code_buf)
    vim.fn.bufload(other_buf)
    vim.api.nvim_set_current_buf(code_buf)
    code_win = vim.api.nvim_get_current_win()
    vim.fn.sign_define("AvanteInputPromptSign", { text = Config.windows.input.prefix })
    vim.g.avante_login = true
    sidebar = Sidebar:new(vim.api.nvim_get_current_tabpage())
    saved_sidebar = Avante.sidebars[sidebar.id]
    Avante.sidebars[sidebar.id] = sidebar
    Avante.current.sidebar = sidebar
    sidebar.get_generate_prompts_options = function(self, _, cb)
      if cb then cb({ session_ctx = { project_root = self.chat_history_project_root } }) end
    end
    stubs = {}
    stream_opts = nil
    sidebar:open({})
  end)

  after_each(function()
    Llm.cancel_inflight_request()
    if sidebar.is_generating and stream_opts then stream_opts.on_stop({ reason = "cancelled" }) end
    vim.wait(1150)
    sidebar:close()
    sidebar.code.winid = nil
    for _, value in ipairs(stubs) do
      value:revert()
    end
    Avante.sidebars[sidebar.id] = saved_sidebar
    Avante.current = saved_current
    Config.history.storage_path = saved_storage
    vim.g.avante_login = saved_login
    for _, bufnr in ipairs({ code_buf, other_buf }) do
      if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end
    vim.fn.chdir(saved_cwd)
    vim.fn.delete(storage, "rf")
  end)

  local function start_captured_request()
    stubs[#stubs + 1] = stub(Llm, "stream").invokes(function(opts) stream_opts = opts end)
    sidebar:handle_submit("initial question")
  end

  for _, entry in ipairs({
    { name = "Ask", open = function() Api.ask({ question = "other project", floating = false }) end },
    { name = "Toggle", open = function() Avante.toggle_sidebar({}) end },
    { name = "open_sidebar", open = function() Avante.open_sidebar({}) end },
  }) do
    it("rejects " .. entry.name .. " for another project while the active sidebar is hidden", function()
      start_captured_request()
      local history = sidebar.chat_history
      local root = sidebar.chat_history_project_root
      local ask_opts = Config.ask_opts
      vim.api.nvim_set_current_win(sidebar.containers.result.winid)
      Api.ask({ floating = false })
      assert.is_false(sidebar:is_open())
      assert.is_true(sidebar.is_generating)
      vim.api.nvim_set_current_win(code_win)
      vim.api.nvim_set_current_buf(other_buf)

      entry.open()

      assert.equals(ask_opts, Config.ask_opts)
      assert.is_false(sidebar:is_open())
      assert.equals(code_buf, sidebar.code.bufnr)
      assert.equals(history, sidebar.chat_history)
      assert.equals(root, sidebar.chat_history_project_root)
    end)
  end

  it("allows reopening the same active chat and preserves followups on disk", function()
    start_captured_request()
    local history = sidebar.chat_history
    sidebar:close()
    vim.api.nvim_set_current_win(code_win)

    Avante.toggle_sidebar({})
    sidebar:handle_submit("important followup")
    assert.equals("important followup", stream_opts.get_history_messages({ all = true })[2].message.content)
    stream_opts.on_messages_add({ History.Message:new("assistant", "answer") })
    stream_opts.on_stop({ reason = "complete" })

    assert.equals(history, sidebar.chat_history)
    local saved = Path.history.load(code_buf, history.filename, sidebar.chat_history_project_root)
    assert.same(
      { "initial question", "important followup", "answer" },
      vim.tbl_map(function(message) return message.message.content end, saved.messages)
    )
  end)

  it("keeps the session root after its original code window and buffer are removed", function()
    start_captured_request()
    local root = sidebar.chat_history_project_root
    vim.api.nvim_set_current_win(sidebar.containers.result.winid)
    vim.api.nvim_win_close(code_win, true)
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.wait(50)

    local ok, resolved_root = pcall(Utils.get_project_root)
    -- Leave a normal window so closing the sidebar can clean up all its splits.
    vim.cmd("new")

    assert.is_true(ok, resolved_root)
    assert.equals(root, resolved_root)
  end)

  it("refuses a session's relative tool path after the user focuses another project", function()
    local root = sidebar.chat_history_project_root
    local callback_error
    vim.api.nvim_set_current_win(code_win)
    vim.api.nvim_set_current_buf(other_buf)

    local _, err = LLMTools.process_tool_use({ require("avante.llm_tools.view") }, {
      name = "view",
      id = "view-other-project",
      input = { path = "test.lua" },
    }, {
      session_ctx = { project_root = root },
      on_complete = function(_, error) callback_error = error end,
    })

    assert.is_not_nil(err or callback_error)
  end)

  it("executes a session's relative tool path in its original project", function()
    local root = sidebar.chat_history_project_root
    local result, err
    vim.api.nvim_set_current_win(code_win)

    local _, tool_err = LLMTools.process_tool_use({ require("avante.llm_tools.view") }, {
      name = "view",
      id = "view-original-project",
      input = { path = "test.lua" },
    }, {
      session_ctx = { project_root = root },
      on_complete = function(content, error)
        result, err = content, error
      end,
    })

    assert.is_nil(tool_err)
    assert.is_nil(err)
    assert.equals("project a", vim.json.decode(result).content)
  end)

  local function start_async_tool()
    local tool_started = false
    local tools = {
      { name = "waiting_tool", func = function() tool_started = true end },
    }
    stubs[#stubs + 1] = stub(Llm, "generate_prompts").returns({ tools = tools, messages = {} })
    stubs[#stubs + 1] = stub(Llm, "request").invokes(function(opts)
      opts.handler_opts.on_messages_add({
        History.Message:new("assistant", {
          type = "tool_use",
          id = "pending-tool",
          name = "waiting_tool",
          input = {},
        }, { turn_id = "tool-turn", state = "generated" }),
      })
      opts.handler_opts.on_stop({ reason = "tool_use" })
      return { cancel = function() end }
    end)
    sidebar:handle_submit("start task")
    assert.is_true(tool_started)
    return History.Helpers.get_tool_use_message("pending-tool", sidebar.chat_history.messages)
  end

  it("keeps cleared history empty after a cancelled asynchronous tool settles", function()
    start_async_tool()
    local filename = sidebar.chat_history.filename
    local root = sidebar.chat_history_project_root

    sidebar:clear_history()
    assert.equals(0, #sidebar.chat_history.messages)
    vim.wait(1200)

    local saved = Path.history.load(code_buf, filename, root)
    assert.same({ 0, 0 }, { #sidebar.chat_history.messages, #saved.messages })
  end)

  it("clears the calling flag when an asynchronous tool is cancelled", function()
    local message = start_async_tool()
    assert.is_true(message.is_calling)

    Llm.cancel_inflight_request()
    assert.is_true(vim.wait(500, function() return message.is_calling == false end, 1))

    assert.is_false(sidebar.is_generating)
  end)
end)
