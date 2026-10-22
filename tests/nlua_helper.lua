local cwd = vim.fn.getcwd()
local deps = (os.getenv("DEPS_PATH") or "target/tests/deps") .. "/share/lua/5.1"
package.path = deps .. "/?.lua;" .. deps .. "/?/init.lua;" .. package.path

vim.opt.runtimepath:prepend(cwd)

local Path = {}
Path.__index = Path

local function join(parts)
  local result = parts[1] or ""
  for i = 2, #parts do
    local part = tostring(parts[i])
    if result == "" or part:sub(1, 1) == "/" then
      result = part
    else
      result = result:gsub("/$", "") .. "/" .. part:gsub("^/", "")
    end
  end
  return result
end

function Path:new(...)
  local value = join({ ... })
  return setmetatable({ filename = value }, self)
end

function Path:__tostring() return self.filename end

function Path:joinpath(...) return Path:new(self.filename, ...) end

function Path:parent() return Path:new(vim.fs.dirname(self.filename)) end

function Path:normalize(root)
  if root and not self:is_absolute() then return tostring(Path:new(root, self.filename)) end
  return vim.fs.normalize(self.filename)
end

function Path:exists() return vim.uv.fs_stat(self.filename) ~= nil end

function Path:is_file()
  local stat = vim.uv.fs_stat(self.filename)
  return stat and stat.type == "file" or false
end

function Path:is_dir()
  local stat = vim.uv.fs_stat(self.filename)
  return stat and stat.type == "directory" or false
end

function Path:is_absolute() return vim.fs.normalize(self.filename):sub(1, 1) == "/" end

function Path:mkdir(opts) vim.fn.mkdir(self.filename, opts and opts.parents and "p" or "") end

function Path:read()
  local fd = assert(io.open(self.filename, "r"))
  local content = fd:read("*a")
  fd:close()
  return content
end

function Path:write(content, mode)
  local parent = vim.fs.dirname(self.filename)
  if parent and parent ~= "." then vim.fn.mkdir(parent, "p") end
  local fd = assert(io.open(self.filename, mode or "w"))
  fd:write(content)
  fd:close()
end

function Path:list()
  local entries = {}
  local fs = vim.uv.fs_scandir(self.filename)
  if not fs then return entries end
  while true do
    local name = vim.uv.fs_scandir_next(fs)
    if not name then break end
    table.insert(entries, name)
  end
  return entries
end

function Path:unlink() vim.fs.rm(self.filename, { recursive = true, force = true }) end

function Path:copy(opts)
  local destination = tostring(opts.destination)
  if self:is_dir() then
    if opts.recursive then
      vim.fn.mkdir(destination, "p")
      for _, entry in ipairs(self:list()) do
        local source = self:joinpath(entry)
        source:copy({ destination = vim.fs.joinpath(destination, entry), recursive = true, override = opts.override })
      end
    end
    return
  end

  if not opts.override and vim.uv.fs_stat(destination) then return end
  local parent = vim.fs.dirname(destination)
  if parent and parent ~= "." then vim.fn.mkdir(parent, "p") end
  vim.fn.writefile(vim.fn.readfile(self.filename, "b"), destination, "b")
end

package.preload["plenary.path"] = function() return Path end

local function scan_dir(root, opts)
  opts = opts or {}
  local results = {}
  local max_depth = opts.depth or math.huge

  local function scan(dir, depth)
    if depth > max_depth then return end

    local fs = vim.uv.fs_scandir(dir)
    if not fs then return end

    while true do
      local name, kind = vim.uv.fs_scandir_next(fs)
      if not name then break end

      local path = vim.fs.joinpath(dir, name)
      local is_dir = kind == "directory"
      local include = (is_dir and opts.add_dirs ~= false) or (not is_dir and not opts.only_dirs)
      if include then table.insert(results, path) end
      if is_dir and opts.recursive ~= false then scan(path, depth + 1) end
    end
  end

  scan(root, 1)
  return results
end

package.preload["plenary.scandir"] = function()
  return {
    scan_dir = scan_dir,
  }
end

package.preload["plenary.filetype"] = function()
  return {
    detect = function(filepath) return vim.filetype.match({ filename = filepath }) end,
  }
end

package.preload["plenary.curl"] = function()
  return {
    get = function() error("plenary.curl.get was not stubbed for this test") end,
    post = function() error("plenary.curl.post was not stubbed for this test") end,
  }
end

return function(busted)
  local schedule = vim.schedule
  local callback_errors = {}
  local pending_callbacks = 0
  -- Neovim otherwise logs scheduled assertion failures without failing Busted.
  vim.schedule = function(callback)
    pending_callbacks = pending_callbacks + 1
    schedule(function()
      local ok, err = xpcall(callback, function(error) return debug.traceback(tostring(error), 2) end)
      pending_callbacks = pending_callbacks - 1
      if not ok then table.insert(callback_errors, err) end
    end)
  end

  local function check_scheduled_callbacks()
    local drained = false
    schedule(function() drained = true end)
    assert(
      vim.wait(1000, function() return drained and pending_callbacks == 0 end, 1),
      "scheduled callbacks did not drain"
    )
    local errors = callback_errors
    callback_errors = {}
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
    return nil, true
  end

  busted.subscribe({ "test", "end" }, check_scheduled_callbacks, { priority = 1 })
  busted.subscribe({ "suite", "end" }, function()
    local ok, err = pcall(check_scheduled_callbacks)
    vim.schedule = schedule
    if not ok then error(err, 0) end
    return nil, true
  end, { priority = 1 })
  return true
end
