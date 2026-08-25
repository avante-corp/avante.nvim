--- Which agent a chat is talking to, and whether it is up yet.
---
--- A thread may pin its own ACP provider, independently of the global
--- `Config.provider`. Two things used to ignore that: the transcript header,
--- which recorded the global provider and so claimed every chat ran on the
--- default agent, and the prompt path, which had no notion of "still
--- connecting" and reported "ACP client not connected" instead.

local Config = require("avante.config")

--- Sidebar pulls in nui.nvim, which the minimal test runtime lacks. These
--- methods have no UI dependency, so attach the real ones to a bare table.
local function make_sidebar(fields)
  local Sidebar = require("avante.sidebar")
  local sidebar = vim.tbl_extend("force", {
    chat_history = nil,
    current_acp_provider = nil,
    acp_client = nil,
    _acp_connecting = nil,
  }, fields or {})
  for _, name in ipairs({ "acp_provider_name", "acp_connect_pending" }) do
    sidebar[name] = Sidebar[name]
  end
  return sidebar
end

describe("sidebar acp provider", function()
  local has_sidebar = pcall(require, "avante.sidebar")
  if not has_sidebar then
    pending("nui.nvim not available in the test runtime")
    return
  end

  describe("acp_provider_name", function()
    local original_provider

    before_each(function()
      original_provider = Config.provider
      Config.provider = "claude-code"
    end)

    after_each(function() Config.provider = original_provider end)

    it("falls back to the global provider when the thread pins nothing", function()
      assert.equals("claude-code", make_sidebar():acp_provider_name())
    end)

    it("prefers the provider pinned on the thread", function()
      local sidebar = make_sidebar({ chat_history = { acp_provider = "cursor" } })

      assert.equals("cursor", sidebar:acp_provider_name())
    end)

    it("uses the pending selection before a thread exists", function()
      -- new_thread sets current_acp_provider before chat_history is written.
      local sidebar = make_sidebar({ current_acp_provider = "cursor" })

      assert.equals("cursor", sidebar:acp_provider_name())
    end)

    it("lets the saved thread win over a stale in-memory selection", function()
      local sidebar = make_sidebar({
        chat_history = { acp_provider = "cursor" },
        current_acp_provider = "goose",
      })

      assert.equals("cursor", sidebar:acp_provider_name())
    end)
  end)

  describe("acp_connect_pending", function()
    it("is false before any connect is attempted", function()
      assert.is_false(make_sidebar():acp_connect_pending())
    end)

    it("is true while the agent is coming up", function()
      -- connect_acp clears acp_client and sets the flag; the client is only
      -- assigned once the agent answers initialize. This window is the one in
      -- which a submitted prompt used to report "not connected".
      local sidebar = make_sidebar({ _acp_connecting = "cursor" })

      assert.is_true(sidebar:acp_connect_pending())
    end)

    it("is false once the client is up", function()
      local sidebar = make_sidebar({ _acp_connecting = "cursor", acp_client = {} })

      assert.is_false(sidebar:acp_connect_pending())
    end)

    it("is false after a failed connect clears the flag", function()
      local sidebar = make_sidebar({ _acp_connecting = "cursor" })
      sidebar._acp_connecting = nil

      assert.is_false(sidebar:acp_connect_pending())
    end)
  end)
end)
