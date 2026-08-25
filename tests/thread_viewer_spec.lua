--- Thread summaries must be hydrated before use.
---
--- list_all_histories returns lightweight summaries with no `messages` -- that
--- is what makes listing fast. The preview pane renders from `messages`, and
--- the open callback assigns the object to sidebar.chat_history and *saves it*,
--- so handing an unhydrated summary onward would overwrite a real conversation
--- with an empty stub.

local TV = require("avante.thread_viewer")

--- Write a history file and return the summary shape the bridge would emit.
local function make_history(dir, name, messages)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  local file = io.open(path, "w")
  file:write(vim.json.encode({
    filename = name,
    title = "Recorded thread",
    timestamp = "2026-08-01T00:00:00Z",
    messages = messages,
    tags = { "claude" },
  }))
  file:close()
  return path
end

describe("thread_viewer.hydrate", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function() vim.fn.delete(tmp, "rf") end)

  it("loads messages for a summary", function()
    local path = make_history(tmp, "1.json", {
      { message = { role = "user", content = "hello" }, timestamp = "2026-08-01" },
      { message = { role = "assistant", content = "hi" }, timestamp = "2026-08-01" },
    })

    local full = TV.hydrate({ filename = "1.json", path = path, message_count = 2 })

    assert.equals(2, #full.messages)
    assert.equals("Recorded thread", full.title)
  end)

  it("returns an already-full history untouched", function()
    local history = { messages = { { a = 1 } }, title = "Full" }

    local result = TV.hydrate(history)

    assert.equals(history, result)
  end)

  it("leaves external sessions alone", function()
    -- They have no local file to read.
    local external = { _is_external = true, acp_session_id = "sess-1" }

    assert.equals(external, TV.hydrate(external))
  end)

  it("returns the summary unchanged when it has no path", function()
    local summary = { title = "No path", message_count = 3 }

    local result = TV.hydrate(summary)

    assert.is_nil(result.messages)
  end)

  it("returns the summary unchanged when the file is gone", function()
    -- Never invent an empty history: callers save what they are given.
    local summary = { filename = "9.json", path = tmp .. "/missing.json", message_count = 3 }

    local result = TV.hydrate(summary)

    assert.is_nil(result.messages)
  end)

  it("keeps the summary's working_directory when the file lacks one", function()
    local path = make_history(tmp, "1.json", {})

    local full = TV.hydrate({ path = path, working_directory = "/from/summary" })

    assert.equals("/from/summary", full.working_directory)
  end)

  it("preserves path so a second hydrate is still possible", function()
    local path = make_history(tmp, "1.json", {})

    assert.equals(path, TV.hydrate({ path = path }).path)
  end)

  it("is safe on nil", function() assert.is_nil(TV.hydrate(nil)) end)

  it("produces a history that renders preview content", function()
    -- The preview pane was blank because summaries carry no messages.
    -- Sidebar pulls in nui.nvim, which the minimal test runtime lacks.
    if not pcall(require, "nui.split") then
      pending("nui.nvim not available in the test runtime")
      return
    end

    local path = make_history(tmp, "1.json", {
      { message = { role = "user", content = "what is 2+2" }, timestamp = "2026-08-01" },
    })

    local full = TV.hydrate({ path = path })
    local content = require("avante.sidebar").render_history_content(full)

    assert.is_true(#content > 0)
  end)
end)
