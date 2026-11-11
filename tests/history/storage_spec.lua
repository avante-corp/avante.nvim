local Config = require("avante.config")
local HistoryStorage = require("avante.history.storage")

describe("History storage", function()
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

    assert.has_no.errors(function() HistoryStorage.save(bufnr, history, project_root) end)
    local loaded = HistoryStorage.load(bufnr, history.filename, project_root)
    assert.equals(history.filename, loaded.filename)
    assert.same(history.messages, loaded.messages)

    vim.fn.delete(project_root, "rf")
  end)

  it("saves and clears ACP session metadata with a captured project root", function()
    local provider, acp_providers = Config.provider, Config.acp_providers
    local project_root = Config.history.storage_path .. "/acp-project"
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = {} }

    local ok, err = pcall(function()
      local history = HistoryStorage.new(0, project_root)
      history.acp_session_id = "session-1"
      HistoryStorage.save(0, history, project_root)

      assert.same({
        acp_provider = "test-acp",
        acp_session_id = "session-1",
        acp_session_cwd = project_root,
      }, vim.json.decode(HistoryStorage.get_filepath(0, history.filename, project_root):read()))
      assert.equals("session-1", HistoryStorage.load(0, history.filename, project_root).acp_session_id)

      local histories = HistoryStorage.list(0, project_root)
      assert.equals(1, #histories)
      assert.equals(history.filename, histories[1].filename)
      assert.equals("session-1", histories[1].acp_session_id)

      local current = HistoryStorage.new(0, project_root)
      current.acp_session_id = "current-session"
      HistoryStorage.save(0, current, project_root)

      current.acp_session_id = nil
      HistoryStorage.save(0, current, project_root)

      local metadata = vim.json.decode(HistoryStorage.get_metadata_filepath(0, project_root):read())
      assert.is_nil(metadata.latest_filename)
    end)

    Config.provider, Config.acp_providers = provider, acp_providers
    assert.is_true(ok, err)
  end)

  it("restores the metadata target without mixing it into the ACP history list", function()
    local provider, acp_providers = Config.provider, Config.acp_providers
    local project_root = Config.history.storage_path .. "/regular-project"
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = {} }

    local ok, err = pcall(function()
      local history = {
        filename = "0.json",
        title = "regular history",
        timestamp = "2026-11-09 00:00:00",
        messages = { { message = { role = "user", content = "restore me" } } },
        entries = {},
        todos = {},
      }
      HistoryStorage.save(0, history, project_root)

      assert.same({}, HistoryStorage.list(0, project_root))
      assert.same(history.messages, HistoryStorage.load(0, nil, project_root).messages)
    end)

    Config.provider, Config.acp_providers = provider, acp_providers
    assert.is_true(ok, err)
  end)

  it("does not restore an old history when metadata has no latest filename", function()
    local project_root = Config.history.storage_path .. "/unselected-project"
    HistoryStorage.write(0, {
      filename = "0.json",
      title = "old history",
      messages = { { message = { role = "user", content = "do not restore" } } },
      entries = {},
      todos = {},
    }, project_root)
    HistoryStorage.write(0, {
      filename = "1.json",
      title = "newer old history",
      messages = { { message = { role = "user", content = "do not restore either" } } },
      entries = {},
      todos = {},
    }, project_root)

    assert.is_nil(HistoryStorage.get_latest_filename(0, false, project_root))
    local restored = HistoryStorage.load(0, nil, project_root)
    assert.same({}, restored.messages)
    assert.equals("2.json", restored.filename)
  end)

  it("does not restore an ACP session through a different provider", function()
    local provider, acp_providers = Config.provider, Config.acp_providers
    local project_root = Config.history.storage_path .. "/removed-acp-project"
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = {} }

    local ok, err = pcall(function()
      HistoryStorage.save(0, {
        filename = "0.json",
        acp_provider = "removed-acp",
        acp_session_id = "foreign-session",
        messages = {},
      }, project_root)

      local restored = HistoryStorage.load(0, nil, project_root)
      assert.equals("test-acp", restored.acp_provider)
      assert.is_nil(restored.acp_session_id)
    end)

    Config.provider, Config.acp_providers = provider, acp_providers
    assert.is_true(ok, err)
  end)

  it("reuses prompt snapshots across turns and preserves changed rules after saving", function()
    local History = require("avante.history")
    local root = Config.history.storage_path .. "/project"
    local history = HistoryStorage.new(0, root)
    local snapshot = { system_prompt = "Final system instructions", instructions = "Project rules" }
    local first = { turn_id = "turn-1", model = "model-1", reasoning_effort = "high", project_root = root }
    local second = { turn_id = "turn-2", model = "model-2", reasoning_effort = "low", project_root = root }

    History.record_turn(history, first, snapshot)
    History.record_turn(history, second, vim.deepcopy(snapshot))
    assert.equals(first.prompt_snapshot_id, second.prompt_snapshot_id)

    local changed = { system_prompt = snapshot.system_prompt, instructions = "Changed project rules" }
    History.record_turn(history, { turn_id = "turn-3" }, changed)
    HistoryStorage.save(0, history, root)
    local loaded = HistoryStorage.load(0, history.filename, root)

    assert.same(history.turn_contexts, loaded.turn_contexts)
    assert.equals(2, vim.tbl_count(loaded.prompt_snapshots))
    assert.same(snapshot, loaded.prompt_snapshots[loaded.turn_contexts[1].prompt_snapshot_id])
    assert.same(changed, loaded.prompt_snapshots[loaded.turn_contexts[3].prompt_snapshot_id])
    assert.is_string(loaded.turn_contexts[1].timestamp)
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
    HistoryStorage.save(bufnr, current, project_root)
    sidebar.chat_history = current
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_true(
      vim.wait(2000, function() return HistoryStorage.get_filepath(bufnr, old.filename, project_root):exists() end, 10)
    )
    assert.same(old.messages, HistoryStorage.load(bufnr, old.filename, project_root).messages)
    assert.same(current.filename, HistoryStorage.get_latest_filename(bufnr, false, project_root))
  end)
end)
