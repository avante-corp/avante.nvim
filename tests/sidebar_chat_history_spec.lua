local stub = require("luassert.stub")
local Config = require("avante.config")
local HistoryStorage = require("avante.history.storage")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("Sidebar chat history", function()
  local stubs, project, latest, loaded

  local function fake_sidebar(chat_history, chat_history_project_root)
    return setmetatable({
      code = { bufnr = vim.api.nvim_get_current_buf() },
      chat_history = chat_history,
      chat_history_project_root = chat_history_project_root,
    }, { __index = Sidebar })
  end

  before_each(function()
    if not Config.windows then Config.setup({}) end
    project, latest, loaded = "/project-a", "latest.json", {}
    stubs = {
      stub(Utils.root, "get").invokes(function() return project end),
      stub(HistoryStorage, "get_latest_filename").invokes(function() return latest end),
      stub(HistoryStorage, "load").invokes(function(_, filename)
        table.insert(loaded, filename or "<latest>")
        return { filename = filename or latest, messages = {} }
      end),
    }
  end)

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
  end)

  it("keeps the chat it shows when another instance saves a different latest chat", function()
    local sidebar = fake_sidebar({ filename = "mine.json" }, project)
    latest = "theirs.json"

    sidebar:reload_chat_history()

    assert.same({ "mine.json" }, loaded)
    assert.equals("mine.json", sidebar.chat_history.filename)
  end)

  it("loads the chat it is asked to switch to", function()
    local sidebar = fake_sidebar({ filename = "mine.json" }, project)

    sidebar:reload_chat_history("other.json")

    assert.same({ "other.json" }, loaded)
  end)

  it("falls back to the latest chat when the buffer belongs to another project", function()
    local sidebar = fake_sidebar({ filename = "mine.json" }, project)
    project = "/project-b"

    sidebar:reload_chat_history()

    assert.same({ "<latest>" }, loaded)
    assert.equals("/project-b", sidebar.chat_history_project_root)
  end)

  it("falls back to the latest chat before any chat is loaded", function()
    local sidebar = fake_sidebar(nil, nil)

    sidebar:reload_chat_history()

    assert.same({ "<latest>" }, loaded)
  end)
end)
