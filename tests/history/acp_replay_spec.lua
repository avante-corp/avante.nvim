local AcpReplay = require("avante.history.acp_replay")

---@param text string
local function text(text) return { type = "text", text = text } end

---@param messages avante.HistoryMessage[]
---@return { role: string, content: any }[]
local function summarize(messages)
  return vim.tbl_map(function(m) return { role = m.message.role, content = m.message.content } end, messages)
end

local function wrap(role, body) return "<" .. role .. ">" .. body .. "</" .. role .. ">" end

describe("acp_replay", function()
  describe("unwrap_avante_prompt", function()
    it("returns the newest user message from a session continuation prompt", function()
      local prompt = "[@main.py](file:///p/main.py)"
        .. wrap("previous_user_message", "What was the code word?")
        .. wrap("previous_user_message", "Remember pineapple")
        .. "<system_context>Continuing from previous session with 2 recent user messages</system_context>"

      assert.equals("What was the code word?", AcpReplay.unwrap_avante_prompt(prompt))
    end)

    it("returns the last user message from a session recovery prompt", function()
      local prompt = wrap("previous_user_message", "Remember pineapple")
        .. wrap("previous_assistant_message", "OK")
        .. wrap("previous_user_message", "What was the code word?")
        .. "<system_context>Continuing from previous ACP session with 3 recent messages preserved for context</system_context>"

      assert.equals("What was the code word?", AcpReplay.unwrap_avante_prompt(prompt))
    end)

    it("recovers the request from a prompt that already contained nested wrappers", function()
      local earlier = wrap("previous_user_message", "Remember pineapple")
        .. "<system_context>Continuing from previous session with 1 recent user messages</system_context>"
      local prompt = wrap("previous_user_message", "What was the code word?")
        .. wrap("previous_user_message", earlier)
        .. "<system_context>Continuing from previous session with 2 recent user messages</system_context>"

      assert.equals("What was the code word?", AcpReplay.unwrap_avante_prompt(prompt))
    end)

    it("leaves other text alone, even with similar tags", function()
      local text = "Explain " .. wrap("previous_user_message", "this") .. " please"
      assert.equals(text, AcpReplay.unwrap_avante_prompt(text))
      assert.equals("plain question", AcpReplay.unwrap_avante_prompt("plain question"))
    end)

    it("is applied to replayed user messages", function()
      local prompt = wrap("previous_user_message", "What was it?")
        .. "<system_context>Continuing from previous session with 1 recent user messages</system_context>"
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "user_message_chunk", content = text(prompt:sub(1, 20)) },
        { sessionUpdate = "user_message_chunk", content = text(prompt:sub(21)) },
        { sessionUpdate = "agent_message_chunk", content = text(prompt) },
      })

      assert.equals("What was it?", messages[1].message.content)
      assert.equals(prompt, messages[2].message.content)
    end)
  end)

  describe("is_conversation_update", function()
    it("accepts message, thought and tool call updates", function()
      for _, kind in ipairs({
        "user_message_chunk",
        "agent_message_chunk",
        "agent_thought_chunk",
        "tool_call",
        "tool_call_update",
      }) do
        assert.is_true(AcpReplay.is_conversation_update({ sessionUpdate = kind }))
      end
    end)

    it("rejects plans, commands and mode updates", function()
      for _, kind in ipairs({ "plan", "available_commands_update", "current_mode_update", "config_option_update" }) do
        assert.is_false(AcpReplay.is_conversation_update({ sessionUpdate = kind }))
      end
    end)
  end)

  describe("to_messages", function()
    it("merges consecutive chunks and alternates roles", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "user_message_chunk", content = text("Remember ") },
        { sessionUpdate = "user_message_chunk", content = text("pineapple") },
        { sessionUpdate = "agent_message_chunk", content = text("O") },
        { sessionUpdate = "agent_message_chunk", content = text("K") },
        { sessionUpdate = "user_message_chunk", content = text("What was it?") },
        { sessionUpdate = "agent_message_chunk", content = text("pineapple") },
      })

      assert.same({
        { role = "user", content = "Remember pineapple" },
        { role = "assistant", content = "OK" },
        { role = "user", content = "What was it?" },
        { role = "assistant", content = "pineapple" },
      }, summarize(messages))
      assert.is_true(messages[1].is_user_submission)
      assert.is_false(messages[2].is_user_submission)
    end)

    it("turns thought chunks into one thinking item", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "agent_thought_chunk", content = text("Let me ") },
        { sessionUpdate = "agent_thought_chunk", content = text("think") },
        { sessionUpdate = "agent_message_chunk", content = text("Done") },
      })

      assert.same({
        { role = "assistant", content = { { type = "thinking", thinking = "Let me think" } } },
        { role = "assistant", content = "Done" },
      }, summarize(messages))
    end)

    it("renders resource links as mentions and skips other content", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "user_message_chunk", content = text("Look at ") },
        {
          sessionUpdate = "user_message_chunk",
          content = { type = "resource_link", name = "main.py", uri = "file:///p/main.py" },
        },
        { sessionUpdate = "user_message_chunk", content = { type = "image", data = "..." } },
      })

      assert.same({ { role = "user", content = "Look at @main.py" } }, summarize(messages))
    end)

    it("builds a tool use and its result from a tool call and its completion", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "agent_message_chunk", content = text("Reading") },
        {
          sessionUpdate = "tool_call",
          toolCallId = "t1",
          title = "Read main.py",
          kind = "read",
          status = "pending",
          rawInput = { path = "main.py", description = "Read the entry point" },
        },
        { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed", content = {} },
        { sessionUpdate = "agent_message_chunk", content = text("Done") },
      })

      assert.equals(4, #messages)
      local tool_use = messages[2]
      assert.equals("t1", tool_use.uuid)
      assert.same({
        type = "tool_use",
        id = "t1",
        name = "read",
        input = { path = "main.py", description = "Read the entry point" },
      }, tool_use.message.content[1])
      assert.equals("completed", tool_use.acp_tool_call.status)
      assert.equals("Read main.py", tool_use.acp_tool_call.title)
      assert.is_false(tool_use.is_calling)
      assert.same({ "Read the entry point" }, tool_use.tool_use_logs)

      assert.same({ type = "tool_result", tool_use_id = "t1", is_error = false }, messages[3].message.content[1])
      assert.same({ role = "assistant", content = "Done" }, summarize({ messages[4] })[1])
    end)

    it("marks failed tool calls as errors", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "tool_call", toolCallId = "t1", title = "Run", status = "in_progress" },
        { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "failed" },
      })

      assert.is_true(messages[2].message.content[1].is_error)
    end)

    it("adds a result for a tool call that arrives already completed, only once", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "tool_call", toolCallId = "t1", title = "Run", status = "completed" },
        { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" },
      })

      assert.equals(2, #messages)
      assert.equals("tool_result", messages[2].message.content[1].type)
    end)

    it("creates a tool use for an update with no earlier tool call", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "tool_call_update", toolCallId = "t1", title = "Edit", status = "completed" },
      })

      assert.equals("tool_use", messages[1].message.content[1].type)
      assert.equals("t1", messages[1].uuid)
      assert.equals("tool_result", messages[2].message.content[1].type)
    end)

    it("keeps earlier tool output when an update has empty content", function()
      local output = { { type = "content", content = text("file contents") } }
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "tool_call", toolCallId = "t1", title = "Read", status = "pending", content = output },
        { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed", content = {} },
      })

      assert.same(output, messages[1].acp_tool_call.content)
    end)

    it("leaves no tool call running when the replay ends mid-call", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "tool_call", toolCallId = "t1", title = "Run", status = "in_progress" },
      })

      assert.equals(1, #messages)
      assert.is_false(messages[1].is_calling)
      assert.equals("generated", messages[1].state)
    end)

    it("defaults tool input to an empty table and ignores other updates", function()
      local messages = AcpReplay.to_messages({
        { sessionUpdate = "plan", entries = {} },
        { sessionUpdate = "tool_call", toolCallId = "t1", title = "Run", status = "pending" },
      })

      assert.equals(1, #messages)
      assert.same({}, messages[1].message.content[1].input)
    end)
  end)
end)
