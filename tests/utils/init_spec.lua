local Utils = require("avante.utils")

describe("Utils", function()
  describe("trim", function()
    it("should trim prefix", function() assert.equals("test", Utils.trim("prefix_test", { prefix = "prefix_" })) end)

    it("should trim suffix", function() assert.equals("test", Utils.trim("test_suffix", { suffix = "_suffix" })) end)

    it(
      "should trim both prefix and suffix",
      function() assert.equals("test", Utils.trim("prefix_test_suffix", { prefix = "prefix_", suffix = "_suffix" })) end
    )

    it(
      "should return original string if no match",
      function() assert.equals("test", Utils.trim("test", { prefix = "xxx", suffix = "yyy" })) end
    )
  end)

  describe("url_join", function()
    it("should join url parts correctly", function()
      assert.equals("http://example.com/path", Utils.url_join("http://example.com", "path"))
      assert.equals("http://example.com/path", Utils.url_join("http://example.com/", "/path"))
      assert.equals("http://example.com/path/to", Utils.url_join("http://example.com", "path", "to"))
      assert.equals("http://example.com/path", Utils.url_join("http://example.com/", "/path/"))
    end)

    it("should handle empty parts", function()
      assert.equals("http://example.com", Utils.url_join("http://example.com", ""))
      assert.equals("http://example.com", Utils.url_join("http://example.com", nil))
    end)
  end)

  describe("is_type", function()
    it("should check basic types correctly", function()
      assert.is_true(Utils.is_type("string", "test"))
      assert.is_true(Utils.is_type("number", 123))
      assert.is_true(Utils.is_type("boolean", true))
      assert.is_true(Utils.is_type("table", {}))
      assert.is_true(Utils.is_type("function", function() end))
      assert.is_true(Utils.is_type("nil", nil))
    end)

    it("should check list type correctly", function()
      assert.is_true(Utils.is_type("list", { 1, 2, 3 }))
      assert.is_false(Utils.is_type("list", { a = 1, b = 2 }))
    end)

    it("should check map type correctly", function()
      assert.is_true(Utils.is_type("map", { a = 1, b = 2 }))
      assert.is_false(Utils.is_type("map", { 1, 2, 3 }))
    end)
  end)

  describe("get_indentation", function()
    it("should get correct indentation", function()
      assert.equals("  ", Utils.get_indentation("  test"))
      assert.equals("\t", Utils.get_indentation("\ttest"))
      assert.equals("", Utils.get_indentation("test"))
    end)

    it("should handle empty or nil input", function()
      assert.equals("", Utils.get_indentation(""))
      assert.equals("", Utils.get_indentation(nil))
    end)
  end)

  describe("trime_space", function()
    it("should remove indentation correctly", function()
      assert.equals("test", Utils.trim_space("  test"))
      assert.equals("test", Utils.trim_space("\ttest"))
      assert.equals("test", Utils.trim_space("test"))
    end)

    it("should handle empty or nil input", function()
      assert.equals("", Utils.trim_space(""))
      assert.equals(nil, Utils.trim_space(nil))
    end)
  end)

  describe("is_first_letter_uppercase", function()
    it("should detect uppercase first letter", function()
      assert.is_true(Utils.is_first_letter_uppercase("Test"))
      assert.is_true(Utils.is_first_letter_uppercase("ABC"))
    end)

    it("should detect lowercase first letter", function()
      assert.is_false(Utils.is_first_letter_uppercase("test"))
      assert.is_false(Utils.is_first_letter_uppercase("abc"))
    end)
  end)

  describe("extract_mentions", function()
    it("should extract @codebase mention", function()
      local result = Utils.extract_mentions("test @codebase")
      assert.equals("test ", result.new_content)
      assert.is_true(result.enable_project_context)
      assert.is_false(result.enable_diagnostics)
    end)

    it("should extract @diagnostics mention", function()
      local result = Utils.extract_mentions("test @diagnostics")
      assert.equals("test @diagnostics", result.new_content)
      assert.is_false(result.enable_project_context)
      assert.is_true(result.enable_diagnostics)
    end)

    it("should handle multiple mentions", function()
      local result = Utils.extract_mentions("test @codebase @diagnostics")
      assert.equals("test  @diagnostics", result.new_content)
      assert.is_true(result.enable_project_context)
      assert.is_true(result.enable_diagnostics)
    end)
  end)

  describe("get_mentions", function()
    it("should return valid mentions", function()
      local mentions = Utils.get_mentions()
      assert.equals("codebase", mentions[1].command)
      assert.equals("diagnostics", mentions[2].command)
    end)
  end)

  describe("trim_think_content", function()
    it("should remove think content", function()
      local input = "<think>this should be removed</think> Hello World"
      assert.equals(" Hello World", Utils.trim_think_content(input))
    end)

    it("The think tag that is not in the prefix should not be deleted.", function()
      local input = "Hello <think>this should not be removed</think> World"
      assert.equals("Hello <think>this should not be removed</think> World", Utils.trim_think_content(input))
    end)

    it("should handle multiple think blocks", function()
      local input = "<think>first</think>middle<think>second</think>"
      assert.equals("middle<think>second</think>", Utils.trim_think_content(input))
    end)

    it("should handle empty think blocks", function()
      local input = "<think></think>testtest"
      assert.equals("testtest", Utils.trim_think_content(input))
    end)

    it("should handle empty think blocks", function()
      local input = "test<think></think>test"
      assert.equals("test<think></think>test", Utils.trim_think_content(input))
    end)

    it("should handle input without think blocks", function()
      local input = "just normal text"
      assert.equals("just normal text", Utils.trim_think_content(input))
    end)
  end)

  describe("debounce", function()
    it("should debounce function calls", function()
      local count = 0
      local debounced = Utils.debounce(function() count = count + 1 end, 100)

      -- Call multiple times in quick succession
      debounced()
      debounced()
      debounced()

      -- Should not have executed yet
      assert.equals(0, count)

      -- Wait for debounce timeout
      vim.wait(200, function() return false end)

      -- Should have executed once
      assert.equals(1, count)
    end)

    it("should cancel previous timer on new calls", function()
      local count = 0
      local debounced = Utils.debounce(function(c) count = c end, 100)

      -- First call
      debounced(1)

      -- Wait partial time
      vim.wait(50, function() return false end)

      -- Second call should cancel first
      debounced(233)

      -- Count should still be 0
      assert.equals(0, count)

      -- Wait for timeout
      vim.wait(200, function() return false end)

      -- Should only execute the latest once
      assert.equals(233, count)
    end)

    it("should pass arguments correctly", function()
      local result
      local debounced = Utils.debounce(function(x, y) result = x + y end, 100)

      debounced(2, 3)

      -- Wait for timeout
      vim.wait(200, function() return false end)

      assert.equals(5, result)
    end)
  end)

  describe("fuzzy_match", function()
    it("should match exact lines", function()
      local lines = { "test", "test2", "test3", "test4" }
      local start_line, end_line = Utils.fuzzy_match(lines, { "test2", "test3" })
      assert.equals(2, start_line)
      assert.equals(3, end_line)
    end)

    it("should match lines with suffix", function()
      local lines = { "test", "test2", "test3", "test4" }
      local start_line, end_line = Utils.fuzzy_match(lines, { "test2 \t", "test3" })
      assert.equals(2, start_line)
      assert.equals(3, end_line)
    end)

    it("should match lines with space", function()
      local lines = { "test", "test2", "test3", "test4" }
      local start_line, end_line = Utils.fuzzy_match(lines, { "test2 ", "  test3" })
      assert.equals(2, start_line)
      assert.equals(3, end_line)
    end)
  end)
end)
