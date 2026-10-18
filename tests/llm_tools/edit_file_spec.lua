local stub = require("luassert.stub")
local Config = require("avante.config")
local Utils = require("avante.utils")
local EditFile = require("avante.llm_tools.edit_file")

describe("edit_file", function()
  it("passes the Morph API key to curl through a file only the user can read", function()
    Config.setup()
    local parse = stub(Utils.environment, "parse", function() return "morph-test-SECRET123" end)
    local headers_file, headers_mode, headers
    local system = stub(vim, "system", function(cmd, _, on_exit)
      headers_file = cmd[vim.fn.index(cmd, "-H") + 2]:match("^@(.+)")
      if headers_file then
        headers_mode = bit.band(vim.uv.fs_stat(headers_file).mode, 511)
        headers = table.concat(vim.fn.readfile(headers_file), "\n")
      end
      on_exit({ code = 7, stdout = "", stderr = "curl: (7) Failed to connect" })
    end)
    local target = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local x = 1" }, target)

    local err
    EditFile.func(
      { path = target, instructions = "rename x", code_edit = "local y = 1" },
      { on_complete = function(_, e) err = e end }
    )
    local completed = vim.wait(1000, function() return err ~= nil end)
    local cmd = system.calls[1] and system.calls[1].refs[1]
    parse:revert()
    system:revert()
    os.remove(target)

    assert.is_true(completed, "edit_file did not complete")
    assert.is_nil(vim.inspect(cmd):find("SECRET123", 1, true))
    assert.equals(tonumber("600", 8), headers_mode)
    assert.truthy(headers:find("Authorization: Bearer morph-test-SECRET123", 1, true))
    assert.is_nil(vim.uv.fs_stat(headers_file))
    -- The error repeats the curl command
    assert.is_nil(err:find("SECRET123", 1, true))
  end)
end)
