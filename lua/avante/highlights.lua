local api = vim.api

local Config = require("avante.config")
local Utils = require("avante.utils")
local bit = require("bit")
local rshift, band = bit.rshift, bit.band

local Highlights = {
  TITLE = { name = "AvanteTitle", fg = "#1e222a", bg = "#98c379" },
  REVERSED_TITLE = { name = "AvanteReversedTitle", fg = "#98c379", bg_link = "NormalFloat" },
  SUBTITLE = { name = "AvanteSubtitle", fg = "#1e222a", bg = "#56b6c2" },
  REVERSED_SUBTITLE = { name = "AvanteReversedSubtitle", fg = "#56b6c2", bg_link = "NormalFloat" },
  THIRD_TITLE = { name = "AvanteThirdTitle", fg = "#ABB2BF", bg = "#353B45" },
  REVERSED_THIRD_TITLE = { name = "AvanteReversedThirdTitle", fg = "#353B45", bg_link = "NormalFloat" },
  SUGGESTION = { name = "AvanteSuggestion", link = "Comment" },
  ANNOTATION = { name = "AvanteAnnotation", link = "Comment" },
  POPUP_HINT = { name = "AvantePopupHint", link = "NormalFloat" },
  INLINE_HINT = { name = "AvanteInlineHint", link = "Keyword" },
  TO_BE_DELETED = { name = "AvanteToBeDeleted", bg = "#ffcccc", strikethrough = true },
  TO_BE_DELETED_WITHOUT_STRIKETHROUGH = { name = "AvanteToBeDeletedWOStrikethrough", bg = "#562C30" },
  CONFIRM_TITLE = { name = "AvanteConfirmTitle", fg = "#1e222a", bg = "#e06c75" },
  BUTTON_DEFAULT = { name = "AvanteButtonDefault", fg = "#1e222a", bg = "#ABB2BF" },
  BUTTON_DEFAULT_HOVER = { name = "AvanteButtonDefaultHover", fg = "#1e222a", bg = "#a9cf8a" },
  BUTTON_PRIMARY = { name = "AvanteButtonPrimary", fg = "#1e222a", bg = "#ABB2BF" },
  BUTTON_PRIMARY_HOVER = { name = "AvanteButtonPrimaryHover", fg = "#1e222a", bg = "#56b6c2" },
  BUTTON_DANGER = { name = "AvanteButtonDanger", fg = "#1e222a", bg = "#ABB2BF" },
  BUTTON_DANGER_HOVER = { name = "AvanteButtonDangerHover", fg = "#1e222a", bg = "#e06c75" },
  AVANTE_PROMPT_INPUT = { name = "AvantePromptInput" },
  AVANTE_PROMPT_INPUT_BORDER = { name = "AvantePromptInputBorder", link = "NormalFloat" },
  AVANTE_SIDEBAR_WIN_SEPARATOR = {
    name = "AvanteSidebarWinSeparator",
    fg_link_bg = "NormalFloat",
    bg_link = "NormalFloat",
  },
  AVANTE_SIDEBAR_WIN_HORIZONTAL_SEPARATOR = {
    name = "AvanteSidebarWinHorizontalSeparator",
    fg_link = "WinSeparator",
    bg_link = "NormalFloat",
  },
  AVANTE_SIDEBAR_NORMAL = { name = "AvanteSidebarNormal", link = "NormalFloat" },
  AVANTE_COMMENT_FG = { name = "AvanteCommentFg", fg_link = "Comment" },
  AVANTE_REVERSED_NORMAL = { name = "AvanteReversedNormal", fg_link_bg = "Normal", bg_link_fg = "Normal" },
  AVANTE_STATE_SPINNER_GENERATING = { name = "AvanteStateSpinnerGenerating", fg = "#1e222a", bg = "#ab9df2" },
  AVANTE_STATE_SPINNER_TOOL_CALLING = { name = "AvanteStateSpinnerToolCalling", fg = "#1e222a", bg = "#56b6c2" },
  AVANTE_STATE_SPINNER_FAILED = { name = "AvanteStateSpinnerFailed", fg = "#1e222a", bg = "#e06c75" },
  AVANTE_STATE_SPINNER_SUCCEEDED = { name = "AvanteStateSpinnerSucceeded", fg = "#1e222a", bg = "#98c379" },
  AVANTE_STATE_SPINNER_SEARCHING = { name = "AvanteStateSpinnerSearching", fg = "#1e222a", bg = "#c678dd" },
  AVANTE_STATE_SPINNER_THINKING = { name = "AvanteStateSpinnerThinking", fg = "#1e222a", bg = "#c678dd" },
  AVANTE_STATE_SPINNER_COMPACTING = { name = "AvanteStateSpinnerCompacting", fg = "#1e222a", bg = "#c678dd" },
  AVANTE_TASK_RUNNING = { name = "AvanteTaskRunning", fg = "#c678dd", bg_link = "Normal" },
  AVANTE_TASK_COMPLETED = { name = "AvanteTaskCompleted", fg = "#98c379", bg_link = "Normal" },
  AVANTE_TASK_FAILED = { name = "AvanteTaskFailed", fg = "#e06c75", bg_link = "Normal" },
  AVANTE_THINKING = { name = "AvanteThinking", fg = "#c678dd", bg_link = "Normal" },
  -- Gradient logo highlights
  AVANTE_LOGO_LINE_1 = { name = "AvanteLogoLine1", fg = "#f5f5f5" },
  AVANTE_LOGO_LINE_2 = { name = "AvanteLogoLine2", fg = "#e8e8e8" },
  AVANTE_LOGO_LINE_3 = { name = "AvanteLogoLine3", fg = "#dbdbdb" },
  AVANTE_LOGO_LINE_4 = { name = "AvanteLogoLine4", fg = "#cfcfcf" },
  AVANTE_LOGO_LINE_5 = { name = "AvanteLogoLine5", fg = "#c2c2c2" },
  AVANTE_LOGO_LINE_6 = { name = "AvanteLogoLine6", fg = "#b5b5b5" },
  AVANTE_LOGO_LINE_7 = { name = "AvanteLogoLine7", fg = "#a8a8a8" },
  AVANTE_LOGO_LINE_8 = { name = "AvanteLogoLine8", fg = "#9b9b9b" },
  AVANTE_LOGO_LINE_9 = { name = "AvanteLogoLine9", fg = "#8e8e8e" },
  AVANTE_LOGO_LINE_10 = { name = "AvanteLogoLine10", fg = "#818181" },
  AVANTE_LOGO_LINE_11 = { name = "AvanteLogoLine11", fg = "#747474" },
  AVANTE_LOGO_LINE_12 = { name = "AvanteLogoLine12", fg = "#676767" },
  AVANTE_LOGO_LINE_13 = { name = "AvanteLogoLine13", fg = "#5a5a5a" },
  AVANTE_LOGO_LINE_14 = { name = "AvanteLogoLine14", fg = "#4d4d4d" },
  -- Plan mode status indicators
  AVANTE_STATUS_PLAN_MODE = { name = "AvanteStatusPlanMode", fg = "#61AFEF", bold = true },
  AVANTE_STATUS_EXEC_MODE = { name = "AvanteStatusExecMode", fg = "#98c379", bold = true },
}

