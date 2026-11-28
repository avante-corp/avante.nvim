local stub = require("luassert.stub")
local Llm = require("avante.llm")
local Range = require("avante.range")
local Selection = require("avante.selection")
local SelectionResult = require("avante.selection_result")
local Utils = require("avante.utils")

describe("Selection:submit_input", function()
  local bufnr, stream_stub, warn_stub, stream_opts

  before_each(function()
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def f():", "    a = 1", "    b = 2", "    return a + b" })
    stream_stub = stub(Llm, "stream").invokes(function(opts) stream_opts = opts end)
    warn_stub = stub(Utils, "warn")
  end)

  after_each(function()
    stream_stub:revert()
    warn_stub:revert()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  local function submit()
    local selection = Selection:new(vim.api.nvim_get_current_tabpage())
    selection.code_bufnr = bufnr
    selection.selection = SelectionResult:new(
      "/tmp/f.py",
      "python",
      "    a = 1\n    b = 2",
      Range:new({ lnum = 2, col = 9 }, { lnum = 3, col = 9 })
    )
    selection:submit_input("rename a, b to x, y")
  end

  local function lines() return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

  it("keeps the selection when the reply has no code block", function()
    submit()
    stream_opts.on_chunk("I can't see any code.")
    stream_opts.on_stop({ reason = "complete" })

    assert.same({ "def f():", "    a = 1", "    b = 2", "    return a + b" }, lines())
    assert.stub(warn_stub).was_called(1)
  end)

  it("replaces the selection with a code block streamed across chunks", function()
    submit()
    stream_opts.on_chunk("Sure.\n")
    assert.same({ "def f():", "    a = 1", "    b = 2", "    return a + b" }, lines())
    for _, chunk in ipairs({ "<code>\n    x = 1\n", "    y = 2\n", "</code>" }) do
      stream_opts.on_chunk(chunk)
    end
    stream_opts.on_stop({ reason = "complete" })

    assert.same({ "def f():", "    x = 1", "    y = 2", "    return a + b" }, lines())
    assert.stub(warn_stub).was_not_called()
  end)
end)
