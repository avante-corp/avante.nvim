-- lua/myplugin/platform.lua
local uv = vim.uv or vim.loop
local env = vim.env

local M = {}

local uname = uv.os_uname() -- { sysname, release, version, machine }
local sysname = (uname.sysname or ""):upper()

-- Helpers
local function file_contains(path, needle)
  local f = io.open(path, "r")
  if not f then return false end
  ---@type boolean, string?
  local ok, data = pcall(function() return f:read("*a") end)
  f:close()
  return ok and data and data:match(needle) ~= nil
end

-- Family checks
local is_windows_nt = (sysname == "WINDOWS_NT")
local is_mingw_like = sysname:find("MINGW", 1, true) ~= nil
local is_msys_like = sysname:find("MSYS", 1, true) ~= nil
local is_windowsish = is_windows_nt or is_mingw_like or is_msys_like

M.is_linux = (sysname == "LINUX")
M.is_macos = (sysname == "DARWIN")
M.is_windows_kernel = is_windowsish

-- Environment cues
local has_msystem_env = env.MSYSTEM ~= nil

-- Your policy:
-- - Only treat it as "msys2" when MSYSTEM is present.
-- - If sysname is MINGW*/MSYS* but MSYSTEM is missing, fall back to "windows".
M.is_msys2 = (is_windowsish and has_msystem_env)
M.is_win = (is_windowsish and not M.is_msys2)

-- WSL detection (only on Linux)
M.is_wsl = M.is_linux
  and (
    env.WSL_DISTRO_NAME ~= nil
    or file_contains("/proc/version", "[Mm]icrosoft")
    or file_contains("/proc/sys/kernel/osrelease", "[Mm]icrosoft")
  )

-- Human-friendly classification
M.platform = (function()
  if M.is_wsl then return "wsl" end
  if M.is_msys2 then return "msys2" end
  if M.is_win then return "windows" end
  if M.is_macos then return "macos" end
  if M.is_linux then return "linux" end
  return "unknown"
end)()

M.uname = uname

return M