Highlights.conflict = {
  CURRENT = { name = "AvanteConflictCurrent", bg = "#562C30", bold = true },
  CURRENT_LABEL = { name = "AvanteConflictCurrentLabel", shade_link = "AvanteConflictCurrent", shade = 30 },
  INCOMING = { name = "AvanteConflictIncoming", bg = 3229523, bold = true }, -- #314753
  INCOMING_LABEL = { name = "AvanteConflictIncomingLabel", shade_link = "AvanteConflictIncoming", shade = 30 },
}

--- helper
local H = {}

local M = {}

local function has_set_colors(hl_group) return next(Utils.get_hl(hl_group)) ~= nil end

local first_setup = true
local already_set_highlights = {}

local function title_colors()
  local colors = Config.windows
    and Config.windows.sidebar_header
    and Config.windows.sidebar_header.title_colors
    or {}
  return vim.islist(colors) and colors or {}
end

local function setup_session_title_highlights()
  local normal_float_bg = Utils.get_hl("NormalFloat").bg
  for index, color in ipairs(title_colors()) do
    local title_name = "AvanteSessionTitle" .. index
    local reversed_name = "AvanteReversedSessionTitle" .. index
    for _, name in ipairs({ title_name, reversed_name }) do
      if first_setup and has_set_colors(name) then already_set_highlights[name] = true end
    end
    if not already_set_highlights[title_name] then
      api.nvim_set_hl(0, title_name, { fg = "#1e222a", bg = color })
    end
    if not already_set_highlights[reversed_name] then
      api.nvim_set_hl(0, reversed_name, { fg = color, bg = normal_float_bg })
    end
  end
end

