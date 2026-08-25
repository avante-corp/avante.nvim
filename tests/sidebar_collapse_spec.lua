--- Message collapsing.
---
--- Distinct from `expand_tool_use` (<C-e>), which toggles a single tool call.
--- These fold whole messages so a long thread can be skimmed, and so opening
--- an old thread does not dump thousands of lines at you.

local Line = require("avante.ui.line")

--- Sidebar pulls in nui.nvim, which the minimal test runtime lacks; the
--- collapse logic itself has no UI dependency, so exercise it on a bare table
--- with the real methods attached.
local function make_sidebar()
  local Sidebar = require("avante.sidebar")
  local sidebar = {
    collapsed_message_uuids = {},
    chat_history = { messages = {} },
    rendered = 0,
  }
  for _, name in ipairs({
    "_collapse_lines",
    "_collapsible_messages",
    "collapse_all_messages",
    "expand_all_messages",
  }) do
    sidebar[name] = Sidebar[name]
  end
  sidebar._rerender_after_collapse = function(self) self.rendered = self.rendered + 1 end
  return sidebar
end

local function lines(...)
  local result = {}
  for _, text in ipairs({ ... }) do
    table.insert(result, Line:new({ { text } }))
  end
  return result
end

local function texts(rendered)
  return vim.tbl_map(function(line) return tostring(line) end, rendered)
end

