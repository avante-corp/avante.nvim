local assert = require("luassert")
local mock = require("luassert.mock")
local stub = require("luassert.stub")
local Filesystem = require("avante.utils.filesystem")
local Filetype = vim.filetype

describe("Filesystem", function()
  local test_file = "test.txt"
  local test_content = "test content\nline 2"

  -- Mock vim API
  local uv_mock
  local writefile

  before_each(function()
    writefile = vim.fn.writefile
    -- Setup mocks
    uv_mock = mock(vim.uv, true)
  end)

  after_each(function()
    vim.fn.writefile = writefile
    -- Clean up mocks
    mock.revert(uv_mock)
  end)

  describe("write_atomically", function()
    before_each(function()
      uv_mock.fs_stat.returns({ mode = 33188 })
      uv_mock.os_getpid.returns(123)
      uv_mock.hrtime.returns(456)
      uv_mock.fs_open.returns(7)
      uv_mock.fs_close.returns(true)
      uv_mock.fs_chmod.returns(true)
      uv_mock.fs_rename.returns(true)
      uv_mock.fs_unlink.returns(true)
      vim.fn.writefile = stub().returns(0)
    end)

    it("replaces the destination only after the temporary file is durable", function()
      local ok, err = Filesystem.write_atomically(test_file, test_content)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.stub(uv_mock.fs_open).was_called_with("test.txt.avante-123-456-1", "wx", 33188)
      assert.stub(uv_mock.fs_close).was_called_with(7)
      assert.stub(uv_mock.fs_chmod).was_called_with("test.txt.avante-123-456-1", 33188)
      assert.stub(vim.fn.writefile).was_called_with(test_content, "test.txt.avante-123-456-1", "s")
      assert.stub(uv_mock.fs_rename).was_called_with("test.txt.avante-123-456-1", test_file)
    end)

    it("creates new files with permissions filtered by the process umask", function()
      uv_mock.fs_stat.returns(nil)

      local ok, err = Filesystem.write_atomically(test_file, test_content)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.stub(uv_mock.fs_open).was_called_with("test.txt.avante-123-456-1", "wx", 438)
      assert.stub(uv_mock.fs_chmod).was_not_called()
    end)

    it("retries with a new exclusive temporary path after a collision", function()
      local attempts = 0
      uv_mock.fs_open.invokes(function()
        attempts = attempts + 1
        if attempts == 1 then return nil, "file exists" end
        return 7
      end)

      local ok, err = Filesystem.write_atomically(test_file, test_content)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.stub(uv_mock.fs_open).was_called(2)
      assert.stub(uv_mock.fs_rename).was_called_with("test.txt.avante-123-456-2", test_file)
    end)

    it("leaves the destination untouched when writing the temporary file fails", function()
      vim.fn.writefile.invokes(function() error("disk full") end)

      local ok, err = Filesystem.write_atomically(test_file, test_content)

      assert.is_nil(ok)
      assert.matches("disk full", err)
      assert.stub(uv_mock.fs_unlink).was_called_with("test.txt.avante-123-456-1")
      assert.stub(uv_mock.fs_rename).was_not_called()
    end)
  end)

  describe("get_file_icon", function()
    local devicons_mock

    before_each(function()
      Filetype = mock(Filetype, true)
      -- Prepare devicons mock
      devicons_mock = {
        get_icon = stub().returns(""),
      }
      -- Reset _G.MiniIcons
      _G.MiniIcons = nil
    end)

    after_each(function() mock.revert(Filetype) end)

    it("should get icon using nvim-web-devicons", function()
      Filetype.match.returns("lua")
      devicons_mock.get_icon.returns("")

      -- Mock require for nvim-web-devicons
      local old_require = _G.require
      _G.require = function(module)
        if module == "nvim-web-devicons" then return devicons_mock end
        return old_require(module)
      end

      local icon = Filesystem.get_file_icon("test.lua")
      assert.equals("", icon)
      assert.stub(Filetype.match).was_called_with({ filename = "test.lua" })
      assert.stub(devicons_mock.get_icon).was_called()

      _G.require = old_require
    end)

    it("should get icon using MiniIcons if available", function()
      _G.MiniIcons = {
        get = stub().returns("", "color", "name"),
      }

      Filetype.match.returns("lua")

      local icon = Filesystem.get_file_icon("test.lua")
      assert.equals("", icon)
      assert.stub(Filetype.match).was_called_with({ filename = "test.lua" })
      assert.stub(_G.MiniIcons.get).was_called_with("filetype", "lua")

      _G.MiniIcons = nil
    end)

    it("should handle unknown filetypes", function()
      Filetype.match.returns(nil)
      devicons_mock.get_icon.returns("")

      -- Mock require for nvim-web-devicons
      local old_require = _G.require
      _G.require = function(module)
        if module == "nvim-web-devicons" then return devicons_mock end
        return old_require(module)
      end

      local icon = Filesystem.get_file_icon("unknown.xyz")
      assert.equals("", icon)

      _G.require = old_require
    end)
  end)
end)

describe("project membership", function()
  local Root = require("avante.utils.root")
  local root = vim.fs.joinpath(vim.uv.os_tmpdir(), "avante-project")
  local get_root

  before_each(function() get_root = stub(Root, "get").returns(root .. "/") end)
  after_each(function() get_root:revert() end)

  it("includes the root and descendants but excludes sibling prefixes", function()
    assert.is_true(Filesystem.is_in_project(root))
    assert.is_true(Filesystem.is_in_project(root .. "/src/file.lua"))
    assert.is_false(Filesystem.is_in_project(root .. "-other/file.lua"))
    assert.is_false(Filesystem.is_in_project(root .. "/../outside.lua"))
  end)
end)

