local Config = require("avante.config")
local Path = require("avante.path")

describe("History paths", function()
  local storage_path

  before_each(function()
    if not Config.history then Config.setup({}) end
    storage_path = Config.history.storage_path
    Config.history.storage_path = vim.fn.tempname()
  end)

  after_each(function()
    vim.fn.delete(Config.history.storage_path, "rf")
    Config.history.storage_path = storage_path
  end)

  it("saves with a captured project root after the source buffer is wiped", function()
    local project_root = vim.fn.tempname()
    vim.fn.mkdir(project_root, "p")
    local bufnr = vim.api.nvim_create_buf(false, true)
    local history = { filename = "0.json", title = "untitled", messages = {}, entries = {}, todos = {} }
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.has_no.errors(function() Path.history.save(bufnr, history, project_root) end)
    local loaded = Path.history.load(bufnr, history.filename, project_root)
    assert.equals(history.filename, loaded.filename)
    assert.same(history.messages, loaded.messages)

    vim.fn.delete(project_root, "rf")
  end)

  it("does not select an old chat when its delayed save runs after a new chat is selected", function()
    local Sidebar = require("avante.sidebar")
    local project_root = Config.history.storage_path .. "/project"
    vim.fn.mkdir(project_root, "p")
    local bufnr = vim.api.nvim_create_buf(false, true)
    local old = { filename = "old.json", messages = { { message = { role = "user", content = "old chat" } } } }
    local current = { filename = "new.json", messages = {} }
    local sidebar = setmetatable({ code = { bufnr = bufnr }, chat_history = old }, { __index = Sidebar })

    sidebar:save_history(old, bufnr, project_root)
    Path.history.save(bufnr, current, project_root)
    sidebar.chat_history = current
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_true(
      vim.wait(2000, function() return Path.history.get_filepath(bufnr, old.filename, project_root):exists() end, 10)
    )
    assert.same(old.messages, Path.history.load(bufnr, old.filename, project_root).messages)
    assert.same(current.filename, Path.history.get_latest_filename(bufnr, false, project_root))
  end)
end)
