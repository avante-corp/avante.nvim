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

--- Cleans up old DLLs renamed by the build script in Windows.
--- It runs in the background so as not to block startup time.
function M.clean_windows_dll_trash()
  if vim.fn.has("win32") == 0 then return end

  vim.defer_fn(function()
    local trash_files = vim.api.nvim_get_runtime_file("lua/avante_*.dll.old", true)

    for _, file in ipairs(trash_files) do
      pcall(vim.fn.delete, file)
    end
  end, 2000)
end

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
