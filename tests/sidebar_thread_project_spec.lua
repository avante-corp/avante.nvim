--- Which project a thread belongs to.
---
--- Threads are stored per project, and the project is derived from the sidebar's
--- code buffer — the cwd, when `use_cwd_as_project_root` is set. Following an
--- agent edit into ~/.avante/plans, or any `:cd`, therefore used to make an
--- incidental reload swap the live conversation for another project's latest
--- thread, or invent an empty one. The sidebar kept rendering the old messages,
--- so the next prompt silently landed in a stray untitled thread with no ACP
--- session ("No ACP session ID").

local Config = require("avante.config")
local Path = require("avante.path")
local Utils = require("avante.utils")

--- Sidebar pulls in nui.nvim, which the minimal test runtime lacks. The reload
--- guard has no UI dependency, so attach the real methods to a bare table.
---@param chat_history table|nil
local function make_sidebar(chat_history)
  local Sidebar = require("avante.sidebar")
  local sidebar = {
    chat_history = chat_history,
    code = { bufnr = vim.api.nvim_create_buf(false, true) },
  }
  for _, name in ipairs({ "reload_chat_history", "has_live_thread" }) do
    sidebar[name] = Sidebar[name]
  end
  return sidebar
end

--- A live thread, as the sidebar holds it mid-conversation.
---@param fields? table
local function live_thread(fields)
  return vim.tbl_extend("force", {
    project_root = "/projects/app",
    filename = "7.json",
    acp_session_id = "sess-1",
    messages = {},
  }, fields or {})
end

describe("sidebar thread project binding", function()
  local has_sidebar = pcall(require, "avante.sidebar")
  if not has_sidebar then
    pending("nui.nvim not available in the test runtime")
    return
  end

  local original_get, original_load
  local loaded_from

  before_each(function()
    original_get = Utils.root.get
    original_load = Path.history.load
    loaded_from = nil
    -- The buffer resolves to a different project than the live thread's, as it
    -- does once the agent's plan file is opened.
    Utils.root.get = function() return "/projects/plans" end
    Path.history.load = function()
      loaded_from = "/projects/plans"
      return { title = "untitled", messages = {}, project_root = "/projects/plans" }
    end
  end)

  after_each(function()
    Utils.root.get = original_get
    Path.history.load = original_load
  end)

  it("keeps a thread with a live ACP session", function()
    local sidebar = make_sidebar({ project_root = "/projects/app", acp_session_id = "sess-1", messages = {} })

    sidebar:reload_chat_history()

    assert.equals("sess-1", sidebar.chat_history.acp_session_id)
    assert.is_nil(loaded_from)
  end)

  it("keeps a thread that has messages but no session yet", function()
    local sidebar = make_sidebar({
      project_root = "/projects/app",
      messages = { { message = { role = "user", content = "hi" } } },
    })

    sidebar:reload_chat_history()

    assert.equals("/projects/app", sidebar.chat_history.project_root)
    assert.is_nil(loaded_from)
  end)

  it("reloads an empty thread, which has no conversation to lose", function()
    local sidebar = make_sidebar({ project_root = "/projects/app", messages = {} })

    sidebar:reload_chat_history()

    assert.equals("/projects/plans", loaded_from)
  end)

  it("reloads when the buffer resolves to the thread's own project", function()
    local sidebar = make_sidebar({ project_root = "/projects/plans", acp_session_id = "sess-1", messages = {} })

    sidebar:reload_chat_history()

    assert.equals("/projects/plans", loaded_from)
  end)

  it("reloads a live thread when the user asked to switch", function()
    -- Opening the sidebar or picking a thread is an explicit request for
    -- another project, unlike a render or a buffer change.
    local sidebar = make_sidebar({ project_root = "/projects/app", acp_session_id = "sess-1", messages = {} })

    sidebar:reload_chat_history({ force = true })

    assert.equals("/projects/plans", loaded_from)
  end)

  it("reloads threads saved before the project was recorded", function()
    local sidebar = make_sidebar({ acp_session_id = "sess-1", messages = {} })

    sidebar:reload_chat_history()

    assert.equals("/projects/plans", loaded_from)
  end)
end)

