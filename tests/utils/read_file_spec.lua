local Utils = require("avante.utils")
local stub = require("luassert.stub")

describe("Reading exact file buffers", function()
  local dir, bufs, stat_stub, open_stub
  before_each(function()
    dir, bufs = vim.fn.tempname(), {}
    vim.fn.mkdir(dir .. "/root", "p")
  end)
  after_each(function()
    if stat_stub then
      stat_stub:revert()
      stat_stub = nil
    end
    if open_stub then
      open_stub:revert()
      open_stub = nil
    end
    for _, buf in ipairs(bufs) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(dir, "rf")
  end)

  local function buffer(path, text)
    local buf = vim.api.nvim_create_buf(true, false)
    table.insert(bufs, buf)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  end

  it("does not read a buffer whose name only starts with the requested filename", function()
    buffer(dir .. "/root/config.lua", "other file")
    local _, _, errname = Utils.read_file_from_buf_or_disk(dir .. "/root/config")
    assert.equals("ENOENT", errname)
  end)

  it("treats wildcard characters in filenames literally", function()
    buffer(dir .. "/root/config.lua", "other file")
    local _, _, errname = Utils.read_file_from_buf_or_disk(dir .. "/root/*.lua")
    assert.equals("ENOENT", errname)
    buffer(dir .. "/root/*.lua", "literal file")
    assert.same({ "literal file" }, Utils.read_file_from_buf_or_disk(dir .. "/root/*.lua"))
  end)

  it("rejects a directory even when an outside buffer has that path prefix", function()
    buffer(dir .. "/root-other/private.txt", "outside synthetic contents")
    local lines, err = Utils.read_file_from_buf_or_disk(dir .. "/root")
    assert.is_not_nil(err)
    assert.same({}, lines)
  end)

  it("reads unsaved changes through a symlink's canonical path", function()
    local real, alias = dir .. "/root/real.txt", dir .. "/root/alias.txt"
    vim.fn.writefile({ "disk" }, real)
    assert(vim.uv.fs_symlink(real, alias))
    buffer(alias, "unsaved buffer")
    assert.same({ "unsaved buffer" }, Utils.read_file_from_buf_or_disk(real))
  end)

  it("reads a named buffer before its first save", function()
    local path = dir .. "/root/new.txt"
    buffer(path, "new buffer")
    assert.same({ "new buffer" }, Utils.read_file_from_buf_or_disk(path))
  end)

  for _, filename in ipairs({ "new.txt", "*.lua" }) do
    it("reads an unsaved buffer through a symlinked directory: " .. filename, function()
      assert(vim.uv.fs_symlink(dir .. "/root", dir .. "/alias"))
      local path = dir .. "/alias/" .. filename
      buffer(path, "unsaved buffer")
      assert.same({ "unsaved buffer" }, Utils.read_file_from_buf_or_disk(path))
    end)
  end

  it("rejects special files without opening a potentially blocking stream", function()
    stat_stub = stub(vim.uv, "fs_stat").returns({ type = "fifo" })
    open_stub = stub(io, "open").invokes(function() error("special file must not be opened") end)
    local lines, err = Utils.read_file_from_buf_or_disk(dir .. "/pipe")
    assert.same({}, lines)
    assert.matches("non%-regular file", err)
    assert.stub(open_stub).was_not_called()
  end)

  it("reads disk content when no exact buffer is loaded", function()
    vim.fn.writefile({ "disk" }, dir .. "/root/file.txt")
    buffer(dir .. "/root/file.txt.backup", "other buffer")
    assert.same({ "disk", "" }, Utils.read_file_from_buf_or_disk(dir .. "/root/file.txt"))
  end)
end)
