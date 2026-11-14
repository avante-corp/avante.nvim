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

return M
