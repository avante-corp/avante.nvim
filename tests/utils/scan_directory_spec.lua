local Utils = require("avante.utils")
local stub = require("luassert.stub")

describe("directory scanning", function()
  local root, executable, notify

  before_each(function()
    root = vim.fn.tempname() .. " space ' $HOME"
    vim.fn.mkdir(root, "p")
    assert.equals(0, vim.system({ "git", "init", "-q", root }):wait().code)
    vim.fn.writefile({ "hello" }, root .. "/literal%20name.txt")
    executable = stub(vim.fn, "executable", function(cmd) return cmd == "git" and 1 or 0 end)
    notify = stub(Utils, "error")
  end)

  after_each(function()
    executable:revert()
    notify:revert()
    vim.fn.delete(root, "rf")
  end)

  it("handles literal Git paths, depth limits and parent directories", function()
    vim.fn.mkdir(root .. "/nested", "p")
    vim.fn.writefile({ "nested" }, root .. "/nested/file.txt")
    assert.same(
      { root, root .. "/literal%20name.txt" },
      Utils.scan_directory({ directory = root, max_depth = 1, add_dirs = true })
    )
    assert.stub(notify).was_not_called()
  end)

  it("reports command failures instead of treating their output as files", function()
    local system = stub(vim, "system").returns({
      wait = function() return { code = 2, stdout = "not-a-file\n", stderr = "permission denied" } end,
    })
    local files = Utils.scan_directory({ directory = root })
    system:revert()
    assert.same({}, files)
    assert.stub(notify).was_called()
  end)

  it("treats ripgrep's no-match status as an empty directory", function()
    executable.invokes(function(cmd) return cmd == "rg" and 1 or 0 end)
    local system = stub(vim, "system").returns({
      wait = function() return { code = 1, stdout = "", stderr = "" } end,
    })
    local files = Utils.scan_directory({ directory = root })
    system:revert()
    assert.same({}, files)
    assert.stub(notify).was_not_called()
  end)
end)