function M.setup()
  if Config.behaviour.auto_set_highlight_group then
    vim
      .iter(Highlights)
      :filter(function(k, _)
        -- return all uppercase key with underscore or fully uppercase key
        return k:match("^%u+_") or k:match("^%u+$")
      end)
      :each(function(_, hl)
        if first_setup and has_set_colors(hl.name) then already_set_highlights[hl.name] = true end
        if not already_set_highlights[hl.name] then
          local bg = hl.bg
          local fg = hl.fg
          if hl.bg_link ~= nil then bg = Utils.get_hl(hl.bg_link).bg end
          if hl.fg_link ~= nil then fg = Utils.get_hl(hl.fg_link).fg end
          if hl.bg_link_fg ~= nil then bg = Utils.get_hl(hl.bg_link_fg).fg end
          if hl.fg_link_bg ~= nil then fg = Utils.get_hl(hl.fg_link_bg).bg end
          api.nvim_set_hl(
            0,
            hl.name,
            { fg = fg or nil, bg = bg or nil, link = hl.link or nil, strikethrough = hl.strikethrough }
          )
        end
      end)
    setup_session_title_highlights()
  end

  if first_setup then
    vim.iter(Highlights.conflict):each(function(_, hl)
      if hl.name and has_set_colors(hl.name) then already_set_highlights[hl.name] = true end
    end)
  end
  first_setup = false

  M.setup_conflict_highlights()
end

---@param index integer|nil
---@return string title_hl
---@return string reversed_title_hl
function M.session_title(index)
  local count = #title_colors()
  if count == 0 then return Highlights.TITLE.name, Highlights.REVERSED_TITLE.name end
  local normalized = (math.floor(tonumber(index) or 1) - 1) % count + 1
  return "AvanteSessionTitle" .. normalized, "AvanteReversedSessionTitle" .. normalized
end

function M.setup_conflict_highlights()
  local custom_hls = Config.highlights.diff

  ---@return number | nil
  local function get_bg(hl_name) return Utils.get_hl(hl_name).bg end

  local function get_bold(hl_name) return Utils.get_hl(hl_name).bold end

  vim.iter(Highlights.conflict):each(function(key, hl)
    --- set none shade linked highlights first
    if hl.shade_link ~= nil and hl.shade ~= nil then return end

    if already_set_highlights[hl.name] then return end

    local bg = hl.bg
    local bold = hl.bold

    local custom_hl_name = custom_hls[key:lower()]
    if custom_hl_name ~= nil then
      bg = get_bg(custom_hl_name) or hl.bg
      bold = get_bold(custom_hl_name) or hl.bold
    end

    api.nvim_set_hl(0, hl.name, { bg = bg, default = true, bold = bold })
  end)

  vim.iter(Highlights.conflict):each(function(key, hl)
    --- only set shade linked highlights
    if hl.shade_link == nil or hl.shade == nil then return end

    if already_set_highlights[hl.name] then return end

    local bg
    local bold = hl.bold

    local custom_hl_name = custom_hls[key:lower()]
    if custom_hl_name ~= nil then
      bg = get_bg(custom_hl_name)
      bold = get_bold(custom_hl_name) or hl.bold
    else
      local link_bg = get_bg(hl.shade_link)
      if link_bg == nil then
        Utils.warn(string.format("highlights %s don't have bg, use fallback", hl.shade_link))
        link_bg = 3229523
      end
      bg = H.shade_color(link_bg, hl.shade)
    end

    api.nvim_set_hl(0, hl.name, { bg = bg, default = true, bold = bold })
  end)
end

setmetatable(M, {
  __index = function(t, k)
    if Highlights[k] ~= nil then
      return Highlights[k].name
    elseif Highlights.conflict[k] ~= nil then
      return Highlights.conflict[k].name
    end
    return t[k]
  end,
})

--- Returns a table containing the RGB values encoded inside 24 least
--- significant bits of the number @rgb_24bit
---
---@param rgb_24bit number 24-bit RGB value
---@return {r: integer, g: integer, b: integer} with keys 'r', 'g', 'b' in [0,255]
function H.decode_24bit_rgb(rgb_24bit)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.validate("rgb_24bit", rgb_24bit, "number", true)
  else
    vim.validate({ rgb_24bit = { rgb_24bit, "number", true } })
  end
  local r = band(rshift(rgb_24bit, 16), 255)
  local g = band(rshift(rgb_24bit, 8), 255)
  local b = band(rgb_24bit, 255)
  return { r = r, g = g, b = b }
end

---@param attr integer
---@param percent integer
function H.alter(attr, percent) return math.floor(attr * (100 + percent) / 100) end

---@source https://stackoverflow.com/q/5560248
---@see https://stackoverflow.com/a/37797380
---Lighten a specified hex color
---@param color number
---@param percent number
---@return string
function H.shade_color(color, percent)
  percent = vim.opt.background:get() == "light" and percent / 5 or percent
  local rgb = H.decode_24bit_rgb(color)
  if not rgb.r or not rgb.g or not rgb.b then return "NONE" end
  local r, g, b = H.alter(rgb.r, percent), H.alter(rgb.g, percent), H.alter(rgb.b, percent)
  r, g, b = math.min(r, 255), math.min(g, 255), math.min(b, 255)
  return string.format("#%02x%02x%02x", r, g, b)
end

return M