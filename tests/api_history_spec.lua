local stub = require("luassert.stub")

local Api = require("avante.api")
local Avante = require("avante")
local Config = require("avante.config")
local HistorySelector = require("avante.history_selector")
local Path = require("avante.path")
local PromptInput = require("avante.ui.prompt_input")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("api history", function()
  local sidebar_buf
  local code_buf
  local opened_buf
  local on_history_select
  local saved_ask_opts
  local sidebar
  local stubs

  before_each(function()
    if not Config.windows then Config.setup({}) end
    saved_ask_opts = Config.ask_opts
    sidebar_buf = vim.api.nvim_create_buf(false, true)
    code_buf = vim.api.nvim_create_buf(false, true)
    Utils.mark_as_sidebar_buffer(sidebar_buf)
    vim.api.nvim_set_current_buf(sidebar_buf)
    opened_buf = nil
    on_history_select = nil
    sidebar = {
      can_open = Sidebar.can_open,
      code = { bufnr = code_buf },
      is_generating = false,
      is_open = function() return true end,
      containers = { result = { bufnr = sidebar_buf }, input = { bufnr = sidebar_buf } },
      close = function() end,
      render = function() end,
      new_chat = function() end,
      update_content_with_history = function() end,
      create_todos_container = function() end,
      initialize_token_count = function() end,
      focus_input = function() end,
    }

    stubs = {
      stub(Avante, "get").returns(sidebar),
      stub(Avante, "is_sidebar_open").returns(true),
      stub(Avante, "open_sidebar"),
      stub(HistorySelector, "open").invokes(function(bufnr, cb)
        opened_buf = bufnr
        on_history_select = cb
      end),
      stub(Path.history, "save_latest_filename"),
      stub(Utils, "warn"),
    }
  end)

  after_each(function()
    Config.ask_opts = saved_ask_opts
    for _, value in ipairs(stubs) do
      value:revert()
    end
    if vim.api.nvim_buf_is_valid(sidebar_buf) then vim.api.nvim_buf_delete(sidebar_buf, { force = true }) end
    if vim.api.nvim_buf_is_valid(code_buf) then vim.api.nvim_buf_delete(code_buf, { force = true }) end
  end)

  it("lists the code buffer history when invoked from the sidebar", function()
    Api.select_history()

    assert.equals(code_buf, opened_buf)
  end)

  it("keeps the current buffer when invoked outside the sidebar", function()
    vim.api.nvim_set_current_buf(code_buf)

    Api.select_history()

    assert.equals(code_buf, opened_buf)
  end)

  it("does not open history selection while a request is generating", function()
    sidebar.is_generating = true

    Api.select_history()

    assert.is_nil(opened_buf)
  end)

  it("does not switch history when generation starts while the selector is open", function()
    Api.select_history()
    sidebar.is_generating = true

    on_history_select("other.json")

    assert.stub(Path.history.save_latest_filename).was_not_called()
  end)

  it("does not create a new chat while a request is generating", function()
    local current = { ask = false, project_root = "/current" }
    Config.ask_opts = current
    local new_chat_calls = 0
    sidebar.is_generating = true
    sidebar.new_chat = function() new_chat_calls = new_chat_calls + 1 end

    local opened = Api.ask({ new_chat = true, floating = false, ask = true })

    assert.is_false(opened)
    assert.equals(0, new_chat_calls)
    assert.equals(current, Config.ask_opts)
  end)

  it("rechecks generation before submitting a deferred new chat", function()
    local current = Config.ask_opts
    local prompt_opts
    local new_chat_calls = 0
    sidebar.new_chat = function()
      new_chat_calls = new_chat_calls + 1
      return false
    end
    stubs[#stubs + 1] = stub(PromptInput, "new").invokes(function(_, opts)
      prompt_opts = opts
      return { open = function() end }
    end)

    assert.is_true(Api.ask({ new_chat = true, floating = true }))
    sidebar.is_generating = true
    prompt_opts.submit_callback("next question")

    assert.equals(0, new_chat_calls)
    assert.equals(current, Config.ask_opts)
    assert.stub(Avante.open_sidebar).was_not_called()
  end)

  it("does not move an active request to another code buffer", function()
    local other_buf = vim.api.nvim_create_buf(false, true)
    local current = Config.ask_opts
    sidebar.is_generating = true
    vim.api.nvim_set_current_buf(other_buf)

    local opened = Api.ask({ question = "next question", floating = false })

    assert.is_false(opened)
    assert.equals(current, Config.ask_opts)
    assert.stub(Avante.open_sidebar).was_not_called()
    vim.api.nvim_buf_delete(other_buf, { force = true })
  end)

  it("does not refresh an active request onto another code buffer", function()
    local other_buf = vim.api.nvim_create_buf(true, true)
    local closed = 0
    local rendered = 0
    sidebar.is_generating = true
    sidebar.close = function() closed = closed + 1 end
    sidebar.render = function() rendered = rendered + 1 end
    vim.api.nvim_set_current_buf(other_buf)

    local refreshed = Api.refresh()

    assert.is_false(refreshed)
    assert.equals(0, closed)
    assert.equals(0, rendered)
    vim.api.nvim_buf_delete(other_buf, { force = true })
  end)
end)
