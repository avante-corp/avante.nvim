local IS_WIN = require("avante.utils.platform").is_win ---@type boolean

local SEP = IS_WIN and "\\" or "/" ---@type string

---@class avante.utils.filesystem
local M = {}
local fn = vim.fn

M.SEP = SEP

-- Filesystem predicates follow symlinks and return false for missing targets or stat errors.
---@param filepath                      string
---@return boolean
function M.exists(filepath) return vim.uv.fs_stat(filepath) ~= nil end

---@param filepath string
---@return boolean
function M.is_regular_file(filepath)
  local stat = vim.uv.fs_stat(filepath)
  return stat ~= nil and stat.type == "file"
end

---@param filepath string
---@return boolean
function M.is_directory(filepath)
  local stat = vim.uv.fs_stat(filepath)
  return stat ~= nil and stat.type == "directory"
end

---@param filepath                      string
---@return string
function M.normalize(filepath) return vim.fs.normalize(filepath, { expand_env = false }) end

---@param filepath string
---@param cwd string
---@return string
function M.normalize_display(filepath, cwd)
  if filepath:match("^%a[%w+.-]*://") then return filepath end
  filepath = M.normalize(filepath)
  if vim.fn.isabsolutepath(filepath) == 0 then return filepath end
  cwd = M.normalize(cwd)
  if filepath == cwd then return "." end
  local prefix = cwd:gsub("/$", "") .. "/"
  -- vim.fs.relpath expands literal environment variables in filenames.
  if vim.startswith(filepath, prefix) then return filepath:sub(#prefix + 1) end
  local display = vim.fn.fnamemodify(filepath, ":~")
  return IS_WIN and display:gsub("\\", "/") or display
end

local function split(filepath)
  local normalized = M.normalize(filepath)
  if normalized == "." then return {} end
  if normalized == "/" then return { "" } end
  local pieces = vim.split(normalized, "/", { plain = true })
  if #filepath > 1 and filepath:match("[/\\]$") and normalized:sub(-1) ~= "/" then pieces[#pieces + 1] = "" end
  return pieces
end

---@param from                          string
---@param to                            string
---@param prefer_slash                  boolean
---@return string
function M.relative(from, to, prefer_slash)
  local is_from_absolute = vim.fn.isabsolutepath(from) == 1 ---@type boolean
  local is_to_absolute = vim.fn.isabsolutepath(to) == 1 ---@type boolean

  if is_from_absolute and not is_to_absolute then return M.normalize(to) end

  if is_to_absolute and not is_from_absolute then return M.normalize(to) end

  local from_pieces = split(from) ---@type string[]
  local to_pieces = split(to) ---@type string[]
  local L = #from_pieces < #to_pieces and #from_pieces or #to_pieces

  local i = 1
  while i <= L do
    if from_pieces[i] ~= to_pieces[i] then break end
    i = i + 1
  end

  if i == 2 and is_to_absolute then return M.normalize(to) end

  local sep = prefer_slash and "/" or SEP
  local p = "" ---@type string
  for _ = i, #from_pieces do
    p = p .. sep .. ".." ---@type string
  end
  for j = i, #to_pieces do
    p = p .. sep .. to_pieces[j] ---@type string
  end

  if p == "" then return "." end
  return #p > 1 and string.sub(p, 2) or p
end

---@param source string
---@param destination string
---@param opts? {hidden?: boolean, override?: boolean}
---@return true|nil, string|nil
function M.copy_dir(source, destination, opts)
  opts = opts or {}
  local flags = { excl = opts.override == false, ficlone = false, ficlone_force = false }
  source = M.normalize(vim.fn.resolve(vim.fs.abspath(source)))
  destination = M.normalize(vim.fn.resolve(vim.fs.abspath(destination)))
  local windows = vim.fn.has("win32") == 1
  local source_path = windows and source:lower() or source
  local destination_path = windows and destination:lower() or destination
  if destination_path == source_path or vim.startswith(destination_path, source_path:gsub("/$", "") .. "/") then
    return nil, "Cannot copy a directory into itself: " .. destination
  end
  local active = {} ---@type table<string, boolean>
  ---@param src string
  ---@param dst string
  local function copy_dir(src, dst)
    local real = assert(vim.uv.fs_realpath(src))
    assert(not active[real], "Directory cycle: " .. src)
    local scan = assert(vim.uv.fs_scandir(src))
    vim.fn.mkdir(dst, "p")
    active[real] = true
    for name in vim.uv.fs_scandir_next, scan do
      if opts.hidden ~= false or name:sub(1, 1) ~= "." then
        local from, to = vim.fs.joinpath(src, name), vim.fs.joinpath(dst, name)
        local stat = assert(vim.uv.fs_stat(from))
        if stat.type == "directory" then
          copy_dir(from, to)
        else
          assert(vim.uv.fs_copyfile(from, to, flags))
        end
      end
    end
    active[real] = nil
  end
  local ok, err = pcall(copy_dir, source, destination)
  if not ok then return nil, tostring(err) end
  return true
end

---@param filepath string
---@param content string
---@return true|nil, string|nil
function M.write_atomically(filepath, content)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(filepath)
  ---@type integer?, string?, string?
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
  return true
end

function M.is_in_project(filepath)
  local Root = require("avante.utils.root")
  local project_root = M.normalize(vim.fs.abspath(Root.get()))
  local abs_filepath = M.normalize(vim.fs.abspath(filepath))
  if vim.fn.has("win32") == 1 then
    project_root, abs_filepath = project_root:lower(), abs_filepath:lower()
  end
  return abs_filepath == project_root or vim.startswith(abs_filepath, project_root:gsub("/$", "") .. "/")
end

---@param filepath string
---@return string?, string?
function M.get_file_icon(filepath)
  local filetype = vim.filetype.match({ filename = filepath }) or "unknown"
  ---@type string?, string?
  local icon, hl
  ---@diagnostic disable-next-line: undefined-field
  if _G.MiniIcons ~= nil then
    ---@type {get: fun(category: string, name: string): string, string, boolean}
    local mini_icons = rawget(_G, "MiniIcons")
    icon, hl = mini_icons.get("filetype", filetype)
  else
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      ---@type {get_icon: fun(name: string, ext?: string, opts?: {default?: boolean}): string?, string?}
      local icons = devicons
      icon, hl = icons.get_icon(filepath, filetype, { default = false })
      if not icon then
        icon, hl = icons.get_icon(filepath, nil, { default = true })
        icon = icon or " "
      end
    else
      icon = ""
    end
  end
  return icon, hl
end

return M
