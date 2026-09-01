--- Arrow-key recall of previous prompts into the sidebar input box, plus the
--- buffer options that keep typed prompts from being auto-wrapped.

local Config = require("avante.config")
local InputHistory = require("avante.utils.input_history")
local Utils = require("avante.utils")

---@param role string
---@param text string
---@param opts table|nil
local function message(role, text, opts)
  return vim.tbl_extend("force", {
    message = { role = role, content = text },
  }, opts or {})
end

---A sidebar stand-in: recall only needs the input container and the thread.
local function make_sidebar(messages)
  local bufnr = vim.api.nvim_create_buf(false, true)
  return {
    bufnr = bufnr,
    containers = { input = { bufnr = bufnr } },
    chat_history = { messages = messages or {} },
    submitted = false,
    handle_submit = function(self) self.submitted = true end,
  }
end

local function buf_text(sidebar)
  return table.concat(vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false), "\n")
end

local function set_buf_text(sidebar, text)
  vim.api.nvim_buf_set_lines(sidebar.bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

describe("input history recall", function()
  local original_collect_project_prompts

  before_each(function()
    Config.setup({})
    original_collect_project_prompts = InputHistory.collect_project_prompts
    InputHistory.collect_project_prompts = function() return {} end
  end)

  after_each(function() InputHistory.collect_project_prompts = original_collect_project_prompts end)

  describe("candidate list", function()
    it("takes the thread's user prompts newest first", function()
      local sidebar = make_sidebar({
        message("user", "first"),
        message("assistant", "answer"),
        message("user", "second"),
      })

      assert.same({ "second", "first" }, InputHistory.collect_thread_prompts(sidebar))
    end)

    it("skips display-only messages and non-text content", function()
      local sidebar = make_sidebar({
        message("user", "real prompt"),
        message("user", "banner", { just_for_display = true }),
        message("user", "   "),
        {
          message = {
            role = "user",
            content = { { type = "text", content = "a" }, { type = "text", content = "b" } },
          },
        },
      })

      assert.same({ "real prompt" }, InputHistory.collect_thread_prompts(sidebar))
    end)

    it("puts thread prompts ahead of project prompts and drops duplicates", function()
      local items = InputHistory.merge_items({ "thread new", "shared" }, { "shared", "project old" })

      assert.same({ "thread new", "shared", "project old" }, items)
    end)

    it("honours the configured source", function()
      local thread, project = { "thread" }, { "project" }

      assert.same({ "thread" }, InputHistory.merge_items(thread, project, "thread"))
      assert.same({ "project" }, InputHistory.merge_items(thread, project, "project"))
      assert.same({ "thread", "project" }, InputHistory.merge_items(thread, project, "thread_then_project"))
    end)
  end)

  describe("stepping", function()
    it("clamps at the draft and at the oldest entry", function()
      assert.equals(0, InputHistory.clamp_index(0, 2, -1))
      assert.equals(1, InputHistory.clamp_index(0, 2, 1))
      assert.equals(2, InputHistory.clamp_index(2, 2, 1))
    end)

    it("walks older prompts and stops at the oldest", function()
      local sidebar = make_sidebar({ message("user", "oldest"), message("user", "newest") })

      InputHistory.recall(sidebar, 1)
      assert.equals("newest", buf_text(sidebar))

      InputHistory.recall(sidebar, 1)
      assert.equals("oldest", buf_text(sidebar))

      InputHistory.recall(sidebar, 1)
      assert.equals("oldest", buf_text(sidebar))
    end)

    it("restores the draft when walking back past the newest prompt", function()
      local sidebar = make_sidebar({ message("user", "logged") })
      set_buf_text(sidebar, "half-written thought")

      InputHistory.recall(sidebar, 1)
      assert.equals("logged", buf_text(sidebar))

      InputHistory.recall(sidebar, -1)
      assert.equals("half-written thought", buf_text(sidebar))
    end)

    it("recalls multi-line prompts intact", function()
      local sidebar = make_sidebar({ message("user", "line one\nline two") })

      InputHistory.recall(sidebar, 1)

      assert.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false))
    end)

    it("never submits", function()
      local sidebar = make_sidebar({ message("user", "logged") })

      InputHistory.recall(sidebar, 1)

      assert.is_false(sidebar.submitted)
    end)

    it("does nothing without history", function()
      local sidebar = make_sidebar({})
      set_buf_text(sidebar, "draft")

      InputHistory.recall(sidebar, 1)

      assert.equals("draft", buf_text(sidebar))
    end)
  end)

  describe("state lifetime", function()
    it("restashes the draft after the user edits a recalled prompt", function()
      local sidebar = make_sidebar({ message("user", "logged") })

      InputHistory.recall(sidebar, 1)
      set_buf_text(sidebar, "logged, now edited")
      InputHistory.on_text_changed(sidebar.bufnr)

      InputHistory.recall(sidebar, 1)
      assert.equals("logged", buf_text(sidebar))

      InputHistory.recall(sidebar, -1)
      assert.equals("logged, now edited", buf_text(sidebar))
    end)

    it("keeps walking history when the change came from recall itself", function()
      local sidebar = make_sidebar({ message("user", "oldest"), message("user", "newest") })

      InputHistory.recall(sidebar, 1)
      InputHistory.on_text_changed(sidebar.bufnr)
      InputHistory.recall(sidebar, 1)

      assert.equals("oldest", buf_text(sidebar))
    end)

    it("treats the buffer as a fresh draft after a reset", function()
      local sidebar = make_sidebar({ message("user", "logged") })

      InputHistory.recall(sidebar, 1)
      InputHistory.reset(sidebar.bufnr)
      set_buf_text(sidebar, "new draft")

      InputHistory.recall(sidebar, 1)
      assert.equals("logged", buf_text(sidebar))

      InputHistory.recall(sidebar, -1)
      assert.equals("new draft", buf_text(sidebar))
    end)
  end)
