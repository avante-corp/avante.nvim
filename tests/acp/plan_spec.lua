--- Plans delivered over the wire.
---
--- claude writes its plan to ~/.claude/plans/<name>.md as a file edit, which is
--- how /open-plan finds it. Cursor sends the whole plan inside
--- cursor/create_plan and expects only an approve/reject answer, so unless it
--- is persisted the plan is gone the moment the prompt is answered.

local Plan = require("avante.acp.plan")
local Utils = require("avante.utils")

--- The documented cursor/create_plan example payload.
local function payload()
  return {
    toolCallId = "call_124",
    name = "Refactor tabs layout",
    overview = "Tighten layout behavior and preserve existing UX.",
    plan = "1. Inspect current tab sizing logic.\n2. Update layout calculations.",
    todos = {
      { id = "todo-1", content = "Inspect current tab sizing logic", status = "completed" },
      { id = "todo-2", content = "Update layout calculations", status = "in_progress" },
      { id = "todo-3", content = "Verify editor behavior", status = "pending" },
    },
  }
end

describe("acp.plan", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function() vim.fn.delete(tmp, "rf") end)

  describe("render_markdown", function()
    it("includes the name, overview, plan body and todos", function()
      local markdown = Plan.render_markdown(payload())

      assert.is_not_nil(markdown:find("# Refactor tabs layout", 1, true))
      assert.is_not_nil(markdown:find("Tighten layout behavior", 1, true))
      assert.is_not_nil(markdown:find("Inspect current tab sizing logic", 1, true))
      assert.is_not_nil(markdown:find("Verify editor behavior", 1, true))
    end)

    it("renders todo status as checkboxes", function()
      local markdown = Plan.render_markdown(payload())

      assert.is_not_nil(markdown:find("- [x] Inspect", 1, true))
      assert.is_not_nil(markdown:find("- [~] Update", 1, true))
      assert.is_not_nil(markdown:find("- [ ] Verify", 1, true))
    end)

    it("copes with a bare payload", function()
      local markdown = Plan.render_markdown({})

      assert.is_not_nil(markdown:find("# Agent Plan", 1, true))
    end)
  end)

  describe("write", function()
    it("saves under a dated directory", function()
      local path = Plan.write(payload(), { dir = tmp, session_id = "abcdef123456" })

      assert.is_not_nil(path)
      assert.equals(1, vim.fn.filereadable(path))
      assert.is_not_nil(path:find(os.date("%Y-%m-%d"), 1, true))
    end)

    it("names the file after the session and plan", function()
      local path = Plan.write(payload(), { dir = tmp, session_id = "abcdef123456" })

      local name = vim.fn.fnamemodify(path, ":t")
      assert.is_not_nil(name:find("abcdef12", 1, true))
      assert.is_not_nil(name:find("refactor-tabs-layout", 1, true))
    end)

    it("writes the rendered markdown", function()
      local path = Plan.write(payload(), { dir = tmp })

      local content = table.concat(vim.fn.readfile(path), "\n")
      assert.is_not_nil(content:find("Tighten layout behavior", 1, true))
    end)

    it("cannot escape the plan directory via the name", function()
      local nasty = payload()
      nasty.name = "../../etc/passwd"

      local path = Plan.write(nasty, { dir = tmp })

      assert.is_not_nil(path:find(tmp, 1, true))
      assert.is_nil(vim.fn.fnamemodify(path, ":t"):find("/", 1, true))
    end)
  end)

  describe("to_todos", function()
    it("maps statuses the plan panel understands", function()
      local todos = Plan.to_todos(payload())

      assert.equals(3, #todos)
      assert.equals("completed", todos[1].status)
      assert.equals("in_progress", todos[2].status)
      assert.equals("pending", todos[3].status)
    end)

    it("folds cursor's cancelled status into completed", function()
      -- The panel has no cancelled state; leaving it through renders as
      -- permanently outstanding.
      local todos = Plan.to_todos({ todos = { { content = "Dropped", status = "cancelled" } } })

      assert.equals("completed", todos[1].status)
    end)

    it("falls back to pending for an unknown status", function()
      local todos = Plan.to_todos({ todos = { { content = "x", status = "weird" } } })

      assert.equals("pending", todos[1].status)
    end)

    it("is empty for a payload with no todos", function() assert.same({}, Plan.to_todos({})) end)
  end)

  describe("/open-plan lookup", function()
    it("prefers a path recorded on the thread", function()
      -- Scanning tool calls for a `.claude/plans/` path only ever finds
      -- claude's; cursor never writes a file.
      local found = Utils.plan_find_file_path({ plan_file_path = "/tmp/plan.md", messages = {} })

      assert.equals("/tmp/plan.md", found)
    end)

    it("ignores an empty recorded path", function()
      assert.is_nil(Utils.plan_find_file_path({ plan_file_path = "", messages = {} }))
    end)

    it("still finds a claude plan written as a file", function()
      local history = {
        messages = {
          {
            message = { content = {} },
            acp_tool_call = {
              title = "Write /Users/me/.claude/plans/thing.md",
              rawInput = { file_path = "/Users/me/.claude/plans/thing.md" },
            },
          },
        },
      }

      assert.equals("/Users/me/.claude/plans/thing.md", Utils.plan_find_file_path(history))
    end)

    it("returns nil when there is no plan at all", function()
      assert.is_nil(Utils.plan_find_file_path({ messages = {} }))
    end)
  end)
end)
