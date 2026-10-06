local stub = require("luassert.stub")
local Path = require("avante.path")
local Utils = require("avante.utils")
local Sidebar = require("avante.sidebar")

describe("Sidebar ACP import", function()
  local stubs, saved, deleted, latest, stored

  ---@return table
  local function fake_sidebar(opts)
    local s = setmetatable({
      code = { bufnr = 1 },
      open = opts.open ~= false,
      acp_client = opts.client,
      acp_client_generation = 0,
      chat_history = opts.chat_history,
      pending_acp_import = opts.import,
      rendered = 0,
      reconnected = 0,
    }, { __index = Sidebar })
    function s:is_open() return self.open end
    function s:update_content_with_history() self.rendered = self.rendered + 1 end
    function s:create_todos_container() end
    function s:initialize_token_count() end
    function s:switch_to_history_and_reconnect() self.reconnected = self.reconnected + 1 end
    return s
  end

  before_each(function()
    saved, deleted, latest = nil, {}, nil
    -- Chats on disk, by filename, for discard_acp_import_chat to check
    stored = {}
    stubs = {
      stub(Path.history, "save").invokes(function(_, history) saved = history end),
      stub(Path.history, "delete").invokes(function(_, filename) table.insert(deleted, filename) end),
      stub(Path.history, "save_latest_filename").invokes(function(_, filename) latest = filename end),
      stub(Path.history, "load").invokes(function(_, filename) return stored[filename] end),
      stub(Utils, "error"),
      stub(Utils, "warn"),
    }
  end)

  after_each(function()
    for _, s in ipairs(stubs) do
      s:revert()
    end
  end)

  describe("stop_acp_client", function()
    it("stops the client and invalidates connections still in flight", function()
      local client = { stop = stub() }
      local sidebar = fake_sidebar({ client = client })

      sidebar:stop_acp_client()

      assert.stub(client.stop).was_called(1)
      assert.is_nil(sidebar.acp_client)
      assert.equals(1, sidebar.acp_client_generation)
    end)

    it("still bumps the generation when there is no client", function()
      local sidebar = fake_sidebar({})
      sidebar:stop_acp_client()
      assert.equals(1, sidebar.acp_client_generation)
    end)
  end)

  describe("session metadata", function()
    it("preserves omitted fields, clears nulls, and replaces metadata without merging", function()
      local chat = {
        acp_session_id = "s1",
        acp_session_cwd = "/p",
        acp_session_additional_directories = { "/extra" },
        title = "old",
        acp_session_info = {
          sessionId = "s1",
          cwd = "/p",
          title = "old",
          updatedAt = "2026-01-01T00:00:00Z",
          additionalDirectories = { "/extra" },
          _meta = { old = true },
        },
      }
      local sidebar = fake_sidebar({ chat_history = chat })
      sidebar:update_acp_session_info(
        chat,
        "s1",
        { sessionUpdate = "session_info_update", title = "new", _meta = { new = true } }
      )
      assert.equals("new", chat.title)
      assert.equals("2026-01-01T00:00:00Z", chat.acp_session_info.updatedAt)
      assert.same({ new = true }, chat.acp_session_info._meta)
      sidebar:update_acp_session_info(
        chat,
        "s1",
        { sessionUpdate = "session_info_update", title = vim.NIL, updatedAt = vim.NIL, _meta = vim.NIL }
      )
      assert.equals("untitled", chat.title)
      assert.is_nil(chat.acp_session_info.title)
      assert.is_nil(chat.acp_session_info.updatedAt)
      assert.same({ new = true }, chat.acp_session_info._meta)
      assert.same({ "/extra" }, chat.acp_session_info.additionalDirectories)
      assert.same({ "/extra" }, chat.acp_session_additional_directories)
      assert.equals(chat, saved)
    end)

    it("ignores patches belonging to another session", function()
      local chat = { acp_session_id = "s1", title = "kept" }
      local sidebar = fake_sidebar({ chat_history = chat })
      sidebar:update_acp_session_info(chat, "s2", { sessionUpdate = "session_info_update", title = "other" })
      assert.equals("kept", chat.title)
      assert.is_nil(saved)
    end)
  end)

  describe("finish_acp_import", function()
    it("replaces the chat with the replayed conversation", function()
      local import = { session_id = "s1", filename = "3.json", created = false }
      local chat = {
        acp_session_id = "s1",
        filename = "3.json",
        messages = { "stale" },
        entries = { "legacy" },
        todos = { "t" },
        memory = { content = "summary of the stale messages" },
        tokens_usage = {},
      }
      local sidebar = fake_sidebar({ chat_history = chat, import = import })

      sidebar:finish_acp_import(import, "s1", { "fresh" })

      assert.same({ "fresh" }, chat.messages)
      assert.same({}, chat.entries)
      assert.same({}, chat.todos)
      assert.is_nil(chat.memory)
      assert.is_nil(chat.tokens_usage)
      assert.equals(chat, saved)
      assert.is_nil(sidebar.pending_acp_import)
      assert.equals(1, sidebar.rendered)
    end)

    it("keeps an existing chat when the agent replays nothing", function()
      local import = { session_id = "s1", filename = "3.json", created = false }
      local chat = { acp_session_id = "s1", filename = "3.json", messages = { "kept" } }
      local sidebar = fake_sidebar({ chat_history = chat, import = import })

      sidebar:finish_acp_import(import, "s1", {})

      assert.same({ "kept" }, chat.messages)
      assert.is_nil(saved)
      assert.stub(Utils.warn).was_called(1)
    end)

    it("ignores an import that is no longer the pending one", function()
      local chat = { acp_session_id = "s1", filename = "3.json", messages = { "kept" } }
      local sidebar =
        fake_sidebar({ chat_history = chat, import = { session_id = "s2", filename = "4.json", created = false } })

      sidebar:finish_acp_import({ session_id = "s1", filename = "3.json", created = false }, "s1", { "fresh" })

      assert.same({ "kept" }, chat.messages)
      assert.is_nil(saved)
    end)

    it("drops the client and the empty chat it created when another chat was opened meanwhile", function()
      local client = { stop = stub() }
      local import = { session_id = "s1", filename = "5.json", created = true }
      stored["5.json"] = { messages = {} }
      local other_chat = { acp_session_id = "other", filename = "2.json", messages = { "kept" } }
      local sidebar = fake_sidebar({ chat_history = other_chat, import = import, client = client })

      sidebar:finish_acp_import(import, "s1", { "fresh" })

      assert.same({ "kept" }, other_chat.messages)
      assert.stub(client.stop).was_called(1)
      assert.same({ "5.json" }, deleted)
      assert.is_nil(saved)
    end)

    it("saves without rendering when the sidebar was closed meanwhile", function()
      local import = { session_id = "s1", filename = "3.json", created = false }
      local chat = { acp_session_id = "s1", filename = "3.json", messages = {} }
      local sidebar = fake_sidebar({ chat_history = chat, import = import, open = false })

      sidebar:finish_acp_import(import, "s1", { "fresh" })

      assert.equals(chat, saved)
      assert.equals(0, sidebar.rendered)
    end)
  end)

  describe("fail_acp_import", function()
    it("removes a chat created for the import and goes back to the previous one", function()
      local import = { session_id = "s1", filename = "5.json", created = true, previous_filename = "2.json" }
      stored["5.json"] = { messages = {} }
      local client = { stop = stub() }
      local chat = { acp_session_id = "s1", messages = {}, filename = "5.json" }
      local sidebar = fake_sidebar({ chat_history = chat, import = import, client = client })

      sidebar:fail_acp_import(import, { message = "Session not found" })

      assert.stub(Utils.error).was_called(1)
      assert.stub(client.stop).was_called(1)
      assert.same({ "5.json" }, deleted)
      assert.equals("2.json", latest)
      assert.equals(1, sidebar.reconnected)
      assert.is_nil(sidebar.pending_acp_import)
    end)

    it("keeps an existing chat and its messages", function()
      local import = { session_id = "s1", filename = "3.json", created = false }
      local chat = { acp_session_id = "s1", messages = { "kept" }, filename = "3.json" }
      local sidebar = fake_sidebar({ chat_history = chat, import = import })

      sidebar:fail_acp_import(import, { message = "Session not found" })

      assert.stub(Utils.error).was_called(1)
      assert.same({}, deleted)
      assert.same({ "kept" }, chat.messages)
      assert.equals(0, sidebar.reconnected)
    end)

    it("removes the created chat without switching when another chat is showing", function()
      local import = { session_id = "s1", filename = "5.json", created = true, previous_filename = "2.json" }
      stored["5.json"] = { messages = {} }
      local sidebar = fake_sidebar({
        chat_history = { acp_session_id = "other", filename = "2.json", messages = {} },
        import = import,
      })

      sidebar:fail_acp_import(import, { message = "Session not found" })

      assert.same({ "5.json" }, deleted)
      assert.is_nil(latest)
      assert.equals(0, sidebar.reconnected)
    end)

    it("ignores an import that is no longer the pending one", function()
      local sidebar =
        fake_sidebar({ chat_history = {}, import = { session_id = "s2", filename = "6.json", created = true } })

      sidebar:fail_acp_import({ session_id = "s1", filename = "5.json", created = true }, { message = "x" })

      assert.stub(Utils.error).was_not_called()
      assert.same({}, deleted)
    end)
  end)

  describe("discard_acp_import_chat", function()
    it("keeps a created chat that already has messages", function()
      stored["5.json"] = { messages = { "something the user added" } }
      local sidebar = fake_sidebar({})

      sidebar:discard_acp_import_chat({ session_id = "s1", filename = "5.json", created = true })

      assert.same({}, deleted)
    end)

    it("never deletes a chat the import didn't create", function()
      stored["3.json"] = { messages = {} }
      local sidebar = fake_sidebar({})

      sidebar:discard_acp_import_chat({ session_id = "s1", filename = "3.json", created = false })

      assert.same({}, deleted)
    end)
  end)
end)
