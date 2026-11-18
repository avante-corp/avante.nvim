---NOTE: this module is inspired by https://github.com/HakonHarnes/img-clip.nvim/tree/main
---@see https://github.com/ekickx/clipboard-image.nvim/blob/main/lua/clipboard-image/paste.lua

local Utils = require("avante.utils")
local Config = require("avante.config")
---@type {paste_image: fun(opts: table, line?: string): boolean}?
local ImgClip = nil

---@class AvanteClipboard
---
---@class avante.Clipboard: AvanteClipboard
local M = {}

---@type string?
local paste_directory = nil

---@return string
local function get_paste_directory()
  if paste_directory then return paste_directory end
  paste_directory = vim.fs.joinpath(Config.history.storage_path, "pasted_images")
  return paste_directory
end

M.support_paste_image = Config.support_paste_image

function M.setup()
  local dir = get_paste_directory()

  if not Utils.filesystem.exists(dir) then vim.fn.mkdir(dir, "p") end

  if M.support_paste_image() and ImgClip == nil then
    ---@type {paste_image: fun(opts: table, line?: string): boolean}
    ImgClip = require("img-clip")
  end
end

---@param line? string
---@return boolean
function M.paste_image(line)
  line = line or nil
  if not Config.support_paste_image() then return false end
  local dir = get_paste_directory()

  ---@type {dir_path: string, prompt_for_file_name: boolean, filetypes: table<string, table>, use_absolute_path?: boolean}
  local opts = {
    dir_path = vim.fs.abspath(dir),
    prompt_for_file_name = false,
    filetypes = {
      AvanteInput = Config.img_paste,
    },
  }

  if vim.fn.has("wsl") > 0 or vim.fn.has("win32") > 0 then opts.use_absolute_path = true end

  ---@diagnostic disable-next-line: need-check-nil, undefined-field
  return ImgClip.paste_image(opts, line)
end

---Turn one pasted line into a filesystem path, if it looks like one.
---Handles `file://` URIs (as sent by terminals for drag and drop) and quoted paths.
---@param line string
---@return string?
local function pasted_line_to_path(line)
  line = vim.trim(line)
  if line == "" then return nil end
  local quote = line:sub(1, 1)
  if (quote == "'" or quote == '"') and line:sub(-1) == quote and #line >= 2 then line = line:sub(2, -2) end
  if line:match("^file://") then
    local ok, fname = pcall(vim.uri_to_fname, line)
    if not ok then return nil end
    line = fname
  end
  line = vim.fn.expand(line)
  if not vim.uv.fs_stat(line) then return nil end
  return line
end

---Add pasted file paths to the sidebar's selected files.
---This is what drag and dropping files onto a terminal (e.g. kitty) does: it
---pastes the paths of the dropped files, one per line.
---@param lines string[]
---@return boolean true if every non-empty line was an existing path and was added
function M.paste_files(lines)
  local paths = {} ---@type string[]
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local path = pasted_line_to_path(line)
      if not path then return false end
      table.insert(paths, path)
    end
  end
  if #paths == 0 then return false end

  local sidebar = require("avante").get()
  if not sidebar or not sidebar.file_selector then return false end
  for _, path in ipairs(paths) do
    sidebar.file_selector:add_selected_file(path)
  end
  return true
end

return M
