local stub = require("luassert.stub")
local Path = require("avante.path")
local Utils = require("avante.utils")
local AcpSessionSelector = require("avante.acp_session_selector")

describe("acp_session_selector", function()
  describe("format_updated_at", function()
    it("converts UTC timestamps using the offset in effect on that date", function()
      -- 2026-07-01T12:00:00Z and 2026-01-01T12:00:00Z as epoch seconds: the OS works out local time
      assert.equals(
        os.date("%Y-%m-%d %H:%M", 1782907200),
        AcpSessionSelector.format_updated_at("2026-07-01T12:00:00Z")
      )
      assert.equals(
        os.date("%Y-%m-%d %H:%M", 1767268800),
        AcpSessionSelector.format_updated_at("2026-01-01T12:00:00Z")
      )
      assert.equals(
        os.date("%Y-%m-%d %H:%M", 1782907200),
        AcpSessionSelector.format_updated_at("2026-07-01T12:00:00.618Z")
      )
    end)

    it("applies explicit UTC offsets", function()
      assert.equals(1782907200, AcpSessionSelector.parse_timestamp("2026-07-01T12:00:00Z"))
      assert.equals(1782907200, AcpSessionSelector.parse_timestamp("2026-07-01T14:00:00+02:00"))
      assert.equals(1782907200, AcpSessionSelector.parse_timestamp("2026-07-01T07:00:00-0500"))
    end)

    it(
      "keeps a timestamp without a zone as local time",
      function() assert.equals("2026-09-24 23:37", AcpSessionSelector.format_updated_at("2026-09-24T23:37:10")) end
    )

    it("returns malformed input unchanged and nothing for a missing timestamp", function()
      assert.equals("yesterday", AcpSessionSelector.format_updated_at("yesterday"))
      assert.equals("", AcpSessionSelector.format_updated_at(nil))
    end)
  end)

  describe("resume", function()
    local stubs = {}
    local saved
    local sidebar
    local histories

    ---@return table
    local function fake_sidebar(opts)
      local s = {
        current_state = opts.current_state,
        pending_acp_import = opts.pending,
        open = opts.open,
        stopped = 0,
        switched = 0,
        discarded = {},
      }
      function s:discard_acp_import_chat(import) table.insert(self.discarded, import) end
      function s:is_open() return self.open end
      function s:stop_acp_client() self.stopped = self.stopped + 1 end
      function s:switch_to_history_and_reconnect() self.switched = self.switched + 1 end
      return s
    end

    before_each(function()
      saved = nil
      histories = {}
      sidebar = fake_sidebar({ open = true })
      local Avante = require("avante")
      stubs = {
        stub(Avante, "get").invokes(function() return sidebar end),
        stub(Avante, "open_sidebar"),
        stub(Path.history, "list").invokes(function() return histories end),
        stub(Path.history, "get_latest_filename").returns("7.json"),
        stub(Path.history, "new").invokes(
          function() return { title = "untitled", messages = {}, filename = "8.json" } end
        ),
        stub(Path.history, "save").invokes(function(_, history) saved = history end),
        stub(Utils, "warn"),
        stub(vim.api, "nvim_buf_call").invokes(function(_, fn) fn() end),
      }
    end)

    after_each(function()
      for _, s in ipairs(stubs) do
        s:revert()
      end
    end)

    it("creates a chat for a session that isn't linked yet and resumes it in a fresh client", function()
      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p", title = "Fix the build" })

      assert.equals("s1", saved.acp_session_id)
      assert.equals("Fix the build", saved.title)
      assert.equals(1, sidebar.stopped)
      assert.equals("/p", saved.acp_session_cwd)
      assert.same(
        { session_id = "s1", filename = "8.json", created = true, previous_filename = "7.json" },
        sidebar.pending_acp_import
      )
      assert.equals(1, sidebar.switched)
    end)

    it("reuses the chat already linked to the session and keeps its messages until the agent answers", function()
      local linked = { title = "old title", acp_session_id = "s1", messages = { "kept" }, filename = "3.json" }
      histories = { { acp_session_id = "other" }, linked }

      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p", title = "New title" })

      assert.equals(linked, saved)
      assert.equals("New title", saved.title)
      assert.same({ "kept" }, saved.messages)
      assert.same({ session_id = "s1", filename = "3.json", created = false }, sidebar.pending_acp_import)
    end)

    it("replaces the listed root snapshot instead of retaining earlier roots", function()
      local linked = {
        title = "chat",
        acp_session_id = "s1",
        filename = "3.json",
        acp_session_info = {
          sessionId = "s1",
          cwd = "/p",
          additionalDirectories = { "/old" },
        },
      }
      histories = { linked }
      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p", _meta = { count = 1 } })
      assert.is_nil(saved.acp_session_info.additionalDirectories)
      assert.same({}, saved.acp_session_additional_directories)
      assert.same({ count = 1 }, saved.acp_session_info._meta)
    end)

    it("keeps the chat's title when the session has none", function()
      histories = { { title = "my chat", acp_session_id = "s1", messages = {}, filename = "3.json" } }

      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p" })

      assert.equals("my chat", saved.title)
    end)

    it("opens the sidebar when it is closed instead of switching chats", function()
      sidebar = fake_sidebar({ open = false })

      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p" })

      assert.stub(require("avante").open_sidebar).was_called(1)
      assert.equals(0, sidebar.switched)
      assert.is_not_nil(sidebar.pending_acp_import)
    end)

    it("refuses while a request is in progress", function()
      for _, state in ipairs({ "generating", "tool calling", "thinking", "searching", "compacting" }) do
        saved = nil
        sidebar = fake_sidebar({ open = true, current_state = state })

        AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p" })

        assert.is_nil(saved, state)
        assert.equals(0, sidebar.stopped, state)
        assert.is_nil(sidebar.pending_acp_import, state)
      end
      assert.stub(Utils.warn).was_called(5)
    end)

    it("resumes once the sidebar is idle", function()
      for _, state in ipairs({ "initialized", "succeeded", "failed", "cancelled", "compacted" }) do
        sidebar = fake_sidebar({ open = true, current_state = state })
        AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p" })
        assert.equals(1, sidebar.stopped, state)
      end
    end)

    it("discards an earlier import that hasn't finished", function()
      local earlier = { session_id = "s0", filename = "6.json", created = true }
      sidebar = fake_sidebar({ open = true, pending = earlier })

      AcpSessionSelector.resume(1, { sessionId = "s1", cwd = "/p" })

      assert.same({ earlier }, sidebar.discarded)
      assert.equals("s1", sidebar.pending_acp_import.session_id)
    end)
  end)

  describe("open", function()
    local ACPClient = require("avante.libs.acp_client")
    local Config = require("avante.config")
    local Selector = require("avante.ui.selector")
    local stubs, saved_config, selector_opts, fake

    ---@param opts { spawn_error?: string, connect_error?: string, capabilities?: table, sessions?: table[] }
    local function fake_client(opts)
      local client = { stopped = 0, agent_capabilities = opts.capabilities }
      function client:connect(callback)
        if opts.spawn_error then error(opts.spawn_error, 0) end
        callback(opts.connect_error and { message = opts.connect_error } or nil)
      end
      function client:supports_list_sessions()
        return self.agent_capabilities ~= nil and self.agent_capabilities.sessionCapabilities ~= nil
      end
      function client:list_all_sessions(_, callback)
        if opts.on_list then return opts.on_list(callback) end
        callback(opts.sessions or {}, opts.list_error and { message = opts.list_error } or nil)
      end
      function client:stop() self.stopped = self.stopped + 1 end
      return client
    end

    local LISTING = { loadSession = true, sessionCapabilities = { list = vim.empty_dict() } }

    ---@param opts table
    local function open_with(opts, histories)
      fake = fake_client(opts)
      stubs[#stubs + 1] = stub(ACPClient, "new").returns(fake)
      stubs[#stubs + 1] = stub(Path.history, "list").returns(histories or {})
      AcpSessionSelector.open()
    end

    before_each(function()
      selector_opts = nil
      saved_config = { provider = Config.provider, acp_providers = Config.acp_providers, selector = Config.selector }
      Config.provider = "test-acp"
      Config.acp_providers = { ["test-acp"] = { command = "agent", args = {} } }
      Config.selector = { provider = "native", provider_opts = {} }
      stubs = {
        stub(require("avante"), "get").returns(nil),
        stub(Utils.root, "get").returns("/p"),
        stub(vim, "schedule").invokes(function(fn) fn() end),
        stub(Utils, "error"),
        stub(Utils, "warn"),
        stub(Utils, "info"),
        stub(Selector, "new").invokes(function(_, opts)
          selector_opts = opts
          return { open = function() end }
        end),
      }
    end)

    after_each(function()
      for _, s in ipairs(stubs) do
        s:revert()
      end
      Config.provider, Config.acp_providers, Config.selector =
        saved_config.provider, saved_config.acp_providers, saved_config.selector
    end)

    it("reports an agent that can't be started without raising", function()
      open_with({ spawn_error = "/x/acp_client.lua:483: Failed to spawn ACP agent process [agent]" })

      assert
        .stub(Utils.error)
        .was_called_with("Failed to start the ACP agent: Failed to spawn ACP agent process [agent]")
      assert.equals(1, fake.stopped)
      assert.is_nil(selector_opts)
    end)

    it("reports a failed connection", function()
      open_with({ connect_error = "auth required" })

      assert.stub(Utils.error).was_called_with("Failed to start the ACP agent: auth required")
      assert.equals(1, fake.stopped)
    end)

    it("warns when the agent can't list sessions", function()
      open_with({ capabilities = { loadSession = true } })

      assert.stub(Utils.warn).was_called(1)
      assert.is_nil(selector_opts)
      assert.equals(1, fake.stopped)
    end)

    it("allows discovery without load support and checks import capability only on selection", function()
      local resume = stub(AcpSessionSelector, "resume")
      stubs[#stubs + 1] = resume
      for _, capabilities in ipairs({
        { sessionCapabilities = { list = vim.empty_dict() } },
        { sessionCapabilities = { list = vim.empty_dict(), resume = vim.empty_dict() } },
      }) do
        open_with({ capabilities = capabilities, sessions = { { sessionId = "a", cwd = "/p" } } })
        assert.equals(1, #selector_opts.items)
        selector_opts.on_select({ "a" })
      end
      assert.stub(Utils.warn).was_called(2)
      assert.stub(resume).was_not_called()
    end)

    it("says so when there are no sessions", function()
      open_with({ capabilities = LISTING, sessions = {} })

      assert.stub(Utils.info).was_called(1)
      assert.is_nil(selector_opts)
    end)

    it("ignores results after the provider changes", function()
      local respond
      open_with({
        capabilities = LISTING,
        on_list = function(callback) respond = callback end,
      })
      Config.provider = "other"
      respond({ { sessionId = "a", cwd = "/p" } })
      assert.is_nil(selector_opts)
    end)

    it("ignores a selection after the provider changes", function()
      local resume = stub(AcpSessionSelector, "resume")
      stubs[#stubs + 1] = resume
      open_with({ capabilities = LISTING, sessions = { { sessionId = "a", cwd = "/p" } } })
      Config.provider = "other"
      selector_opts.on_select({ "a" })
      assert.stub(resume).was_not_called()
    end)

    it("lists sessions newest first, marks linked ones and stops the temporary client", function()
      open_with({
        capabilities = LISTING,
        sessions = {
          { sessionId = "older-session", cwd = "/p", title = "Older", updatedAt = "2026-09-01T10:00:00" },
          { sessionId = "newer-session", cwd = "/p", title = "Newer", updatedAt = "2026-09-02T10:00:00" },
          { sessionId = "abcdef123456", cwd = "/p" },
        },
      }, { { acp_session_id = "older-session", title = "chat", filename = "1.json" } })

      assert.same(
        { "newer-session", "older-session", "abcdef123456" },
        vim.tbl_map(function(i) return i.id end, selector_opts.items)
      )
      assert.equals("  Newer  2026-09-02 10:00", selector_opts.items[1].title)
      assert.equals("* Older  2026-09-01 10:00", selector_opts.items[2].title)
      assert.equals("  abcdef12", selector_opts.items[3].title)
      assert.equals(1, fake.stopped)

      local preview = selector_opts.get_preview_content("older-session")
      assert.truthy(preview:find("older-session", 1, true))
      assert.truthy(preview:find("1.json", 1, true))
    end)

    it("shows a partial list with a warning when listing stopped early", function()
      open_with({
        capabilities = LISTING,
        sessions = { { sessionId = "a", cwd = "/p", title = "A" } },
        list_error = "Session list incomplete: the agent repeated a cursor",
      })

      assert.stub(Utils.warn).was_called(1)
      assert.equals(1, #selector_opts.items)
    end)

    it("reuses the sidebar's client only when it was started with the same settings", function()
      local function sidebar_with(env)
        local client = fake_client({ capabilities = LISTING, sessions = { { sessionId = "a", cwd = "/p" } } })
        client.config = { command = "agent", args = {}, env = env }
        function client:is_ready() return true end
        return { acp_client = client, code = { bufnr = -1 } }
      end
      require("avante").get:revert()

      stubs[#stubs + 1] = stub(require("avante"), "get").returns(sidebar_with(nil))
      stubs[#stubs + 1] = stub(ACPClient, "new").returns(fake_client({ capabilities = LISTING }))
      stubs[#stubs + 1] = stub(Path.history, "list").returns({})
      AcpSessionSelector.open()
      assert.stub(ACPClient.new).was_not_called()

      require("avante").get:revert()
      stubs[#stubs + 1] = stub(require("avante"), "get").returns(sidebar_with({ ACCOUNT = "other" }))
      AcpSessionSelector.open()
      assert.stub(ACPClient.new).was_called(1)
    end)

    it("does nothing but warn for a provider that isn't an ACP agent", function()
      Config.provider = "claude"
      stubs[#stubs + 1] = stub(ACPClient, "new")

      AcpSessionSelector.open()

      assert.stub(Utils.warn).was_called(1)
      assert.stub(ACPClient.new).was_not_called()
    end)
  end)
end)
