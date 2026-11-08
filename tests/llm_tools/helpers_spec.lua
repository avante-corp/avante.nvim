local LlmToolHelpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")
local stub = require("luassert.stub")

describe("has_permission_to_access", function()
  local test_dir = "/tmp/test_llm_tools_helpers"

  before_each(function()
    os.execute("mkdir -p " .. test_dir)
    -- create .gitignore file with test.idx file
    os.execute("rm " .. test_dir .. "/.gitignore 2>/dev/null")
    local gitignore_file = io.open(test_dir .. "/.gitignore", "w")
    if gitignore_file then
      gitignore_file:write("test.txt\n")
      gitignore_file:write("data\n")
      gitignore_file:close()
    end
    stub(Utils, "get_project_root", function() return test_dir end)
  end)

  after_each(function() os.execute("rm -rf " .. test_dir) end)

  it("Basic ignored and not ignored", function()
    local abs_path
    abs_path = test_dir .. "/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/test1.txt"
    assert.is_true(LlmToolHelpers.has_permission_to_access(abs_path))
  end)

  it("Ignore files inside directories", function()
    local abs_path
    abs_path = test_dir .. "/data/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/data/test1.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))
  end)

  it("Do not ignore files with just similar paths", function()
    local abs_path
    abs_path = test_dir .. "/data_test/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/data_test/test1.txt"
    assert.is_true(LlmToolHelpers.has_permission_to_access(abs_path))
  end)

  it("Rejects paths that only share the project root prefix", function()
    assert.is_false(LlmToolHelpers.has_permission_to_access(test_dir .. "-evil/test1.txt"))
    assert.is_false(LlmToolHelpers.has_permission_to_access(test_dir .. "2/test1.txt"))
  end)

  it(
    "Rejects an empty allowed root",
    function() assert.is_false(LlmToolHelpers.is_path_within("/tmp/anything", "")) end
  )
end)