describe("sidebar message collapsing", function()
  local has_sidebar = pcall(require, "avante.sidebar")
  if not has_sidebar then
    pending("nui.nvim not available in the test runtime")
    return
  end

  describe("_collapse_lines", function()
    it("leaves an uncollapsed message untouched", function()
      local sidebar = make_sidebar()
      local input = lines("first", "second", "third")

      assert.equals(3, #sidebar:_collapse_lines({ uuid = "a" }, input))
    end)

    it("keeps only the first line plus a count", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      local result = texts(sidebar:_collapse_lines({ uuid = "a" }, lines("first", "second", "third")))

      assert.equals(2, #result)
      assert.equals("first", result[1])
      assert.is_not_nil(result[2]:find("2 more lines", 1, true))
    end)

    it("skips leading blank lines when choosing the first line", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      local result = texts(sidebar:_collapse_lines({ uuid = "a" }, lines("", "  ", "real content", "more")))

      assert.equals("real content", result[1])
    end)

    it("uses the singular for a single hidden line", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      local result = texts(sidebar:_collapse_lines({ uuid = "a" }, lines("first", "second")))

      assert.is_not_nil(result[2]:find("1 more line", 1, true))
      assert.is_nil(result[2]:find("more lines", 1, true))
    end)

    it("adds no indicator when nothing is hidden", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      local result = sidebar:_collapse_lines({ uuid = "a" }, lines("only"))

      assert.equals(1, #result)
    end)

    it("handles an empty message", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      assert.same({}, sidebar:_collapse_lines({ uuid = "a" }, {}))
    end)

    it("ignores messages with no uuid", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids["a"] = true

      assert.equals(3, #sidebar:_collapse_lines({}, lines("a", "b", "c")))
    end)
  end)

  describe("collapse_all_messages", function()
    local function with_messages(n)
      local sidebar = make_sidebar()
      local messages = {}
      for i = 1, n do
        table.insert(messages, { uuid = "m" .. i })
      end
      sidebar.chat_history = { messages = messages }
      return sidebar
    end

    it("collapses every message", function()
      local sidebar = with_messages(3)

      sidebar:collapse_all_messages({ silent = true })

      assert.is_true(sidebar.collapsed_message_uuids["m1"])
      assert.is_true(sidebar.collapsed_message_uuids["m3"])
    end)

    it("keeps the most recent expanded when asked", function()
      -- This is what opening a thread does: read the latest turn, skim the rest.
      local sidebar = with_messages(3)

      sidebar:collapse_all_messages({ keep_last = true, silent = true })

      assert.is_true(sidebar.collapsed_message_uuids["m1"])
      assert.is_true(sidebar.collapsed_message_uuids["m2"])
      assert.is_nil(sidebar.collapsed_message_uuids["m3"])
    end)

    it("skips invisible messages", function()
      local sidebar = make_sidebar()
      sidebar.chat_history = {
        messages = { { uuid = "m1" }, { uuid = "m2", visible = false }, { uuid = "m3" } },
      }

      sidebar:collapse_all_messages({ keep_last = true, silent = true })

      assert.is_nil(sidebar.collapsed_message_uuids["m2"])
      -- m3 is the last *visible* message, so it stays expanded.
      assert.is_nil(sidebar.collapsed_message_uuids["m3"])
      assert.is_true(sidebar.collapsed_message_uuids["m1"])
    end)

    it("does nothing on an empty thread", function()
      local sidebar = make_sidebar()

      sidebar:collapse_all_messages({ silent = true })

      assert.same({}, sidebar.collapsed_message_uuids)
      assert.equals(0, sidebar.rendered)
    end)

    it("renders once by default", function()
      local sidebar = with_messages(2)

      sidebar:collapse_all_messages({ silent = true })

      assert.equals(1, sidebar.rendered)
    end)

    it("skips rendering when deferred", function()
      -- Opening a thread redraws anyway; rendering here would do it twice.
      local sidebar = with_messages(2)

      sidebar:collapse_all_messages({ silent = true, defer_render = true })

      assert.equals(0, sidebar.rendered)
      assert.is_true(sidebar.collapsed_message_uuids["m1"])
    end)

    it("replaces any previous collapse state", function()
      local sidebar = with_messages(2)
      sidebar.collapsed_message_uuids["stale"] = true

      sidebar:collapse_all_messages({ silent = true })

      assert.is_nil(sidebar.collapsed_message_uuids["stale"])
    end)
  end)

  describe("expand_all_messages", function()
    it("clears collapse state and rerenders", function()
      local sidebar = make_sidebar()
      sidebar.collapsed_message_uuids = { m1 = true }

      sidebar:expand_all_messages()

      assert.same({}, sidebar.collapsed_message_uuids)
      assert.equals(1, sidebar.rendered)
    end)

    it("does not rerender when nothing is collapsed", function()
      local sidebar = make_sidebar()

      sidebar:expand_all_messages()

      assert.equals(0, sidebar.rendered)
    end)
  end)
end)

describe("sidebar notification session id", function()
  local has_sidebar = pcall(require, "avante.sidebar")
  if not has_sidebar then
    pending("nui.nvim not available in the test runtime")
    return
  end

  local Sidebar = require("avante.sidebar")

  local function make(fields)
    local sidebar = vim.tbl_extend("force", { id = 7 }, fields or {})
    sidebar.notification_session_id = Sidebar.notification_session_id
    return sidebar
  end

  it("uses the ACP session id when present", function()
    local sidebar = make({ chat_history = { acp_session_id = "sess-abc" } })

    assert.equals("sess-abc", sidebar:notification_session_id())
  end)

  it("falls back for a thread with no ACP session", function()
    -- Regression: this reached for a nonexistent Sidebar.bufnr field and raised
    -- inside a vim.schedule callback, abandoning the rest of the UI update.
    local sidebar = make({ chat_history = { acp_session_id = nil }, code = { bufnr = 42 } })

    assert.equals("internal_42", sidebar:notification_session_id())
  end)

  it("survives a nil chat_history", function()
    local sidebar = make({ code = { bufnr = 42 } })

    assert.equals("internal_42", sidebar:notification_session_id())
  end)

  it("survives a nil code state", function()
    local sidebar = make({ chat_history = {} })

    assert.equals("internal_7", sidebar:notification_session_id())
  end)

  it("treats an empty session id as absent", function()
    local sidebar = make({ chat_history = { acp_session_id = "" }, code = { bufnr = 42 } })

    assert.equals("internal_42", sidebar:notification_session_id())
  end)

  it("never returns nil", function()
    assert.is_string(make():notification_session_id())
  end)
end)
