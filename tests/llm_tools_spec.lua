local stub = require("luassert.stub")
local LlmTools = require("avante.llm_tools")
local LlmToolHelpers = require("avante.llm_tools.helpers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local ls = require("avante.llm_tools.ls")
local grep = require("avante.llm_tools.grep")
local glob = require("avante.llm_tools.glob")
local view = require("avante.llm_tools.view")
local bash = require("avante.llm_tools.bash")

describe("llm_tools", function()
  local test_dir, test_file

  before_each(function()
    Config.setup()
    test_dir = vim.fn.tempname()
    test_file = test_dir .. "/test.txt"
    stub(LlmToolHelpers, "confirm", function(_msg, cb) return cb(true) end)
    stub(LlmToolHelpers, "already_in_context", function() return false end)
    -- 创建测试目录和文件
    os.execute("mkdir -p " .. test_dir)
    vim.fn.system({ "git", "init", "-q", "-b", "main", test_dir })
    local file = io.open(test_file, "w")
    if not file then error("Failed to create test file") end
    file:write("test content")
    file:close()
    os.execute("mkdir -p " .. test_dir .. "/test_dir1")
    file = io.open(test_dir .. "/test_dir1/test1.txt", "w")
    if not file then error("Failed to create test file") end
    file:write("test1 content")
    file:close()
    os.execute("mkdir -p " .. test_dir .. "/test_dir2")
    file = io.open(test_dir .. "/test_dir2/test2.txt", "w")
    if not file then error("Failed to create test file") end
    file:write("test2 content")
    file:close()
    file = io.open(test_dir .. "/.gitignore", "w")
    if not file then error("Failed to create test file") end
    file:write("test_dir2/")
    file:close()

    -- Mock get_project_root
    stub(Utils, "get_project_root", function() return test_dir end)
  end)

  after_each(function()
    -- 清理测试目录
    vim.fn.delete(test_dir, "rf")
    -- 恢复 mock
    Utils.get_project_root:revert()
    LlmToolHelpers.confirm:revert()
    LlmToolHelpers.already_in_context:revert()
  end)

  describe("web search tools", function()
    it("exposes one tool per search engine", function()
      local names = LlmTools.get_tool_names()

      local tools_list = {
        "dispatch_agent",
        "glob",
        "rag_search",
        "run_python",
        "git_diff",
        "git_commit",
        "ls",
        "grep",
        "delete_tool_use_messages",
        "read_todos",
        "write_todos",
        "read_file_toplevel_symbols",
        "str_replace",
        "view",
        "write_to_file",
        "insert",
        "undo_edit",
        "read_global_file",
        "write_global_file",
        "move_path",
        "copy_path",
        "delete_path",
        "create_dir",
        "think",
        "get_diagnostics",
        "bash",
        "attempt_completion",
        "edit_file",
        "web_search_tavily",
        "fetch",
        "read_definitions",
      }

      assert.are.same(tools_list, names)
    end)
  end)

  describe("ls", function()
    it("should list files in directory", function()
      local result, err = ls({ path = ".", max_depth = 1 }, {})
      assert.is_nil(err)
      assert.falsy(result:find("avante.nvim"))
      assert.truthy(result:find("test.txt"))
      assert.falsy(result:find("test1.txt"))
    end)
    it("should list files in directory with depth", function()
      local result, err = ls({ path = ".", max_depth = 2 }, {})
      assert.is_nil(err)
      assert.falsy(result:find("avante.nvim"))
      assert.truthy(result:find("test.txt"))
      assert.truthy(result:find("test1.txt"))
    end)
    it("should list files respecting gitignore", function()
      local result, err = ls({ path = ".", max_depth = 2 }, {})
      assert.is_nil(err)
      assert.falsy(result:find("avante.nvim"))
      assert.truthy(result:find("test.txt"))
      assert.truthy(result:find("test1.txt"))
      assert.falsy(result:find("test2.txt"))
    end)
  end)

  describe("view", function()
    it("should read file content", function()
      view({ path = "test.txt" }, {
        on_complete = function(content, err)
          assert.is_nil(err)
          assert.equals("test content", vim.json.decode(content).content)
        end,
      })
    end)

    it("should return error for non-existent file", function()
      view({ path = "non_existent.txt" }, {
        on_complete = function(content, err)
          assert.truthy(err)
          assert.equals("", content)
        end,
      })
    end)

    it("should read directory content", function()
      view({ path = test_dir }, {
        on_complete = function(content, err)
          assert.is_nil(err)
          assert.truthy(content:find("test.txt"))
          assert.truthy(content:find("test content"))
        end,
      })
    end)
  end)

  describe("create_dir", function()
    it("should create new directory", function()
      LlmTools.create_dir({ path = "new_dir" }, {
        session_ctx = {},
        on_complete = function(success, err)
          assert.is_nil(err)
          assert.is_true(success)

          local dir_exists = io.open(test_dir .. "/new_dir", "r") ~= nil
          assert.is_true(dir_exists)
        end,
      })
    end)
  end)

  describe("delete_path", function()
    it("should delete existing file", function()
      LlmTools.delete_path({ path = "test.txt" }, {
        session_ctx = {},
        on_complete = function(success, err)
          assert.is_nil(err)
          assert.is_true(success)

          local file_exists = io.open(test_file, "r") ~= nil
          assert.is_false(file_exists)
        end,
      })
    end)
  end)

  describe("grep", function()
    local original_exepath = vim.fn.exepath

    after_each(function() vim.fn.exepath = original_exepath end)

    it("should search using ripgrep when available", function()
      -- Mock exepath to return rg path
      vim.fn.exepath = function(cmd)
        if cmd == "rg" then return original_exepath("rg") end
        return ""
      end

      -- Create a test file with searchable content
      local file = io.open(test_dir .. "/searchable.txt", "w")
      if not file then error("Failed to create test file") end
      file:write("this is searchable content")
      file:close()

      file = io.open(test_dir .. "/nothing.txt", "w")
      if not file then error("Failed to create test file") end
      file:write("this is nothing")
      file:close()

      local result, err = grep({ path = ".", query = "Searchable", case_sensitive = false }, {})
      assert.is_nil(err)
      assert.truthy(result:find("searchable.txt"))
      assert.falsy(result:find("nothing.txt"))

      local result2, err2 = grep({ path = ".", query = "searchable", case_sensitive = true }, {})
      assert.is_nil(err2)
      assert.truthy(result2:find("searchable.txt"))
      assert.falsy(result2:find("nothing.txt"))

      local result3, err3 = grep({ path = ".", query = "Searchable", case_sensitive = true }, {})
      assert.is_nil(err3)
      assert.falsy(result3:find("searchable.txt"))
      assert.falsy(result3:find("nothing.txt"))

      local result4, err4 = grep({ path = ".", query = "searchable", case_sensitive = false }, {})
      assert.is_nil(err4)
      assert.truthy(result4:find("searchable.txt"))
      assert.falsy(result4:find("nothing.txt"))

      local result5, err5 = grep({
        path = ".",
        query = "searchable",
        case_sensitive = false,
        exclude_pattern = "search*",
      }, {})
      assert.is_nil(err5)
      assert.falsy(result5:find("searchable.txt"))
      assert.falsy(result5:find("nothing.txt"))
    end)

    it("should search using ag when rg is not available", function()
      -- Mock exepath to return ag path
      vim.fn.exepath = function(cmd)
        if cmd == "ag" then return original_exepath("ag") end
        return ""
      end

      -- Create a test file specifically for ag
      local file = io.open(test_dir .. "/ag_test.txt", "w")
      if not file then error("Failed to create test file") end
      file:write("content for ag test")
      file:close()

      local result, err = grep({ path = ".", query = "ag test" }, {})
      assert.is_nil(err)
      assert.is_string(result)
      assert.truthy(result:find("ag_test.txt"))
    end)

    it("should search using grep when rg and ag are not available", function()
      -- Mock exepath to return grep path
      vim.fn.exepath = function(cmd)
        if cmd == "grep" then return original_exepath("grep") end
        return ""
      end

      -- Create a test file with searchable content
      local file = io.open(test_dir .. "/searchable.txt", "w")
      if not file then error("Failed to create test file") end
      file:write("this is searchable content")
      file:close()

      file = io.open(test_dir .. "/nothing.txt", "w")
      if not file then error("Failed to create test file") end
      file:write("this is nothing")
      file:close()

      local result, err = grep({ path = ".", query = "Searchable", case_sensitive = false }, {})
      assert.is_nil(err)
      assert.truthy(result:find("searchable.txt"))
      assert.falsy(result:find("nothing.txt"))

      local result2, err2 = grep({ path = ".", query = "searchable", case_sensitive = true }, {})
      assert.is_nil(err2)
      assert.truthy(result2:find("searchable.txt"))
      assert.falsy(result2:find("nothing.txt"))

      local result3, err3 = grep({ path = ".", query = "Searchable", case_sensitive = true }, {})
      assert.is_nil(err3)
      assert.falsy(result3:find("searchable.txt"))
      assert.falsy(result3:find("nothing.txt"))

      local result4, err4 = grep({ path = ".", query = "searchable", case_sensitive = false }, {})
      assert.is_nil(err4)
      assert.truthy(result4:find("searchable.txt"))
      assert.falsy(result4:find("nothing.txt"))

      local result5, err5 = grep({
        path = ".",
        query = "searchable",
        case_sensitive = false,
        exclude_pattern = "search*",
      }, {})
      assert.is_nil(err5)
      assert.falsy(result5:find("searchable.txt"))
      assert.falsy(result5:find("nothing.txt"))
    end)

    it("should return error when no search tool is available", function()
      -- Mock exepath to return nothing
      vim.fn.exepath = function() return "" end

      local result, err = grep({ path = ".", query = "test" }, {})
      assert.equals("", result)
      assert.equals("No search command found", err)
    end)

    it("should respect path permissions", function()
      local result, err = grep({ path = "../outside_project", query = "test" }, {})
      assert.truthy(err:find("No permission to access path"))
    end)

    it("should handle non-existent paths", function()
      local result, err = grep({ path = "non_existent_dir", query = "test" }, {})
      assert.equals("", result)
      assert.truthy(err)
      assert.truthy(err:find("No such file or directory"))
    end)
  end)

  describe("bash", function()
    -- it("should execute command and return output", function()
    --   bash({ path = ".", command = "echo 'test'" }, nil, function(result, err)
    --     assert.is_nil(err)
    --     assert.equals("test\n", result)
    --   end)
    -- end)

    it("should return error when running outside current directory", function()
      bash({ path = "../outside_project", command = "echo 'test'" }, {
        session_ctx = {},
        on_complete = function(result, err)
          assert.is_false(result)
          assert.truthy(err)
          assert.truthy(err:find("No permission to access path"))
        end,
      })
    end)
  end)

  describe("python", function()
    local response, command, command_opts

    before_each(function()
      response = { code = 0, stdout = "", stderr = "" }
      command, command_opts = nil, nil
      local executable = vim.fn.executable
      stub(vim.fn, "executable", function(name)
        if name == "docker" then return 1 end
        return executable(name)
      end)
      local system = vim.system
      stub(vim, "system", function(cmd, opts, callback)
        if cmd[1] ~= "docker" then return system(cmd, opts, callback) end
        command, command_opts = cmd, opts
        callback(response)
      end)
    end)

    after_each(function()
      vim.system:revert()
      vim.fn.executable:revert()
    end)

    local function run_python(input)
      local completed, result, err
      local immediate_result, immediate_err = LlmTools.python(input, {
        session_ctx = {},
        on_complete = function(output, error)
          completed, result, err = true, output, error
        end,
      })
      if immediate_err then return immediate_result, immediate_err end
      assert.is_true(vim.wait(1000, function() return completed end, 1), "Python callback did not run")
      return result, err
    end

    it("should execute Python code and return output", function()
      response.stdout = "Hello from Python\n"
      local result, err = run_python({
        path = ".",
        code = "print('Hello from Python')",
      })
      assert.is_nil(err)
      assert.equals("Hello from Python\n", result)
      assert.same({
        "docker",
        "run",
        "--rm",
        "-v",
        test_dir .. ":" .. test_dir,
        "-w",
        test_dir,
        "python:3.14-slim-bookworm",
        "python",
        "-c",
        "print('Hello from Python')",
      }, command)
      assert.same({ text = true, cwd = test_dir }, command_opts)
    end)

    it("should handle Python errors", function()
      response.code, response.stderr = 1, "NameError: name 'undefined_variable' is not defined"
      local result, err = run_python({
        path = ".",
        code = "print(undefined_variable)",
      })
      assert.is_nil(result)
      assert.equals("Error: " .. response.stderr, err)
    end)

    it("should respect path permissions", function()
      local result, err = run_python({
        path = "../outside_project",
        code = "print('test')",
      })
      assert.is_nil(result)
      assert.truthy(err:find("No permission to access path"))
      assert.is_nil(command)
    end)

    it("should handle non-existent paths", function()
      local result, err = run_python({
        path = "non_existent_dir",
        code = "print('test')",
      })
      assert.is_nil(result)
      assert.truthy(err:find("Path not found"))
      assert.is_nil(command)
    end)

    it("should support custom container image", function()
      response.stdout = "Hello from custom container\n"
      local result, err = run_python({
        path = ".",
        code = "print('Hello from custom container')",
        container_image = "python:3.12-slim",
      })
      assert.is_nil(err)
      assert.equals("Hello from custom container\n", result)
      assert.equals("python:3.12-slim", command[8])
    end)
  end)

  describe("glob", function()
    it("should preserve trailing slashes for directory-only patterns", function()
      local cases = {
        { pattern = "test_dir1/", expected = { test_dir .. "/test_dir1/" } },
        { pattern = "*/", expected = { test_dir .. "/test_dir1/", test_dir .. "/test_dir2/" } },
        { pattern = "**/", expected = { test_dir .. "/test_dir1/", test_dir .. "/test_dir2/" } },
        {
          pattern = "{test_dir1/,test_dir2/}",
          expected = { test_dir .. "/test_dir1/", test_dir .. "/test_dir2/" },
        },
        { pattern = "test.txt/", expected = {} },
      }
      for _, case in ipairs(cases) do
        local result, err = glob({ path = ".", pattern = case.pattern }, {})
        assert.is_nil(err)
        assert.are.same(case.expected, vim.json.decode(result).matches)
      end
    end)

    it("should require an explicit dot for each hidden path component", function()
      vim.fn.mkdir(test_dir .. "/.config/nested", "p")
      vim.fn.mkdir(test_dir .. "/.config/.hidden", "p")
      vim.fn.writefile({}, test_dir .. "/.config/visible.txt")
      vim.fn.writefile({}, test_dir .. "/.config/.secret.txt")
      vim.fn.writefile({}, test_dir .. "/.config/nested/visible.txt")
      vim.fn.writefile({}, test_dir .. "/.config/nested/.secret.txt")
      vim.fn.writefile({}, test_dir .. "/.config/.hidden/visible.txt")

      local cases = {
        {
          pattern = ".config/*",
          expected = { test_dir .. "/.config/nested", test_dir .. "/.config/visible.txt" },
        },
        {
          pattern = ".config/**/*.txt",
          expected = { test_dir .. "/.config/nested/visible.txt", test_dir .. "/.config/visible.txt" },
        },
        { pattern = ".config/.*.txt", expected = { test_dir .. "/.config/.secret.txt" } },
        { pattern = "**/.config/.hidden/*.txt", expected = { test_dir .. "/.config/.hidden/visible.txt" } },
      }
      for _, case in ipairs(cases) do
        local result, err = glob({ path = ".", pattern = case.pattern }, {})
        assert.is_nil(err)
        assert.are.same(case.expected, vim.json.decode(result).matches)
      end
    end)

    it("should not enable hidden files in other brace alternatives", function()
      vim.fn.writefile({}, test_dir .. "/.secret.txt")
      local result, err = glob({ path = ".", pattern = "{.gitignore,*.txt}" }, {})
      assert.is_nil(err)
      assert.are.same({ test_dir .. "/.gitignore", test_dir .. "/test.txt" }, vim.json.decode(result).matches)
    end)

    it("should avoid scanning unrelated directories for targeted patterns", function()
      local private = test_dir .. "/private"
      vim.fn.mkdir(private, "p")
      local original_scandir = vim.uv.fs_scandir
      for _, pattern in ipairs({ "test_dir1/*.txt", "test_dir1/**/*.txt" }) do
        local scanned = {}
        stub(vim.uv, "fs_scandir", function(path, callback)
          table.insert(scanned, path)
          if path == private then
            callback("EACCES: permission denied", nil)
            return {}
          end
          return original_scandir(path, callback)
        end)
        local ok, result, err = pcall(glob.func, { path = ".", pattern = pattern }, {})
        vim.uv.fs_scandir:revert()
        assert.is_true(ok)
        assert.is_nil(err)
        assert.are.same({ test_dir .. "/test_dir1/test1.txt" }, vim.json.decode(result).matches)
        assert.are.same({ test_dir, test_dir .. "/test_dir1" }, scanned)
      end
    end)

    it("should expand nested braces and deduplicate overlapping patterns", function()
      local result, err = glob({ path = ".", pattern = "{test.txt,{test_dir1,test_dir2}/*.txt,**/test[12].txt}" }, {})
      assert.is_nil(err)
      assert.are.same({
        test_dir .. "/test.txt",
        test_dir .. "/test_dir1/test1.txt",
        test_dir .. "/test_dir2/test2.txt",
      }, vim.json.decode(result).matches)
    end)

    it("should preserve escaped braces and braces inside character classes", function()
      vim.fn.writefile({}, test_dir .. "/{literal}.txt")
      for _, pattern in ipairs({ "\\{literal\\}.txt", "[{]literal[}].txt" }) do
        local result, err = glob({ path = ".", pattern = pattern }, {})
        assert.is_nil(err)
        assert.are.same({ test_dir .. "/{literal}.txt" }, vim.json.decode(result).matches)
      end
    end)

    it("should handle consecutive globstars without duplicate results", function()
      local result, err = glob({ path = ".", pattern = "**/**/test*.txt" }, {})
      assert.is_nil(err)
      assert.are.same({
        test_dir .. "/test.txt",
        test_dir .. "/test_dir1/test1.txt",
        test_dir .. "/test_dir2/test2.txt",
      }, vim.json.decode(result).matches)
    end)

    it("should expand brace alternatives across directories", function()
      local pattern = "{test.txt,test_dir1/test1.txt,test_dir2/test2.txt}"
      local result, err = glob({ path = ".", pattern = pattern }, {})
      assert.is_nil(err)
      local files = vim.json.decode(result).matches
      assert.equals(3, #files)
      assert.truthy(vim.tbl_contains(files, test_dir .. "/test.txt"))
      assert.truthy(vim.tbl_contains(files, test_dir .. "/test_dir1/test1.txt"))
      assert.truthy(vim.tbl_contains(files, test_dir .. "/test_dir2/test2.txt"))
    end)

    it("should complete asynchronously when a callback is provided", function()
      local completed = false
      local output, error
      local result, err = glob({ path = ".", pattern = "{*.txt,test_dir1/*.txt}" }, {
        on_complete = function(value, problem)
          output, error = value, problem
          completed = true
        end,
      })
      assert.is_nil(result)
      assert.is_nil(err)
      assert.is_false(completed)
      assert.is_true(vim.wait(5000, function() return completed end))
      assert.is_nil(error)
      assert.truthy(vim.json.decode(output).matches)
    end)

    it("should return malformed pattern errors without throwing", function()
      local ok, result, err = pcall(glob.func, { path = ".", pattern = "{missing" }, {})
      assert.is_true(ok)
      assert.equals("", result)
      assert.truthy(err:find("Glob search failed"))
    end)

    it("should report directory scan failures without throwing", function()
      stub(vim.uv, "fs_scandir", function() error("scan failed") end)
      local ok, result, err = pcall(glob.func, { path = ".", pattern = "*.txt" }, {})
      vim.uv.fs_scandir:revert()
      assert.is_true(ok)
      assert.equals("", result)
      assert.truthy(err:find("Glob search failed"))
    end)

    it("should report search timeouts", function()
      stub(vim, "defer_fn", function(callback, timeout)
        assert.equals(10000, timeout)
        vim.schedule(callback)
      end)
      local result, err = glob({ path = ".", pattern = "*.txt" }, {})
      vim.defer_fn:revert()
      assert.equals("", result)
      assert.truthy(err:find("timed out"))
    end)

    it("should preserve filenames and stop scanning when results are truncated", function()
      local filename = "file with spaces\nand a newline.txt"
      local entries = 0
      stub(vim.uv, "fs_scandir", function(_, callback)
        callback(nil, {})
        return {}
      end)
      stub(vim.uv, "fs_scandir_next", function()
        entries = entries + 1
        return entries == 1 and filename or string.rep("a", 10240), "file"
      end)
      local result, err = glob({ path = ".", pattern = "*" }, {})
      vim.uv.fs_scandir:revert()
      vim.uv.fs_scandir_next:revert()
      assert.is_nil(err)
      local decoded = vim.json.decode(result)
      assert.equals(test_dir .. "/" .. filename, decoded.matches[1])
      assert.is_true(decoded.is_truncated)
      assert.equals(2, entries)
    end)

    it("should yield between batches in a large directory", function()
      local entries = 0
      local heartbeat = false
      stub(vim.uv, "fs_scandir", function(_, callback)
        callback(nil, {})
        return {}
      end)
      stub(vim.uv, "fs_scandir_next", function()
        entries = entries + 1
        if entries == 1 then vim.schedule(function() heartbeat = true end) end
        if entries == 129 then assert.is_true(heartbeat) end
        if entries <= 300 then return "entry" .. entries .. ".txt", "file" end
      end)
      local result, err = glob({ path = ".", pattern = "*.lua" }, {})
      vim.uv.fs_scandir:revert()
      vim.uv.fs_scandir_next:revert()
      assert.is_nil(err)
      assert.equals(0, #vim.json.decode(result).matches)
      assert.is_true(heartbeat)
      assert.equals(301, entries)
    end)

    it("should work without an external search executable", function()
      stub(vim.fn, "exepath", function() return "" end)
      local result, err = glob({ path = ".", pattern = "*.txt" }, {})
      vim.fn.exepath:revert()
      assert.is_nil(err)
      assert.truthy(vim.tbl_contains(vim.json.decode(result).matches, test_dir .. "/test.txt"))
    end)

    it("should find files matching the pattern", function()
      -- Create some additional test files with different extensions for glob testing
      os.execute("touch " .. test_dir .. "/file1.lua")
      os.execute("touch " .. test_dir .. "/file2.lua")
      os.execute("touch " .. test_dir .. "/file3.js")
      os.execute("mkdir -p " .. test_dir .. "/nested")
      os.execute("touch " .. test_dir .. "/nested/file4.lua")

      -- Test for lua files in the root
      local result, err = glob({ path = ".", pattern = "*.lua" }, {})
      assert.is_nil(err)
      local files = vim.json.decode(result).matches
      assert.equals(2, #files)
      assert.truthy(vim.tbl_contains(files, test_dir .. "/file1.lua"))
      assert.truthy(vim.tbl_contains(files, test_dir .. "/file2.lua"))
      assert.falsy(vim.tbl_contains(files, test_dir .. "/file3.js"))
      assert.falsy(vim.tbl_contains(files, test_dir .. "/nested/file4.lua"))

      -- Test with recursive pattern
      local result2, err2 = glob({ path = ".", pattern = "**/*.lua" }, {})
      assert.is_nil(err2)
      local files2 = vim.json.decode(result2).matches
      assert.equals(3, #files2)
      assert.truthy(vim.tbl_contains(files2, test_dir .. "/file1.lua"))
      assert.truthy(vim.tbl_contains(files2, test_dir .. "/file2.lua"))
      assert.truthy(vim.tbl_contains(files2, test_dir .. "/nested/file4.lua"))
    end)

    it("should respect path permissions", function()
      local result, err = glob({ path = "../outside_project", pattern = "*.txt" }, {})
      assert.equals("", result)
      assert.truthy(err:find("No permission to access path"))
    end)

    it("should handle patterns without matches", function()
      local result, err = glob({ path = ".", pattern = "*.nonexistent" }, {})
      assert.is_nil(err)
      local files = vim.json.decode(result).matches
      assert.equals(0, #files)
    end)

    it("should handle files in gitignored directories", function()
      -- Create test files in ignored directory
      os.execute("touch " .. test_dir .. "/test_dir2/ignored1.lua")
      os.execute("touch " .. test_dir .. "/test_dir2/ignored2.lua")

      -- Create test files in non-ignored directory
      os.execute("touch " .. test_dir .. "/test_dir1/notignored1.lua")
      os.execute("touch " .. test_dir .. "/test_dir1/notignored2.lua")

      local result, err = glob({ path = ".", pattern = "**/*.lua" }, {})
      assert.is_nil(err)
      local files = vim.json.decode(result).matches

      -- Check that files from non-ignored directory are found
      local found_notignored = false
      for _, file in ipairs(files) do
        if file:find("test_dir1/notignored") then
          found_notignored = true
          break
        end
      end
      assert.is_true(found_notignored)

      -- Note: By default, vim.fn.glob does not respect gitignore files
      -- This test simply verifies the glob function works as expected
      -- If in the future, the function is modified to respect gitignore,
      -- this test can be updated
    end)
  end)
end)
