describe("llm_tools.delete_path", function()
  local delete_path
  local Helpers
  local real_has_permission_to_access
  local confirm_response
  local cleanup_paths

  local function temp_path(suffix)
    local path = vim.fn.tempname() .. (suffix or "")
    table.insert(cleanup_paths, path)
    return path
  end

  local function make_dir()
    local dir = temp_path()
    vim.fn.mkdir(dir, "p")
    return dir
  end

  local function call_delete(path)
    local completed
    local calls = 0
    local path_gone_at_callback
    -- Precondition failures return directly; everything else fires on_complete
    -- from inside the confirm callback.
    local ret1, ret2 = delete_path({ path = path }, {
      on_log = function() end,
      on_complete = function(success, message)
        calls = calls + 1
        path_gone_at_callback = vim.uv.fs_lstat(path) == nil
        completed = { success = success, message = message }
      end,
    })
    if ret1 ~= nil then return { success = ret1, message = ret2, calls = 0 } end
    return {
      success = completed and completed.success,
      message = completed and completed.message,
      calls = calls,
      path_gone_at_callback = path_gone_at_callback,
    }
  end

  before_each(function()
    require("avante.config").setup({})
    Helpers = require("avante.llm_tools.helpers")
    real_has_permission_to_access = Helpers.has_permission_to_access
    cleanup_paths = {}
    confirm_response = true
    Helpers.confirm = function(_, callback) callback(confirm_response, nil) end
    Helpers.has_permission_to_access = function() return true end
    package.loaded["avante.llm_tools"] = nil
    delete_path = require("avante.llm_tools").delete_path
  end)

  after_each(function()
    Helpers.has_permission_to_access = real_has_permission_to_access
    for _, path in ipairs(cleanup_paths) do
      vim.fn.delete(path, "rf")
    end
    cleanup_paths = {}
  end)

  it("deletes a file", function()
    local file = temp_path(" with spaces.txt")
    vim.fn.writefile({ "disposable" }, file)

    local result = call_delete(file)

    assert.is_true(result.success)
    assert.is_nil(result.message)
    assert.are.equal(1, result.calls)
    assert.is_true(result.path_gone_at_callback)
    assert.is_nil(vim.uv.fs_stat(file))
  end)

  it("deletes an empty directory", function()
    local dir = make_dir()

    local result = call_delete(dir)

    assert.is_true(result.success)
    assert.is_nil(result.message)
    assert.are.equal(1, result.calls)
    assert.is_true(result.path_gone_at_callback)
    assert.is_nil(vim.uv.fs_lstat(dir))
  end)

  it("deletes a directory tree", function()
    local dir = make_dir()
    vim.fn.mkdir(dir .. "/nested", "p")
    vim.fn.writefile({ "nested" }, dir .. "/nested/inner.txt")

    local result = call_delete(dir)

    assert.is_true(result.success)
    assert.is_nil(result.message)
    assert.are.equal(1, result.calls)
    assert.is_true(result.path_gone_at_callback)
    assert.is_nil(vim.uv.fs_lstat(dir))
  end)

  it("unlinks the file permanently", function()
    if vim.fn.has("win32") == 1 then return pending("POSIX only") end
    local file = temp_path()
    vim.fn.writefile({ "x" }, file)
    local fd = assert(vim.uv.fs_open(file, "r", 438))

    local ok, result = pcall(call_delete, file)
    local stat = vim.uv.fs_fstat(fd)
    vim.uv.fs_close(fd)

    if not ok then error(result) end
    assert.is_true(result.success)
    assert.are.equal(0, stat.nlink)
  end)

  it("removes a symlink to a directory without following it", function()
    local target_dir = make_dir()
    local kept = target_dir .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local link = temp_path()
    if not vim.uv.fs_symlink(target_dir, link) then return pending("symlinks are not supported on this platform") end

    local result = call_delete(link)

    assert.is_true(result.success)
    assert.are.equal(1, result.calls)
    assert.is_nil(vim.uv.fs_lstat(link))
    assert.are.same({ "keep me" }, vim.fn.readfile(kept))
  end)

  it("normalizes a trailing slash on a directory symlink", function()
    local target_dir = make_dir()
    local kept = target_dir .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local link = temp_path()
    if not vim.uv.fs_symlink(target_dir, link) then return pending("symlinks are not supported on this platform") end

    local result = call_delete(link .. "/")

    assert.is_true(result.success)
    assert.are.equal(1, result.calls)
    assert.is_nil(vim.uv.fs_lstat(link))
    assert.are.same({ "keep me" }, vim.fn.readfile(kept))
  end)

  it("deletes a dangling symlink", function()
    local target = temp_path() .. "-missing"
    local link = temp_path()
    if not vim.uv.fs_symlink(target, link) then return pending("symlinks are not supported on this platform") end

    local result = call_delete(link)

    assert.is_true(result.success)
    assert.is_nil(vim.uv.fs_lstat(link))
  end)

  it("does not follow a symlink nested in a deleted tree", function()
    local outside = make_dir()
    local kept = outside .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local dir = make_dir()
    if not vim.uv.fs_symlink(outside, dir .. "/link") then
      return pending("symlinks are not supported on this platform")
    end

    local result = call_delete(dir)

    assert.is_true(result.success)
    assert.are.equal(1, result.calls)
    assert.is_nil(vim.uv.fs_lstat(dir))
    assert.are.same({ "keep me" }, vim.fn.readfile(kept))
  end)

  it("resolves symlinked ancestors before checking permissions", function()
    local project = make_dir()
    local outside = make_dir()
    local kept = outside .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local link = project .. "/link"
    if not vim.uv.fs_symlink(outside, link) then return pending("symlinks are not supported on this platform") end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end
    local seen
    Helpers.has_permission_to_access = function(path)
      seen = path
      return false
    end

    local ok, success, message = pcall(delete_path, { path = link .. "/keep.txt" }, {})
    Utils.get_project_root = original_get_root

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("No permission", 1, true))
    assert.are.same(
      vim.fs.normalize(vim.fs.joinpath(assert(vim.uv.fs_realpath(outside)), "keep.txt")),
      vim.fs.normalize(seen)
    )
    assert.is_not_nil(vim.uv.fs_stat(kept))
  end)

  it("leaves the path untouched when the user declines", function()
    confirm_response = false
    local file = temp_path()
    vim.fn.writefile({ "keep me" }, file)

    local result = call_delete(file)

    assert.is_false(result.success)
    assert.are.equal(1, result.calls)
    assert.is_false(result.path_gone_at_callback)
    assert.truthy(result.message:find("User declined", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(file))
  end)

  it("returns an error for a missing path without invoking on_complete", function()
    local calls = 0
    local success, message = delete_path({ path = "does/not/exist" }, {
      on_complete = function() calls = calls + 1 end,
    })

    assert.is_false(success)
    assert.truthy(message:find("Path not found", 1, true))
    assert.are.equal(0, calls)
  end)

  it("rejects an empty or missing path", function()
    for _, input in ipairs({ { path = "" }, {} }) do
      local ok, success, message = pcall(delete_path, input, {})
      assert.is_true(ok)
      assert.is_false(success)
      assert.truthy(message:find("path not provided", 1, true))
    end
  end)

  it("refuses to delete the project root", function()
    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    local root = make_dir()
    vim.fn.writefile({ "keep me" }, root .. "/keep.txt")
    Utils.get_project_root = function() return root end

    local results = {}
    for _, path in ipairs({ ".", "sub/.." }) do
      local ok, success, message = pcall(delete_path, { path = path }, {})
      table.insert(results, { ok = ok, success = success, message = message })
    end
    Utils.get_project_root = original_get_root

    for _, result in ipairs(results) do
      assert.is_true(result.ok)
      assert.is_false(result.success)
      assert.truthy(result.message:find("project root", 1, true))
    end
    assert.is_not_nil(vim.uv.fs_stat(root .. "/keep.txt"))
  end)

  it("requires on_complete", function()
    local file = temp_path()
    vim.fn.writefile({ "keep me" }, file)

    local success, message = delete_path({ path = file }, {})

    assert.is_false(success)
    assert.truthy(message:find("on_complete not provided", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(file))
  end)

  it("normalizes the path before checking permissions", function()
    local seen
    Helpers.has_permission_to_access = function(path)
      seen = path
      return false
    end
    local input = vim.fs.joinpath(vim.fn.getcwd(), "..", "escaped")

    local success, message = delete_path({ path = input }, {})

    assert.is_false(success)
    assert.truthy(message:find("No permission", 1, true))
    assert.are.same(vim.fs.normalize(input), seen)
  end)

  it("reports a failure when a child cannot be removed", function()
    if vim.fn.has("win32") == 1 then return pending("POSIX permissions required") end
    if vim.uv.getuid and vim.uv.getuid() == 0 then return pending("requires a non-root user") end

    local dir = make_dir()
    local file = dir .. "/file.txt"
    vim.fn.writefile({ "keep me" }, file)
    assert(vim.uv.fs_chmod(dir, tonumber("555", 8)))

    local ok, result = pcall(call_delete, dir)
    vim.uv.fs_chmod(dir, tonumber("755", 8))

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message)
    assert.are.equal(1, result.calls)
    assert.is_false(result.path_gone_at_callback)
    assert.is_not_nil(vim.uv.fs_stat(file))
  end)

  it("reports a failure when the directory itself cannot be removed", function()
    if vim.fn.has("win32") == 1 then return pending("POSIX permissions required") end
    if vim.uv.getuid and vim.uv.getuid() == 0 then return pending("requires a non-root user") end

    local parent = make_dir()
    local dir = parent .. "/empty"
    vim.fn.mkdir(dir, "p")
    assert(vim.uv.fs_chmod(parent, tonumber("555", 8)))

    local ok, result = pcall(call_delete, dir)
    vim.uv.fs_chmod(parent, tonumber("755", 8))

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message)
    assert.are.equal(1, result.calls)
    assert.is_false(result.path_gone_at_callback)
    assert.is_not_nil(vim.uv.fs_lstat(dir))
  end)

  it("reports a non-ENOENT stat failure", function()
    local file = temp_path()
    vim.fn.writefile({ "keep me" }, file)
    local resolved = vim.fs.joinpath(assert(vim.uv.fs_realpath(vim.fs.dirname(file))), vim.fs.basename(file))
    local original_lstat = vim.uv.fs_lstat
    local fail_lstat = false
    Helpers.confirm = function(_, callback)
      fail_lstat = true
      callback(true, nil)
    end
    vim.uv.fs_lstat = function(path)
      if fail_lstat and vim.fs.normalize(path) == vim.fs.normalize(resolved) then
        return nil, "EACCES: permission denied", "EACCES"
      end
      return original_lstat(path)
    end

    local result
    local ok, err = pcall(delete_path, { path = file }, {
      on_complete = function(success, message) result = { success = success, message = message } end,
    })
    vim.uv.fs_lstat = original_lstat

    if not ok then error(err) end
    assert.is_false(result.success)
    assert.truthy(result.message)
    assert.is_not_nil(vim.uv.fs_stat(file))
  end)

  it("reports a scandir failure", function()
    if vim.fn.has("win32") == 1 then return pending("POSIX permissions required") end
    if vim.uv.getuid and vim.uv.getuid() == 0 then return pending("requires a non-root user") end

    local dir = make_dir()
    assert(vim.uv.fs_chmod(dir, tonumber("000", 8)))

    local ok, result = pcall(call_delete, dir)
    vim.uv.fs_chmod(dir, tonumber("755", 8))

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message)
    assert.are.equal(1, result.calls)
    assert.is_false(result.path_gone_at_callback)
    assert.is_not_nil(vim.uv.fs_lstat(dir))
  end)

  it("reports success when the path disappears after confirmation", function()
    local file = temp_path()
    vim.fn.writefile({ "gone" }, file)
    Helpers.confirm = function(_, callback)
      os.remove(file)
      callback(true, nil)
    end

    local result = call_delete(file)

    assert.is_true(result.success)
    assert.are.equal(1, result.calls)
    assert.is_true(result.path_gone_at_callback)
  end)

  it("treats a directory removed during traversal as success", function()
    local dir = make_dir()
    local resolved = vim.fs.joinpath(assert(vim.uv.fs_realpath(vim.fs.dirname(dir))), vim.fs.basename(dir))
    local original_scandir = vim.uv.fs_scandir
    vim.uv.fs_scandir = function(path)
      if vim.fs.normalize(path) == vim.fs.normalize(resolved) then
        return nil, "ENOENT: no such file or directory", "ENOENT"
      end
      return original_scandir(path)
    end

    local ok, result = pcall(call_delete, dir)
    vim.uv.fs_scandir = original_scandir

    if not ok then error(result) end
    assert.is_true(result.success)
  end)

  it("allows canonical targets under a symlinked project root", function()
    local real_project = make_dir()
    local kept = real_project .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local alias = temp_path()
    if not vim.uv.fs_symlink(real_project, alias) then
      return pending("symlinks are not supported on this platform")
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return alias end
    Helpers.has_permission_to_access = real_has_permission_to_access

    local ok, result = pcall(call_delete, alias .. "/keep.txt")
    Utils.get_project_root = original_get_root

    if not ok then error(result) end
    assert.is_true(result.success)
    assert.is_nil(vim.uv.fs_stat(kept))
  end)

  it("refuses the canonical target of a symlinked project root", function()
    local real_project = make_dir()
    local kept = real_project .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local alias = temp_path()
    if not vim.uv.fs_symlink(real_project, alias) then
      return pending("symlinks are not supported on this platform")
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return alias end
    Helpers.has_permission_to_access = real_has_permission_to_access

    local ok, success, message = pcall(delete_path, { path = real_project }, {})
    Utils.get_project_root = original_get_root

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("project root", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(kept))
  end)

  it("refuses the canonical target of a symlinked config root", function()
    local real_config = make_dir()
    vim.fn.writefile({ "keep me" }, real_config .. "/init.lua")
    local config_link = temp_path()
    if not vim.uv.fs_symlink(real_config, config_link) then
      return pending("symlinks are not supported on this platform")
    end

    local original_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(name)
      if name == "config" then return config_link end
      return original_stdpath(name)
    end

    local ok, success, message = pcall(delete_path, { path = real_config }, {})
    vim.fn.stdpath = original_stdpath

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("config", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(real_config .. "/init.lua"))
  end)

  it("rechecks the resolved path after confirmation", function()
    local project = make_dir()
    local outside = make_dir()
    local kept = outside .. "/victim.txt"
    vim.fn.writefile({ "keep me" }, kept)
    local sub = project .. "/sub"
    vim.fn.mkdir(sub, "p")
    vim.fn.writefile({ "delete me" }, sub .. "/keep.txt")

    Helpers.confirm = function(_, callback)
      assert(vim.uv.fs_rename(sub, project .. "/sub-old"))
      assert(vim.uv.fs_symlink(outside, sub))
      callback(true, nil)
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end

    local ok, result = pcall(call_delete, "sub/keep.txt")
    Utils.get_project_root = original_get_root
    pcall(vim.uv.fs_unlink, sub)

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message:find("Path changed after confirmation", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(kept))
  end)

  it("rejects an in-project path change during confirmation", function()
    local project = make_dir()
    local a = project .. "/a"
    local b = project .. "/b"
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")
    vim.fn.writefile({ "approved" }, a .. "/file.txt")
    local kept = b .. "/file.txt"
    vim.fn.writefile({ "keep me" }, kept)

    Helpers.confirm = function(_, callback)
      assert(vim.uv.fs_rename(a, project .. "/a-old"))
      assert(vim.uv.fs_symlink(b, a))
      callback(true, nil)
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end

    local ok, result = pcall(call_delete, "a/file.txt")
    Utils.get_project_root = original_get_root
    pcall(vim.uv.fs_unlink, a)

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message:find("Path changed after confirmation", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(kept))
  end)

  it("refuses to delete Git metadata", function()
    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    local root = make_dir()
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.writefile({ "config" }, root .. "/.git/config")
    Utils.get_project_root = function() return root end

    local ok, success, message = pcall(delete_path, { path = ".git" }, {})
    Utils.get_project_root = original_get_root

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("Git metadata", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(root .. "/.git/config"))
  end)

  it("refuses the config root and its parents", function()
    local base = make_dir()
    local config_dir = base .. "/config/nvim"
    vim.fn.mkdir(config_dir, "p")
    vim.fn.writefile({ "keep me" }, config_dir .. "/init.lua")

    local original_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(name)
      if name == "config" then return config_dir end
      return original_stdpath(name)
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return base end

    local ok_root, root_success, root_message = pcall(delete_path, { path = config_dir }, {})
    local ok_parent, parent_success, parent_message = pcall(delete_path, { path = "config" }, {})
    Utils.get_project_root = original_get_root
    vim.fn.stdpath = original_stdpath

    if not ok_root then error(root_success) end
    if not ok_parent then error(parent_success) end
    assert.is_false(root_success)
    assert.truthy(root_message:find("config directory", 1, true))
    assert.is_false(parent_success)
    assert.truthy(parent_message:find("config directory", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(config_dir .. "/init.lua"))
  end)

  it("returns path not found for a missing leaf", function()
    local dir = make_dir()
    local missing = dir .. "/missing.txt"
    local ok, success, message = pcall(delete_path, { path = missing }, {})
    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("Path not found", 1, true))
  end)

  it("rechecks protected roots after confirmation", function()
    local project = make_dir()
    local target = project .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, target)

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end
    Helpers.confirm = function(_, callback)
      Utils.get_project_root = function() return target end
      callback(true, nil)
    end

    local ok, result = pcall(call_delete, target)
    Utils.get_project_root = original_get_root

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message:find("project root", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(target))
  end)

  it("rechecks permission after confirmation", function()
    local project = make_dir()
    local target = project .. "/keep.txt"
    vim.fn.writefile({ "keep me" }, target)

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end
    Helpers.confirm = function(_, callback)
      Helpers.has_permission_to_access = function() return false end
      callback(true, nil)
    end

    local ok, result = pcall(call_delete, target)
    Utils.get_project_root = original_get_root

    if not ok then error(result) end
    assert.is_false(result.success)
    assert.truthy(result.message:find("No permission", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(target))
  end)

  it("refuses a parent of a symlinked project root", function()
    local base = make_dir()
    local real_project = base .. "/real/project"
    vim.fn.mkdir(real_project, "p")
    vim.fn.writefile({ "keep me" }, real_project .. "/keep.txt")
    local project_link = base .. "/linked-project"
    if not vim.uv.fs_symlink(real_project, project_link) then
      return pending("symlinks are not supported on this platform")
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project_link end

    local ok, success, message = pcall(delete_path, { path = base .. "/real" }, {})
    Utils.get_project_root = original_get_root

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("project root", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(real_project .. "/keep.txt"))
  end)

  it("refuses Git metadata through a symlinked ancestor", function()
    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    local root = make_dir()
    local git_data = root .. "/git-data"
    vim.fn.mkdir(git_data .. "/objects", "p")
    vim.fn.writefile({ "object" }, git_data .. "/objects/probe")
    local git_link = root .. "/.git"
    if not vim.uv.fs_symlink(git_data, git_link) then return pending("symlinks are not supported on this platform") end
    Utils.get_project_root = function() return root end

    local ok, success, message = pcall(delete_path, { path = ".git/objects/probe" }, {})
    Utils.get_project_root = original_get_root

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("Git metadata", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(git_data .. "/objects/probe"))
  end)

  it("refuses an 8.3 alias of Git metadata", function()
    local root = make_dir()
    local git_dir = root .. "/.git"
    vim.fn.mkdir(git_dir, "p")
    vim.fn.writefile({ "config" }, git_dir .. "/config")
    local alias = root .. "/GIT~1"
    local original_lstat = vim.uv.fs_lstat
    local original_realpath = vim.uv.fs_realpath
    vim.uv.fs_lstat = function(path)
      if vim.fs.normalize(path) == vim.fs.normalize(alias) then return original_lstat(git_dir) end
      return original_lstat(path)
    end
    vim.uv.fs_realpath = function(path)
      if vim.fs.normalize(path) == vim.fs.normalize(alias) then return git_dir end
      return original_realpath(path)
    end
    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return root end

    local ok, success, message = pcall(delete_path, { path = alias }, {})
    Utils.get_project_root = original_get_root
    vim.uv.fs_lstat = original_lstat
    vim.uv.fs_realpath = original_realpath

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("Git metadata", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(git_dir .. "/config"))
  end)

  it("does not treat a POSIX backslash as a path separator", function()
    local Utils = require("avante.utils")
    if Utils.is_win() then return pending("POSIX-only filename") end
    local project = make_dir()
    local name = project .. "/weird\\.git"
    vim.fn.writefile({ "keep me" }, name)
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return project end

    local ok, result = pcall(call_delete, name)
    Utils.get_project_root = original_get_root

    if not ok then error(result) end
    assert.is_true(result.success)
    assert.is_nil(vim.uv.fs_stat(name))
  end)

  it("refuses a parent of a symlinked config root", function()
    local base = make_dir()
    local real_config = base .. "/real/config/nvim"
    vim.fn.mkdir(real_config, "p")
    vim.fn.writefile({ "keep me" }, real_config .. "/init.lua")
    local config_link = base .. "/linked-config"
    if not vim.uv.fs_symlink(real_config, config_link) then
      return pending("symlinks are not supported on this platform")
    end

    local original_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(name)
      if name == "config" then return config_link end
      return original_stdpath(name)
    end

    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return base end

    local ok, success, message = pcall(delete_path, { path = base .. "/real/config" }, {})
    Utils.get_project_root = original_get_root
    vim.fn.stdpath = original_stdpath

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("config directory", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(real_config .. "/init.lua"))
  end)

  it("detects a case-aliased parent of the config root", function()
    local base = make_dir()
    local config_dir = base .. "/.config/nvim"
    vim.fn.mkdir(config_dir, "p")
    vim.fn.writefile({ "keep me" }, config_dir .. "/init.lua")
    local alias = base .. "/.CONFIG"
    local original_lstat = vim.uv.fs_lstat
    local original_realpath = vim.uv.fs_realpath
    vim.uv.fs_lstat = function(path)
      if vim.fs.normalize(path) == vim.fs.normalize(alias) then return original_lstat(base .. "/.config") end
      return original_lstat(path)
    end
    vim.uv.fs_realpath = function(path)
      if vim.fs.normalize(path) == vim.fs.normalize(alias) then return base .. "/.config" end
      return original_realpath(path)
    end

    local original_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(name)
      if name == "config" then return config_dir end
      return original_stdpath(name)
    end
    local Utils = require("avante.utils")
    local original_get_root = Utils.get_project_root
    Utils.get_project_root = function() return base end

    local ok, success, message = pcall(delete_path, { path = alias }, {})
    Utils.get_project_root = original_get_root
    vim.fn.stdpath = original_stdpath
    vim.uv.fs_lstat = original_lstat
    vim.uv.fs_realpath = original_realpath

    if not ok then error(success) end
    assert.is_false(success)
    assert.truthy(message:find("config directory", 1, true))
    assert.is_not_nil(vim.uv.fs_stat(config_dir .. "/init.lua"))
  end)

  it("rejects Windows-aliased path components", function()
    local Utils = require("avante.utils")
    local original_is_win = Utils.is_win
    Utils.is_win = function() return true end

    local results = {}
    for _, path in ipairs({ "sub. ", ".. " }) do
      local ok, success, message = pcall(delete_path, { path = path }, {})
      table.insert(results, { ok = ok, success = success, message = message })
    end
    Utils.is_win = original_is_win

    for _, result in ipairs(results) do
      assert.is_true(result.ok)
      assert.is_false(result.success)
      assert.truthy(result.message:find("Windows-aliased", 1, true))
    end
  end)
end)