describe("sidebar thread reload target", function()
  local has_sidebar = pcall(require, "avante.sidebar")
  if not has_sidebar then
    pending("nui.nvim not available in the test runtime")
    return
  end

  local original_get, original_load
  local requested

  before_each(function()
    original_get = Utils.root.get
    original_load = Path.history.load
    requested = "unset"
    Utils.root.get = function() return "/projects/app" end
    Path.history.load = function(_, filename)
      requested = filename
      return { title = "untitled", messages = {}, filename = filename or "latest.json" }
    end
  end)

  after_each(function()
    Utils.root.get = original_get
    Path.history.load = original_load
  end)

  it("re-reads the sidebar's own thread by name", function()
    -- `latest_filename` lives in a metadata file shared by every Neovim in the
    -- project, so asking for "the latest" let another session's thread take
    -- over this one.
    local sidebar = make_sidebar(live_thread())

    sidebar:reload_chat_history()

    assert.equals("7.json", requested)
  end)

  it("asks for the project's latest when it holds no conversation", function()
    local sidebar = make_sidebar({ project_root = "/projects/app", filename = "7.json", messages = {} })

    sidebar:reload_chat_history()

    assert.is_nil(requested)
  end)

  it("switches to a named thread", function()
    local sidebar = make_sidebar(live_thread())

    sidebar:reload_chat_history({ force = true, filename = "9.json" })

    assert.equals("9.json", requested)
  end)
end)

describe("history storage location", function()
  local storage, original_storage, original_get

  before_each(function()
    Config.setup({})
    original_storage = Config.history.storage_path
    original_get = Utils.root.get
    storage = vim.fn.tempname()
    Config.history.storage_path = storage
  end)

  after_each(function()
    Config.history.storage_path = original_storage
    Utils.root.get = original_get
    vim.fn.delete(storage, "rf")
  end)

  it("saves a thread under its own project, not the buffer's", function()
    -- A `:cd` mid-conversation moves the buffer's project root. Saving by root
    -- would file the same thread under a second project, so the thread carries
    -- the project it was created in.
    Utils.root.get = function() return "/projects/app" end
    local history = Path.history.new(0)
    assert.equals("/projects/app", history.project_root)

    Utils.root.get = function() return "/projects/plans" end
    Path.history.save(0, history)

    local app_dir = storage .. "/projects/__projects__app/history/" .. history.filename
    assert.equals(1, vim.fn.filereadable(app_dir))
    assert.equals(0, vim.fn.filereadable(storage .. "/projects/__projects__plans/history/" .. history.filename))
  end)

  it("records the project on threads written before the field existed", function()
    Utils.root.get = function() return "/projects/app" end
    local history = Path.history.new(0)
    history.project_root = nil
    Path.history.save(0, history)

    local loaded = Path.history.load(0, history.filename)

    assert.equals("/projects/app", loaded.project_root)
  end)
end)

describe("thread numbering", function()
  local storage, original_storage, original_get

  before_each(function()
    Config.setup({})
    original_storage = Config.history.storage_path
    original_get = Utils.root.get
    storage = vim.fn.tempname()
    Config.history.storage_path = storage
    Utils.root.get = function() return "/projects/app" end
  end)

  after_each(function()
    Config.history.storage_path = original_storage
    Utils.root.get = original_get
    vim.fn.delete(storage, "rf")
  end)

  it("gives each new thread its own file", function()
    -- Threads used to exist only in memory until their first message, so two
    -- Neovim sessions in one project picked the same number and wrote the same
    -- thread. Each creation claims its file immediately.
    local first = Path.history.new(0)
    local second = Path.history.new(0)

    assert.are_not.equals(first.filename, second.filename)
    assert.equals(1, vim.fn.filereadable(storage .. "/projects/__projects__app/history/" .. first.filename))
  end)

  it("numbers past the highest thread rather than counting them", function()
    -- A deleted thread left a hole in the numbering, and the count then pointed
    -- back at a thread that already existed.
    local first = Path.history.new(0)
    local second = Path.history.new(0)
    local third = Path.history.new(0)
    Path.history.delete(0, second.filename)

    local fourth = Path.history.new(0)

    assert.are_not.same({ first.filename, second.filename, third.filename }, { fourth.filename })
    assert.is_nil(
      vim.iter({ first.filename, third.filename }):find(function(name) return name == fourth.filename end)
    )
  end)
end)
