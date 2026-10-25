local History = require("avante.history")
local Message = History.Message
require("avante.config").setup({})

local function assistant(content, order, turn_id)
  return Message:new("assistant", content, { order = order, turn_id = turn_id or "turn" })
end

local function tool(id, order) return assistant({ type = "tool_use", id = id, name = "lookup", input = {} }, order) end

local function result(id) return Message:new("user", { type = "tool_result", tool_use_id = id, content = "answer" }) end

describe("provider history order", function()
  it("uses final block order for history and pending tool execution without changing UUIDs", function()
    local first, second = tool("first", 0), tool("second", 1)
    local history = { messages = { second, first } }
    local saved_uuid = first.uuid
    local pending, pending_messages = History.get_pending_tools(history.messages)
    assert.same({ "first", "second" }, vim.tbl_map(function(item) return item.id end, pending))
    assert.same(first, pending_messages[1])
    assert.same({ first, second }, History.get_history_messages(history))
    assert.same(saved_uuid, first.uuid)
  end)

  it("keeps turns, user messages and messages without an ordinal in place", function()
    local first = assistant("first", 0)
    local second = assistant("second", 1)
    local user = Message:new("user", "continue")
    local third = assistant("third", 0, "next")
    local fourth = assistant("fourth", 1, "next")
    local fifth = assistant("fifth", 0, "another")
    local sixth = assistant("sixth", 1, "another")
    local legacy = assistant("legacy", nil)
    local after_legacy = assistant("after legacy", 0)
    local history = { messages = { second, first, user, fourth, third, sixth, fifth, legacy, after_legacy } }
    assert.same(
      { first, second, user, third, fourth, fifth, sixth, legacy, after_legacy },
      History.get_history_messages(history)
    )
  end)

  it("keeps the complete assistant reply before its tool results", function()
    local reasoning = assistant({ type = "thinking", thinking = "plan" }, 0)
    local first, second = tool("first", 1), tool("second", 2)
    local first_result, second_result = result("first"), result("second")
    local refreshed =
      History.update_tool_invocation_history({ second, reasoning, first, first_result, second_result }, nil, false)
    assert.same({ reasoning, first, second, first_result, second_result }, refreshed)
  end)

  it("adds file refreshes after all results in the original reply", function()
    local edit = assistant({ type = "tool_use", id = "edit", name = "edit_file", input = { path = "test.txt" } }, 0)
    local lookup = tool("lookup", 1)
    local edit_result, lookup_result = result("edit"), result("lookup")
    local refreshed = History.update_tool_invocation_history({ edit, lookup, edit_result, lookup_result }, nil, false)
    assert.same({ edit, lookup, edit_result, lookup_result }, vim.list_slice(refreshed, 1, 4))
    assert.equals("view", refreshed[6].message.content[1].name)
  end)
end)