describe("path display normalization", function()
  local root = vim.fs.joinpath(vim.uv.os_homedir(), "avante-project")

  it("formats project paths while preserving literal filenames and URIs", function()
    assert.equals("src/file.lua", Filesystem.normalize_display(root .. "/src/../src/file.lua", root .. "/."))
    assert.equals(".", Filesystem.normalize_display(root, root))
    assert.equals("$HOME.lua", Filesystem.normalize_display(root .. "/$HOME.lua", root))
    assert.equals("term://buffer//123", Filesystem.normalize_display("term://buffer//123", root))
  end)

  it("shortens paths outside the project without confusing sibling prefixes", function()
    assert.equals("~/avante-project-other/file.lua", Filesystem.normalize_display(root .. "-other/file.lua", root))
    assert.equals("src/file.lua", Filesystem.normalize_display("src/file.lua", root))
  end)
end)

describe("relative paths", function()
  it("should remove base directory from filepath", function()
    local test_filepath = "/path/to/project/src/file.lua"
    local test_base_dir = "/path/to/project"
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("src/file.lua", result)
  end)

  it("should handle trailing dot-slash in base_dir", function()
    local test_filepath = "/path/to/project/src/file.lua"
    local test_base_dir = "/path/to/project/."
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("src/file.lua", result)
  end)

  it("should handle trailing dot-slash in filepath", function()
    local test_filepath = "/path/to/project/src/."
    local test_base_dir = "/path/to/project"
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("src", result)
  end)

  it("should handle both having trailing dot-slash", function()
    local test_filepath = "/path/to/project/src/."
    local test_base_dir = "/path/to/project/."
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("src", result)
  end)

  it("should return the filepath when base_dir is not a prefix", function()
    local test_filepath = "/path/to/project/src/file.lua"
    local test_base_dir = "/different/path"
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("/path/to/project/src/file.lua", result)
  end)

  it("should handle identical paths", function()
    local test_filepath = "/path/to/project"
    local test_base_dir = "/path/to/project"
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals(".", result)
  end)

  it("should handle empty strings", function()
    local result = Filesystem.relative("", "", false)
    assert.equals(".", result)
  end)

  it("should preserve trailing slash in filepath", function()
    local test_filepath = "/path/to/project/src/"
    local test_base_dir = "/path/to/project"
    local result = Filesystem.relative(test_base_dir, test_filepath, false)
    assert.equals("src/", result)
  end)
end)

describe("copy_dir", function()
  local root, source, destination

  before_each(function()
    root = vim.fn.tempname()
    source, destination = root .. "/source", root .. "/destination"
    vim.fn.mkdir(source .. "/nested/empty", "p")
    vim.fn.writefile("one\r\ntwo\0three", source .. "/nested/file")
    vim.fn.writefile("hidden", source .. "/.hidden")
    vim.fn.mkdir(source .. "/.hidden-dir", "p")
    vim.fn.writefile("hidden child", source .. "/.hidden-dir/file")
  end)

  after_each(function() vim.fn.delete(root, "rf") end)

  it("copies nested and empty directories and overwrites existing files", function()
    vim.fn.mkdir(destination .. "/nested", "p")
    vim.fn.writefile("old", destination .. "/nested/file")
    assert.is_true(Filesystem.copy_dir(source, destination))
    assert.equals("one\r\ntwo\0three", vim.fn.readblob(destination .. "/nested/file"))
    assert.equals(1, vim.fn.isdirectory(destination .. "/nested/empty"))
    assert.equals("hidden", vim.fn.readblob(destination .. "/.hidden"))
  end)

  it("skips hidden files and directories when requested", function()
    assert.is_true(Filesystem.copy_dir(source, destination, { hidden = false }))
    assert.is_nil(vim.uv.fs_stat(destination .. "/.hidden"))
    assert.is_nil(vim.uv.fs_stat(destination .. "/.hidden-dir"))
    assert.equals("one\r\ntwo\0three", vim.fn.readblob(destination .. "/nested/file"))
  end)

  it("rejects copying into itself, including through a directory symlink", function()
    assert(vim.uv.fs_symlink(source, root .. "/alias", { dir = true }))
    for _, target in ipairs({ source .. "/new/copy", root .. "/alias/new/copy" }) do
      if vim.fn.has("win32") == 1 then target = target:upper() end
      local ok, err = Filesystem.copy_dir(source, target)
      assert.is_nil(ok)
      assert.is_string(err)
      assert.is_nil(vim.uv.fs_stat(source .. "/new"))
    end
  end)

  it("reports a nested directory scan failure", function()
    local scandir = vim.uv.fs_scandir
    local scan_stub = stub(vim.uv, "fs_scandir", function(path)
      if path == source .. "/nested" then return nil, "EACCES: permission denied" end
      return scandir(path)
    end)
    local ok, err = Filesystem.copy_dir(source, destination)
    scan_stub:revert()
    assert.is_nil(ok)
    assert.matches("EACCES: permission denied", err)
  end)

  it("reports directory symlink cycles instead of recursing forever", function()
    assert(vim.uv.fs_symlink(source, source .. "/nested/loop", { dir = true }))
    local ok, err = Filesystem.copy_dir(source, destination)
    assert.is_nil(ok)
    assert.matches("Directory cycle", err)
  end)
end)
