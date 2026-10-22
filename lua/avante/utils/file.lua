local LRUCache = require("avante.utils.lru_cache")
local Filetype = require("plenary.filetype")

---@class avante.utils.file
local M = {}

local api = vim.api
local fn = vim.fn

local _file_content_lru_cache = LRUCache:new(60)

api.nvim_create_autocmd("BufWritePost", {
  callback = function()
    local filepath = api.nvim_buf_get_name(0)
    local keys = _file_content_lru_cache:keys()
    if vim.tbl_contains(keys, filepath) then
      local content = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      _file_content_lru_cache:set(filepath, content)
    end
  end,
})

function M.read_content(filepath)
  local cached_content = _file_content_lru_cache:get(filepath)
  if cached_content then return cached_content end

  local lines = fn.readfile(filepath)
  if lines then
    local content = table.concat(lines, "\n")
    _file_content_lru_cache:set(filepath, content)
    return content
  end

  return nil
end

function M.exists(filepath)
  local stat = vim.uv.fs_stat(filepath)
  return stat ~= nil
end

---@param filepath string
---@param content string
---@return true|nil, string|nil
function M.write_atomically(filepath, content)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(filepath)
  local fd, temp_path, open_err
  local pid = uv.os_getpid()
  local create_mode = stat and stat.mode or 438
  for attempt = 1, 10 do
    temp_path = table.concat({ filepath, ".avante-", pid, "-", uv.hrtime(), "-", attempt })
    fd, open_err = uv.fs_open(temp_path, "wx", create_mode)
    if fd then break end
  end
  if not fd then return nil, "Failed to create temporary file: " .. tostring(open_err) end

  local function fail(message)
    pcall(uv.fs_unlink, temp_path)
    return nil, tostring(message)
  end

  local close_ok, close_err = uv.fs_close(fd)
  if not close_ok then return fail("Failed to close temporary file: " .. tostring(close_err)) end

  local write_ok, write_result = pcall(fn.writefile, content, temp_path, "s")
  if not write_ok then return fail("Failed to write temporary file: " .. tostring(write_result)) end
  if write_result ~= 0 then return fail("Failed to write temporary file") end

  if stat then
    local chmod_ok, chmod_err = uv.fs_chmod(temp_path, stat.mode)
    if not chmod_ok then return fail("Failed to preserve file permissions: " .. tostring(chmod_err)) end
  end

  local rename_ok, rename_err = uv.fs_rename(temp_path, filepath)
  if not rename_ok then return fail("Failed to replace file: " .. tostring(rename_err)) end
  _file_content_lru_cache:remove(filepath)
  return true
end

function M.is_in_project(filepath)
  local Root = require("avante.utils.root")
  local project_root = Root.get()
  local abs_filepath = vim.fs.abspath(filepath)
  return abs_filepath:sub(1, #project_root) == project_root
end

function M.get_file_icon(filepath)
  local filetype = Filetype.detect(filepath, {}) or "unknown"
  ---@type string
  local icon, hl
  ---@diagnostic disable-next-line: undefined-field
  if _G.MiniIcons ~= nil then
    ---@diagnostic disable-next-line: undefined-global
    icon, hl, _ = MiniIcons.get("filetype", filetype) -- luacheck: ignore
  else
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      icon, hl = devicons.get_icon(filepath, filetype, { default = false })
      if not icon then
        icon, hl = devicons.get_icon(filepath, nil, { default = true })
        icon = icon or " "
      end
    else
      icon = ""
    end
  end
  return icon, hl
end

return M
