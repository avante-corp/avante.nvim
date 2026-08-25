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
end)
