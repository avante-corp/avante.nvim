local mock = require("luassert.mock")
local stub = require("luassert.stub")

package.loaded["plenary.filetype"] = package.loaded["plenary.filetype"]
  or {
    detect = function(filepath) return vim.filetype.match({ filename = filepath }) end,
  }

local Filetype = package.loaded["plenary.filetype"]
local File = require("avante.utils.file")

describe("File", function()
  local test_file = "test.txt"
  local test_content = "test content\nline 2"

  -- Mock vim API
  local api_mock
  local uv_mock
  local readfile

  before_each(function()
    readfile = vim.fn.readfile
    -- Setup mocks
    api_mock = mock(vim.api, true)
    uv_mock = mock(vim.uv, true)
  end)

  after_each(function()
    vim.fn.readfile = readfile
    -- Clean up mocks
    mock.revert(api_mock)
    mock.revert(uv_mock)
  end)

  describe("read_content", function()
    it("should read file content", function()
      vim.fn.readfile = stub().returns({ "test content", "line 2" })

      local content = File.read_content(test_file)
      assert.equals(test_content, content)
      assert.stub(vim.fn.readfile).was_called_with(test_file)
    end)

    it("should return nil for non-existent file", function()
      vim.fn.readfile = stub().returns(nil)

      local content = File.read_content("nonexistent.txt")
      assert.is_nil(content)
    end)

    it("should use cache for subsequent reads", function()
      vim.fn.readfile = stub().returns({ "test content", "line 2" })
      local new_test_file = "test1.txt"

      -- First read
      local content1 = File.read_content(new_test_file)
      assert.equals(test_content, content1)

      -- Second read (should use cache)
      local content2 = File.read_content(new_test_file)
      assert.equals(test_content, content2)

      -- readfile should only be called once
      assert.stub(vim.fn.readfile).was_called(1)
    end)
  end)

  describe("exists", function()
    it("should return true for existing file", function()
      uv_mock.fs_stat.returns({ type = "file" })

      assert.is_true(File.exists(test_file))
      assert.stub(uv_mock.fs_stat).was_called_with(test_file)
    end)

    it("should return false for non-existent file", function()
      uv_mock.fs_stat.returns(nil)

      assert.is_false(File.exists("nonexistent.txt"))
    end)
  end)

  describe("write_atomically", function()
    before_each(function()
      uv_mock.fs_stat.returns({ mode = 33188 })
      uv_mock.os_getpid.returns(123)
      uv_mock.hrtime.returns(456)
      uv_mock.fs_open.returns(7)
      uv_mock.fs_write.returns(#test_content)
      uv_mock.fs_fsync.returns(true)
      uv_mock.fs_close.returns(true)
      uv_mock.fs_chmod.returns(true)
      uv_mock.fs_rename.returns(true)
      uv_mock.fs_unlink.returns(true)
    end)

    it("replaces the destination only after the temporary file is durable", function()
      local ok, err = File.write_atomically(test_file, test_content)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.stub(uv_mock.fs_open).was_called_with("test.txt.avante-123-456-1", "wx", 33188)
      assert.stub(uv_mock.fs_write).was_called_with(7, test_content, 0)
      assert.stub(uv_mock.fs_fsync).was_called_with(7)
      assert.stub(uv_mock.fs_close).was_called_with(7)
      assert.stub(uv_mock.fs_chmod).was_called_with("test.txt.avante-123-456-1", 33188)
      assert.stub(uv_mock.fs_rename).was_called_with("test.txt.avante-123-456-1", test_file)
    end)

    it("creates new files with permissions filtered by the process umask", function()
      uv_mock.fs_stat.returns(nil)

      local ok, err = File.write_atomically(test_file, test_content)

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

      local ok, err = File.write_atomically(test_file, test_content)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.stub(uv_mock.fs_open).was_called(2)
      assert.stub(uv_mock.fs_rename).was_called_with("test.txt.avante-123-456-2", test_file)
    end)

    it("leaves the destination untouched when writing the temporary file fails", function()
      uv_mock.fs_write.returns(nil, "disk full")

      local ok, err = File.write_atomically(test_file, test_content)

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
      Filetype.detect.returns("lua")
      devicons_mock.get_icon.returns("")

      -- Mock require for nvim-web-devicons
      local old_require = _G.require
      _G.require = function(module)
        if module == "nvim-web-devicons" then return devicons_mock end
        return old_require(module)
      end

      local icon = File.get_file_icon("test.lua")
      assert.equals("", icon)
      assert.stub(Filetype.detect).was_called_with("test.lua", {})
      assert.stub(devicons_mock.get_icon).was_called()

      _G.require = old_require
    end)

    it("should get icon using MiniIcons if available", function()
      _G.MiniIcons = {
        get = stub().returns("", "color", "name"),
      }

      Filetype.detect.returns("lua")

      local icon = File.get_file_icon("test.lua")
      assert.equals("", icon)
      assert.stub(Filetype.detect).was_called_with("test.lua", {})
      assert.stub(_G.MiniIcons.get).was_called_with("filetype", "lua")

      _G.MiniIcons = nil
    end)

    it("should handle unknown filetypes", function()
      Filetype.detect.returns(nil)
      devicons_mock.get_icon.returns("")

      -- Mock require for nvim-web-devicons
      local old_require = _G.require
      _G.require = function(module)
        if module == "nvim-web-devicons" then return devicons_mock end
        return old_require(module)
      end

      local icon = File.get_file_icon("unknown.xyz")
      assert.equals("", icon)

      _G.require = old_require
    end)
  end)
end)
