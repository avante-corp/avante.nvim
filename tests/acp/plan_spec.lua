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

    it("recognises a cursor plan the agent edited as a file", function()
      local history = {
        messages = {
          {
            message = { content = {} },
            acp_tool_call = {
              title = "Write /Users/me/.cursor/plans/Thing-abcdef12.plan.md",
              rawInput = { file_path = "/Users/me/.cursor/plans/Thing-abcdef12.plan.md" },
            },
          },
        },
      }

      assert.equals("/Users/me/.cursor/plans/Thing-abcdef12.plan.md", Utils.plan_find_file_path(history))
    end)
  end)

  describe("the agent's own plan file", function()
    local SESSION = "2fd6f9f1-4da0-4fbe-988b-dce9d71b16eb"
    local cursor_dir_stub

    before_each(function()
      cursor_dir_stub = Plan.CURSOR_PLAN_DIR
      Plan.CURSOR_PLAN_DIR = tmp
    end)

    after_each(function() Plan.CURSOR_PLAN_DIR = cursor_dir_stub end)

    ---A plan file named the way cursor names them.
    local function cursor_plan(name, first_line)
      local path = tmp .. "/" .. name
      vim.fn.writefile({ first_line or "# A plan", "", "Do the thing." }, path)
      return path
    end

    it("finds the file cursor named after the session", function()
      local path = cursor_plan("App branches summary-2fd6f9f1.plan.md")

      assert.equals(path, Plan.find_agent_file(SESSION))
    end)

    it("prefers the file stamped with the whole session id", function()
      -- Eight characters of a filename can belong to another session; the id
      -- cursor writes into the first line cannot.
      cursor_plan("Alpha-2fd6f9f1.plan.md")
      local mine = cursor_plan("Zulu-2fd6f9f1.plan.md", "<!-- " .. SESSION .. " -->")

      assert.equals(mine, Plan.find_agent_file(SESSION))
    end)

    it("has nothing to find without a session", function()
      cursor_plan("App branches summary-2fd6f9f1.plan.md")

      assert.is_nil(Plan.find_agent_file(nil))
      assert.is_nil(Plan.find_agent_file("short"))
    end)

    it("is nil for an agent that keeps no plan file", function()
      assert.is_nil(Plan.find_agent_file("00000000-1111-2222-3333-444444444444"))
    end)

    it("wins over the copy saved when the plan was proposed", function()
      -- cursor rewrites its own file as the session goes on, so what avante
      -- saved at cursor/create_plan time is a plan the agent has moved past.
      local live = cursor_plan("App branches summary-2fd6f9f1.plan.md")

      local found = Utils.plan_find_file_path({
        acp_session_id = SESSION,
        plan_file_path = "/tmp/snapshot.md",
        messages = {},
      })

      assert.equals(live, found)
    end)

    it("leaves the saved copy in place for an agent that wrote none", function()
      local found = Utils.plan_find_file_path({
        acp_session_id = "00000000-1111-2222-3333-444444444444",
        plan_file_path = "/tmp/snapshot.md",
        messages = {},
      })

      assert.equals("/tmp/snapshot.md", found)
    end)
  end)
end)
