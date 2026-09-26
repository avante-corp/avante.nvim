local Path = require("avante.path")

describe("sidebar thread title", function()
  local Sidebar
  local original_save

  before_each(function()
    Sidebar = require("avante.sidebar")
    original_save = Path.history.save
  end)

  after_each(function() Path.history.save = original_save end)

  it("synchronizes, persists, and rerenders a renamed thread", function()
    local saved
    local rendered = false
    local hinted = false
    Path.history.save = function(bufnr, history)
      saved = { bufnr = bufnr, history = history }
    end
    local sidebar = {
      code = { bufnr = 12 },
      chat_history = { title = "untitled" },
      acp_thread = { title = "untitled" },
      render_result = function() rendered = true end,
      show_input_hint = function() hinted = true end,
    }
    sidebar.rename_thread = Sidebar.rename_thread

    sidebar:rename_thread("  Release prep  ")

    assert.equals("Release prep", sidebar.chat_history.title)
    assert.equals("Release prep", sidebar.acp_thread.title)
    assert.equals(12, saved.bufnr)
    assert.equals(sidebar.chat_history, saved.history)
    assert.is_true(rendered)
    assert.is_true(hinted)
  end)
end)
