local Utils = require("avante.utils")
local Path = require("plenary.path")

local M = {}

local auth_path = vim.fn.stdpath("data") .. "/avante/auth.json"
local legacy_claude_path = vim.fn.stdpath("data") .. "/avante/claude-auth.json"

local callbacks = {}

---Acquire a named auth lock without waiting. Keep the returned release function
---until the operation finishes, including asynchronous refresh and persistence.
---@param name string Lock name without the .lock suffix
---@return fun()|nil release
function M.try_lock(name)
  local lockfile_path = vim.fn.fnamemodify(auth_path, ":h") .. "/" .. name .. ".lock"
  vim.fn.mkdir(vim.fn.fnamemodify(lockfile_path, ":h"), "p")
  local ok, content = pcall(function() return Path:new(lockfile_path):read() end)
  local pid = ok and tonumber(content)
  if pid then
    local _, _, err = vim.uv.kill(pid, 0)
    if err == "ESRCH" then os.remove(lockfile_path) end
  end
  local fd = vim.uv.fs_open(lockfile_path, "wx", 384)
  if not fd then return nil end
  local owner = tostring(vim.fn.getpid())
  local written = vim.uv.fs_write(fd, owner, 0)
  vim.uv.fs_close(fd)
  if written ~= #owner then
    os.remove(lockfile_path)
    return nil
  end
  local released = false
  return function()
    if released then return end
    released = true
    local read_ok, current = pcall(function() return Path:new(lockfile_path):read() end)
    if read_ok and current == owner then os.remove(lockfile_path) end
  end
end

local function safe_decode(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if ok and type(data) == "table" then return data end
  return nil
end

local function write_json(data)
  local parent = Path:new(auth_path):parent()
  if not parent:exists() then parent:mkdir({ parents = true }) end

  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    Utils.error("Failed to encode auth data: " .. tostring(json_str), { once = true, title = "Avante" })
    return false
  end

  local tmp_path = auth_path .. ".tmp." .. vim.fn.getpid()
  -- Set owner-only permissions before writing any credentials.
  local fd, open_err = vim.uv.fs_open(tmp_path, "w", 384)
  if not fd then
    Utils.error("Failed to save auth file: " .. tostring(open_err), { once = true, title = "Avante" })
    return false
  end

  local written, write_err = vim.uv.fs_write(fd, json_str, 0)
  vim.uv.fs_close(fd)

  if written ~= #json_str then
    os.remove(tmp_path)
    Utils.error("Failed to write auth file: " .. tostring(write_err), { once = true, title = "Avante" })
    return false
  end

  local rename_ok = os.rename(tmp_path, auth_path)
  if not rename_ok then
    Utils.error("Failed to replace auth file", { once = true, title = "Avante" })
    return false
  end

  if vim.fn.has("unix") == 1 then
    local chmod_ok = vim.uv.fs_chmod(auth_path, 384) -- 384 is "600" in octal, RW for user only
    if not chmod_ok then Utils.warn("Failed to set auth file permissions", { once = true, title = "Avante" }) end
  end

  return true
end

local function with_lock(fn)
  -- Credential writes must finish before a rotating-token refresh releases its
  -- lock. Bound the wait instead of scheduling the write for a later tick.
  for _ = 1, 6 do
    local release = M.try_lock("auth")
    if release then
      local ok, result = pcall(fn)
      release()
      if ok then return result end
      Utils.warn("Failed to update auth file: " .. tostring(result), { once = true, title = "Avante" })
      return false
    end
    vim.uv.sleep(50)
  end
  Utils.warn("Auth file is locked by another process", { once = true, title = "Avante" })
  return false
end

function M.path() return auth_path end

function M.read()
  local auth_file = Path:new(auth_path)
  if auth_file:exists() then
    local data = safe_decode(auth_file:read())
    if data then
      local legacy = Path:new(legacy_claude_path)
      if legacy:exists() then os.remove(legacy_claude_path) end
      return data
    end

    Utils.warn("Auth file is corrupted, re-authentication required", { once = true, title = "Avante" })
    os.remove(auth_path)
    return nil
  end

  local legacy = Path:new(legacy_claude_path)
  if legacy:exists() then
    local token = safe_decode(legacy:read())
    if token then
      local data = { claude = token }
      write_json(data)
      os.remove(legacy_claude_path)
      return data
    end

    Utils.warn("Auth file is corrupted, re-authentication required", { once = true, title = "Avante" })
    os.remove(legacy_claude_path)
  end

  return nil
end

function M.write_all(data)
  data = data or {}
  return with_lock(function() return write_json(data) end)
end

function M.update(provider, token)
  return with_lock(function()
    local data = M.read() or {}
    data[provider] = token
    return write_json(data)
  end)
end

function M.watch(callback)
  table.insert(callbacks, callback)
  if not M._watcher then
    vim.fn.mkdir(vim.fn.fnamemodify(auth_path, ":h"), "p")
    M._watcher = vim.uv.new_fs_event()
    -- Watch the directory: an atomic rename replaces the file's inode.
    M._watcher:start(
      vim.fn.fnamemodify(auth_path, ":h"),
      {},
      vim.schedule_wrap(function(err, filename)
        if err or (filename and filename ~= "auth.json") then return end
        local data = M.read()
        for _, cb in ipairs(callbacks) do
          cb(data)
        end
      end)
    )
  end
  return function()
    for i, cb in ipairs(callbacks) do
      if cb == callback then
        table.remove(callbacks, i)
        break
      end
    end
    if #callbacks == 0 then M.cleanup() end
  end
end

function M.cleanup()
  if M._watcher then
    ---@diagnostic disable-next-line: param-type-mismatch
    M._watcher:stop()
    M._watcher:close()
    M._watcher = nil
  end
end

return M