end)

describe("input history arrow keys", function()
  local original_collect_project_prompts

  before_each(function()
    original_collect_project_prompts = InputHistory.collect_project_prompts
    InputHistory.collect_project_prompts = function() return {} end
  end)

  after_each(function() InputHistory.collect_project_prompts = original_collect_project_prompts end)

  ---@return table sidebar, integer winid
  local function make_windowed_sidebar()
    local sidebar = make_sidebar({ message("user", "logged") })
    local winid = vim.api.nvim_open_win(sidebar.bufnr, false, {
      relative = "editor",
      width = 20,
      height = 5,
      row = 1,
      col = 1,
    })
    sidebar.containers.input.winid = winid
    set_buf_text(sidebar, "draft one\ndraft two")
    return sidebar, winid
  end

  it("leaves the cursor alone until it reaches the first line", function()
    Config.setup({})
    local sidebar, winid = make_windowed_sidebar()

    vim.api.nvim_win_set_cursor(winid, { 2, 0 })
    InputHistory.make_handler(sidebar, 1, "<Up>")()
    assert.equals("draft one\ndraft two", buf_text(sidebar))

    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    InputHistory.make_handler(sidebar, 1, "<Up>")()
    assert.equals("logged", buf_text(sidebar))

    vim.api.nvim_win_close(winid, true)
  end)

  it("recalls from mid-buffer when forced, as shift+arrow does", function()
    Config.setup({})
    local sidebar, winid = make_windowed_sidebar()

    vim.api.nvim_win_set_cursor(winid, { 2, 0 })
    InputHistory.make_handler(sidebar, 1, "<Up>")()
    assert.equals("draft one\ndraft two", buf_text(sidebar))

    InputHistory.make_handler(sidebar, 1, "<S-Up>", { force = true })()
    assert.equals("logged", buf_text(sidebar))

    InputHistory.make_handler(sidebar, -1, "<S-Down>", { force = true })()
    assert.equals("draft one\ndraft two", buf_text(sidebar))

    vim.api.nvim_win_close(winid, true)
  end)

  it("recalls from anywhere when edge_only is off", function()
    Config.setup({ prompt_logger = { recall = { edge_only = false } } })
    local sidebar, winid = make_windowed_sidebar()

    vim.api.nvim_win_set_cursor(winid, { 2, 0 })
    InputHistory.make_handler(sidebar, 1, "<Up>")()

    assert.equals("logged", buf_text(sidebar))
    vim.api.nvim_win_close(winid, true)
    Config.setup({})
  end)
end)

describe("input buffer formatting", function()
  it("never auto-wraps, whatever the global settings are", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("textwidth", 120, { buf = bufnr })
    vim.api.nvim_set_option_value("formatoptions", "tcqaw", { buf = bufnr })

    Config.setup({})
    Utils.disable_auto_format(bufnr, Config.windows.input)

    assert.equals(0, vim.api.nvim_get_option_value("textwidth", { buf = bufnr }))
    local formatoptions = vim.api.nvim_get_option_value("formatoptions", { buf = bufnr })
    assert.is_nil(formatoptions:find("t", 1, true))
    assert.is_nil(formatoptions:find("a", 1, true))
  end)
end)
