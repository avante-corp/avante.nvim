--- Elicitation form rendering.
---
--- claude-agent-acp maps its AskUserQuestion tool onto elicitation/create and
--- disables the tool entirely unless the client advertises elicitation.form,
--- so these pin the shape it actually sends.

local Elicitation = require("avante.acp.elicitation")

--- Build the params claude-agent-acp sends for a single-select question.
local function single_select_params()
  return {
    message = "Which approach?",
    mode = {
      requestedSchema = {
        type = "object",
        properties = {
          question_0 = {
            type = "string",
            title = "Approach",
            oneOf = {
              { const = "Rewrite", title = "Rewrite", description = "Start fresh" },
              { const = "Patch", title = "Patch" },
            },
          },
          question_0_custom = { type = "string", title = "Other" },
        },
      },
    },
  }
end

describe("acp.elicitation", function()
  local select_stub, input_stub

  local function stub_select(chooser)
    vim.ui.select = function(items, opts, on_choice) chooser(items, opts, on_choice) end
  end

  before_each(function()
    select_stub = vim.ui.select
    input_stub = vim.ui.input
  end)

  after_each(function()
    vim.ui.select = select_stub
    vim.ui.input = input_stub
  end)

  --- Run prompt() and return the reply, draining scheduled callbacks.
  local function run(params)
    local answer
    Elicitation.prompt(params, function(a) answer = a end)
    vim.wait(2000, function() return answer ~= nil end, 10)
    return answer
  end

  describe("field ordering", function()
    it("orders question fields numerically, not by pairs()", function()
      local fields = Elicitation._ordered_question_fields({
        question_10 = {},
        question_2 = {},
        question_1 = {},
        question_1_custom = {},
      })

      assert.same({ "question_1", "question_2", "question_10" }, fields)
    end)

    it("excludes the paired custom free-text fields", function()
      local fields = Elicitation._ordered_question_fields({
        question_0 = {},
        question_0_custom = {},
      })

      assert.same({ "question_0" }, fields)
    end)
  end)

  describe("option extraction", function()
    it("reads single-select options from oneOf", function()
      local options, multi = Elicitation._field_options({
        type = "string",
        oneOf = { { const = "a" }, { const = "b" } },
      })

      assert.equals(2, #options)
      assert.is_false(multi)
    end)

    it("reads multi-select options from items.anyOf", function()
      local options, multi = Elicitation._field_options({
        type = "array",
        items = { anyOf = { { const = "a" } } },
      })

      assert.equals(1, #options)
      assert.is_true(multi)
    end)
  end)

  describe("answering", function()
    it("accepts with the chosen option const", function()
      stub_select(function(items, _, on_choice)
        -- First item is the first schema option.
        on_choice(items[1])
      end)

      local answer = run(single_select_params())

      assert.equals("accept", answer.action)
      assert.equals("Rewrite", answer.content.question_0)
    end)

    it("wraps a multi-select answer in an array", function()
      stub_select(function(items, _, on_choice) on_choice(items[1]) end)

      local answer = run({
        message = "Pick some",
        mode = {
          requestedSchema = {
            properties = {
              question_0 = { type = "array", items = { anyOf = { { const = "x" } } } },
            },
          },
        },
      })

      assert.same({ "x" }, answer.content.question_0)
    end)

    it("cancels when the user presses escape", function()
      stub_select(function(_, _, on_choice) on_choice(nil) end)

      assert.equals("cancel", run(single_select_params()).action)
    end)

    it("declines when every question is skipped", function()
      stub_select(function(items, _, on_choice)
        -- Last entry is the Skip choice.
        on_choice(items[#items])
      end)

      assert.equals("decline", run(single_select_params()).action)
    end)

    it("sends free text under the custom field", function()
      stub_select(function(items, _, on_choice)
        -- Second to last is "Type my own answer…" when a custom field exists.
        on_choice(items[#items - 1])
      end)
      vim.ui.input = function(_, on_confirm) on_confirm("my own answer") end

      local answer = run(single_select_params())

      assert.equals("accept", answer.action)
      assert.equals("my own answer", answer.content.question_0_custom)
      assert.is_nil(answer.content.question_0)
    end)

    it("treats empty free text as a skip", function()
      stub_select(function(items, _, on_choice) on_choice(items[#items - 1]) end)
      vim.ui.input = function(_, on_confirm) on_confirm("") end

      assert.equals("decline", run(single_select_params()).action)
    end)

    it("answers each question of a multi-question form", function()
      stub_select(function(items, _, on_choice) on_choice(items[1]) end)

      local answer = run({
        message = "Please answer the following questions.",
        mode = {
          requestedSchema = {
            properties = {
              question_0 = { type = "string", oneOf = { { const = "a0" } } },
              question_1 = { type = "string", oneOf = { { const = "a1" } } },
            },
          },
        },
      })

      assert.equals("a0", answer.content.question_0)
      assert.equals("a1", answer.content.question_1)
    end)

    it("declines a form with no renderable fields", function()
      -- e.g. url-mode elicitation, which we cannot present.
      assert.equals("decline", run({ message = "hi", mode = { requestedSchema = {} } }).action)
    end)

    it("offers no custom entry when the schema has no custom field", function()
      local seen
      stub_select(function(items, _, on_choice)
        seen = items
        on_choice(items[#items])
      end)

      run({
        message = "Pick",
        mode = {
          requestedSchema = {
            properties = { question_0 = { type = "string", oneOf = { { const = "a" } } } },
          },
        },
      })

      for _, item in ipairs(seen) do
        assert.is_nil(item.custom)
      end
    end)
  end)

  describe("dismissal is visible", function()
    -- A dismissed question is otherwise invisible from the sidebar: the agent
    -- reports it only as "Tool use aborted", which reads as a bug.
    local Utils = require("avante.utils")
    local warn_stub, info_stub, notices

    before_each(function()
      notices = {}
      warn_stub, info_stub = Utils.warn, Utils.info
      Utils.warn = function(msg) table.insert(notices, { level = "warn", msg = msg }) end
      Utils.info = function(msg) table.insert(notices, { level = "info", msg = msg }) end
    end)

    after_each(function()
      Utils.warn, Utils.info = warn_stub, info_stub
    end)

    it("warns when the question is cancelled", function()
      stub_select(function(_, _, on_choice) on_choice(nil) end)

      run(single_select_params())

      assert.equals(1, #notices)
      assert.equals("warn", notices[1].level)
    end)

    it("notes a skip without raising it to a warning", function()
      stub_select(function(items, _, on_choice) on_choice(items[#items]) end)

      run(single_select_params())

      assert.equals(1, #notices)
      assert.equals("info", notices[1].level)
    end)

    it("stays quiet when the question is answered", function()
      stub_select(function(items, _, on_choice) on_choice(items[1]) end)

      run(single_select_params())

      assert.same({}, notices)
    end)
  end)
end)

describe("acp.elicitation rendering", function()
  local Elicitation = require("avante.acp.elicitation")

  describe("wrapping", function()
    it("wraps long text on word boundaries", function()
      local text = "Which approach should I take for the refactor, given that the module is shared?"
      local lines = Elicitation._wrap_text(text, 30)

      assert.is_true(#lines > 1)
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 30)
      end
      assert.equals(text, table.concat(lines, " "))
    end)

    it("never splits a word", function()
      local lines = Elicitation._wrap_text("supercalifragilistic short", 10)

      assert.equals("supercalifragilistic", lines[1])
    end)

    it("preserves explicit newlines as paragraphs", function()
      local lines = Elicitation._wrap_text("one\n\ntwo", 40)

      assert.same({ "one", "", "two" }, lines)
    end)

    it("returns nothing for empty input", function()
      assert.same({}, Elicitation._wrap_text("", 40))
      assert.same({}, Elicitation._wrap_text(nil, 40))
    end)
  end)

  describe("question text", function()
    it("prefers the message over the short header for a single question", function()
      -- claude sends the question in `message` and a short header in `title`;
      -- showing the header instead loses the actual question.
      local question, header = Elicitation._question_text(
        { title = "Colour" },
        "Do you prefer red or blue?"
      )

      assert.equals("Do you prefer red or blue?", question)
      assert.equals("Colour", header)
    end)

    it("prefers the field description for a multi-question form", function()
      local question = Elicitation._question_text(
        { title = "Colour", description = "Which colour?" },
        "Please answer the following questions."
      )

      assert.equals("Which colour?", question)
    end)

    it("does not repeat the header when it equals the question", function()
      local question, header = Elicitation._question_text({ title = "Same" }, "Same")

      assert.equals("Same", question)
      assert.is_nil(header)
    end)
  end)

  describe("float contents", function()
    local long = "Should I rewrite the module from scratch, or apply a targeted patch that keeps the existing structure intact?"

    it("puts the full question in the body, wrapped", function()
      local choices = Elicitation._build_choices(
        { type = "string", oneOf = { { const = "Rewrite" }, { const = "Patch" } } },
        false
      )
      local lines = Elicitation._build_lines(long, nil, choices, 40)

      -- Every word of the question survives, across however many lines.
      local body = table.concat(lines, " ")
      for word in long:gmatch("%S+") do
        assert.is_not_nil(body:find(word, 1, true), "missing word: " .. word)
      end
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 46)
      end
    end)

    it("numbers each choice and reports its line", function()
      local choices = Elicitation._build_choices(
        { type = "string", oneOf = { { const = "A" }, { const = "B" } } },
        false
      )
      local lines, choice_lines = Elicitation._build_lines("Q?", nil, choices, 40)

      -- 2 options + Skip
      assert.equals(3, #choice_lines)
      assert.is_not_nil(lines[choice_lines[1]]:find("1. A", 1, true))
      assert.is_not_nil(lines[choice_lines[2]]:find("2. B", 1, true))
      assert.is_not_nil(lines[choice_lines[3]]:find("Skip", 1, true))
    end)

    it("wraps option descriptions under their option", function()
      local choices = Elicitation._build_choices({
        type = "string",
        oneOf = {
          { const = "A", description = "A fairly long explanation of what this option actually does" },
        },
      }, false)
      local lines = Elicitation._build_lines("Q?", nil, choices, 40)

      local body = table.concat(lines, "\n")
      assert.is_not_nil(body:find("explanation", 1, true))
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 46)
      end
    end)

    it("includes the header above the question when present", function()
      local choices = Elicitation._build_choices({ type = "string", oneOf = {} }, false)
      local lines = Elicitation._build_lines("The question", "Header", choices, 40)

      assert.equals("Header", lines[1])
      assert.equals("The question", lines[3])
    end)

    it("offers a custom entry only when the schema has one", function()
      local with = Elicitation._build_choices({ type = "string", oneOf = {} }, true)
      local without = Elicitation._build_choices({ type = "string", oneOf = {} }, false)

      assert.equals(2, #with) -- custom + skip
      assert.equals(1, #without) -- skip only
    end)
  end)
end)
