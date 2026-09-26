local IS_WIN = require("avante.utils.platform").platform == "windows" ---@type boolean

local SEP = IS_WIN and "\\" or "/" ---@type string

local BYTE_COLON = 0x3a ---@type integer ':'
local BYTE_PATHSEP = string.byte(SEP) ---@type integer

---@class avante.utils.path
local M = {}

M.SEP = SEP

---@return boolean
function M.is_win() return IS_WIN end

---@param filepath                      string
---@return boolean
function M.is_absolute(filepath)
  if type(filepath) ~= "string" or filepath == "" then return false end
  if IS_WIN then return #filepath > 1 and string.byte(filepath, 2, 2) == BYTE_COLON end
  return string.byte(filepath, 1, 1) == BYTE_PATHSEP
end

---@param filepath string
---@return string
function M.abspath(filepath)
  if filepath == "" then return "." end
  return vim.fs.abspath(filepath)
end

---@param filepath                      string
---@return boolean
function M.is_exist(filepath)
  local stat = vim.uv.fs_stat(filepath)
  return stat ~= nil and not vim.tbl_isempty(stat)
end

---@param dirpath                       string
---@return boolean
function M.is_exist_dirpath(dirpath)
  local stat = vim.uv.fs_stat(dirpath)
  return stat ~= nil and stat.type == "directory"
end

---@param filepath                      string
---@return boolean
function M.is_exist_filepath(filepath)
  local stat = vim.uv.fs_stat(filepath)
  return stat ~= nil and stat.type == "file"
end

---@param from                          string
---@param to                            string
---@return string
function M.join(from, to) return M.normalize(from .. SEP .. to) end

function M.mkdir_if_nonexist(dirpath)
  if not M.is_exist(dirpath) then vim.fn.mkdir(dirpath, "p") end
end

---@param filepath                      string
---@return string
function M.normalize(filepath)
  if filepath == "/" and not IS_WIN then return "/" end

  if filepath == "" then return "." end

  filepath = filepath:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  return table.concat(M.split(filepath), SEP)
end

---@param from                          string
---@param to                            string
---@param prefer_slash                  boolean
---@return string
function M.relative(from, to, prefer_slash)
  local is_from_absolute = M.is_absolute(from) ---@type boolean
  local is_to_absolute = M.is_absolute(to) ---@type boolean

  if is_from_absolute and not is_to_absolute then return M.normalize(to) end

  if is_to_absolute and not is_from_absolute then return M.normalize(to) end

  local from_pieces = M.split(from) ---@type string[]
  local to_pieces = M.split(to) ---@type string[]
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

---@param cwd                           string
---@param to                            string
function M.resolve(cwd, to) return M.is_absolute(to) and M.normalize(to) or M.normalize(cwd .. SEP .. to) end

---@param filepath                      string
---@return string[]
function M.split(filepath)
  local pieces = {} ---@type string[]
  local pattern = "([^/\\]+)" ---@type string
  local has_sep_prefix = SEP == "/" and string.byte(filepath, 1, 1) == BYTE_PATHSEP ---@type boolean
  local has_sep_suffix = #filepath > 1 and string.byte(filepath, #filepath, #filepath) == BYTE_PATHSEP ---@type boolean

  if has_sep_prefix then pieces[1] = "" end

  for piece in string.gmatch(filepath, pattern) do
    if piece ~= "" and piece ~= "." then
      if piece == ".." and (has_sep_prefix or #pieces > 0) then
        pieces[#pieces] = nil
      else
        pieces[#pieces + 1] = piece
      end
    end
  end

  if has_sep_suffix then pieces[#pieces + 1] = "" end

  if IS_WIN and #filepath > 1 and string.byte(filepath, 2, 2) == BYTE_COLON then pieces[1] = pieces[1]:upper() end
  return pieces
end

return M
