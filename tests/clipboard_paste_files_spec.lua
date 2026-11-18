describe("clipboard.paste_files", function()
  local Clipboard
  local added
  local previous_avante_module
  local tmpdir

  before_each(function()
    added = {}
    previous_avante_module = package.loaded["avante"]
    package.loaded["avante"] = {
      get = function()
        return {
          file_selector = {
            add_selected_file = function(_, path) table.insert(added, path) end,
          },
        }
      end,
    }
    package.loaded["avante.clipboard"] = nil
    Clipboard = require("avante.clipboard")

    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    vim.fn.writefile({ "a" }, tmpdir .. "/a.lua")
    vim.fn.writefile({ "b" }, tmpdir .. "/b c.lua")
  end)

  after_each(function()
    package.loaded["avante"] = previous_avante_module
    package.loaded["avante.clipboard"] = nil
    vim.fn.delete(tmpdir, "rf")
  end)

  it("adds every pasted existing path", function()
    assert.is_true(Clipboard.paste_files({ tmpdir .. "/a.lua", tmpdir .. "/b c.lua", "" }))
    assert.are.same(2, #added)
  end)

  it("accepts file:// URIs and quoted paths", function()
    assert.is_true(Clipboard.paste_files({ vim.uri_from_fname(tmpdir .. "/b c.lua"), "'" .. tmpdir .. "/a.lua'" }))
    assert.are.same(2, #added)
  end)

  it("ignores pastes that are not only existing paths", function()
    assert.is_false(Clipboard.paste_files({ tmpdir .. "/a.lua", "some text" }))
    assert.is_false(Clipboard.paste_files({ "" }))
    assert.are.same(0, #added)
  end)
end)
