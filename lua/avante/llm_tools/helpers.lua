local Utils = require("avante.utils")
local Path = require("plenary.path")
local Config = require("avante.config")
local ACPConfirmAdapter = require("avante.ui.acp_confirm_adapter")

local M = {}

M.CANCEL_TOKEN = "__CANCELLED__"

-- Track cancellation state
M.is_cancelled = false
---@type avante.ui.Confirm
M.confirm_popup = nil

---@param rel_path string
---@return string
function M.get_abs_path(rel_path)
  local project_root = Utils.get_project_root()
  local p = Utils.is_absolute_path(rel_path) and rel_path or vim.fs.normalize(vim.fs.joinpath(project_root, rel_path))
  if p:sub(-2) == "/." then p = p:sub(1, -3) end
  return p
end

---@type avante.acp.PermissionOption[]
local default_permission_options = {
  { optionId = "allow_always", name = "Allow Always", kind = "allow_always" },
  { optionId = "allow_once", name = "Allow", kind = "allow_once" },
  { optionId = "reject_once", name = "Reject", kind = "reject_once" },
}

---@param callback fun(option_id: string)
---@param confirm_opts avante.ui.ConfirmOptions
function M.confirm_inline(callback, confirm_opts)
  local sidebar = require("avante").get()
  local items =
    ACPConfirmAdapter.generate_buttons_for_acp_options(confirm_opts.permission_options or default_permission_options)

  sidebar.permission_button_options = items
  sidebar.permission_handler = function(id)
    callback(id)
    sidebar.scroll = true
    sidebar.permission_button_options = nil
    sidebar.permission_handler = nil
    sidebar._history_cache_invalidated = true
    sidebar:update_content("")
  end
end

---@param message string
---@param callback fun(response: boolean, reason?: string)
---@param confirm_opts? avante.ui.ConfirmOptions
---@param session_ctx? table
---@param tool_name? string -- Optional tool name to check against tool_permissions config
---@return avante.ui.Confirm | nil
function M.confirm(message, callback, confirm_opts, session_ctx, tool_name)
  callback = vim.schedule_wrap(callback)
  if session_ctx and session_ctx.always_yes then
    callback(true)
    return
  end

  -- Check behaviour.auto_approve_tool_permissions config for auto-approval
  local auto_approve = Config.behaviour.auto_approve_tool_permissions

  -- If auto_approve is true, auto-approve all tools
  if auto_approve == true then
    callback(true)
    return
  end

  -- If auto_approve is a table (array of tool names), check if this tool is in the list
  if type(auto_approve) == "table" and vim.tbl_contains(auto_approve, tool_name) then
    callback(true)
    return
  end

  if Config.behaviour.confirmation_ui_style == "inline_buttons" then
    M.confirm_inline(function(option_id)
      if option_id == "allow" or option_id == "allow_once" or option_id == "allow_always" then
        if option_id == "allow_always" and session_ctx then session_ctx.always_yes = true end

        callback(true)
      else
        callback(false, option_id)
      end
    end, confirm_opts or {})
    return
  end

  local Confirm = require("avante.ui.confirm")
  local sidebar = require("avante").get()
  if not sidebar or not sidebar.containers.input or not sidebar.containers.input.winid then
    Utils.error("Avante sidebar not found", { title = "Avante" })
    callback(false)
    return
  end
  confirm_opts = vim.tbl_deep_extend("force", { container_winid = sidebar.containers.input.winid }, confirm_opts or {})
  if M.confirm_popup then M.confirm_popup:close() end
  M.confirm_popup = Confirm:new(message, function(type, reason)
    if type == "yes" then
      callback(true)
    elseif type == "all" then
      if session_ctx then session_ctx.always_yes = true end
      callback(true)
    elseif type == "no" then
      callback(false, reason)
    end
    M.confirm_popup = nil
  end, confirm_opts)
  M.confirm_popup:open()
  return M.confirm_popup
end

---@param abs_path string
---@return boolean
local function old_is_ignored(abs_path)
  local project_root = Utils.get_project_root()
  local gitignore_path = project_root .. "/.gitignore"
  local gitignore_patterns, gitignore_negate_patterns = Utils.parse_gitignore(gitignore_path)
  -- The checker should only take care of the path inside the project root
  -- Specifically, it should not check the project root itself
  -- Otherwise if the binary is named the same as the project root (such as Go binary), any paths
  -- insde the project root will be ignored
  local rel_path = Utils.make_relative_path(abs_path, project_root)
  return Utils.is_ignored(rel_path, gitignore_patterns, gitignore_negate_patterns)
end

---Is path git ignored
---@param abs_path string
---@return boolean
function M.is_ignored(abs_path)
  local project_root = Utils.get_project_root()
  local exit_code = vim.system({ "git", "-C", project_root, "check-ignore", abs_path }, { text = true }):wait().code

  -- If command failed or git is not available or not a git repository, fall back to old method
  if exit_code ~= 0 and exit_code ~= 1 then return old_is_ignored(abs_path) end

  -- git check-ignore returns:
  -- - exit code 0 and outputs the path to stdout if the file is ignored
  -- - exit code 1 and no output to stdout if the file is not ignored
  -- - exit code 128 and outputs the error info to stderr not stdout
  return exit_code == 0
end

---Check whether path is root or inside it, using path-component boundaries.
---@param path string
---@param root string
---@return boolean
function M.is_path_within(path, root)
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root)
  if root == "" then return false end
  if path == root then return true end
  root = root:gsub("/+$", "")
  return path:sub(1, #root + 1) == root .. "/"
end

---Check whether path is inside an allowed root, including a canonicalized root.
---@param path string
---@param root string
---@return boolean
local function is_within_allowed_root(path, root)
  if M.is_path_within(path, root) then return true end
  local real_root = vim.uv.fs_realpath(root)
  return real_root ~= nil and M.is_path_within(path, real_root)
end

---Check if path belongs to allowed directories
---@param abs_path string
---@return boolean
function M.has_permission_to_access(abs_path)
  if not Path:new(abs_path):is_absolute() then return false end
  abs_path = vim.fs.normalize(abs_path)
  local project_root = vim.fs.normalize(Utils.get_project_root())
  -- allow if inside project root OR inside user config dir
  local config_dir = vim.fs.normalize(vim.fn.stdpath("config"))
  local in_project = is_within_allowed_root(abs_path, project_root)
  local in_config = is_within_allowed_root(abs_path, config_dir)
  local bypass_ignore = Config.behaviour and Config.behaviour.allow_access_to_git_ignored_files
  if not in_project and not in_config then return false end
  return bypass_ignore or not M.is_ignored(abs_path)
end

---@param path string
---@return boolean
function M.already_in_context(path)
  local sidebar = require("avante").get()
  if sidebar and sidebar.file_selector then
    local rel_path = Utils.uniform_path(path)
    return vim.tbl_contains(sidebar.file_selector.selected_filepaths, rel_path)
  end
  return false
end

---@param path string
---@param session_ctx table
---@return boolean
function M.already_viewed(path, session_ctx)
  local view_history = session_ctx.view_history or {}
  local uniform_path = Utils.uniform_path(path)
  if view_history[uniform_path] then return true end
  return false
end

---@param path string
---@param session_ctx table
function M.mark_as_viewed(path, session_ctx)
  local view_history = session_ctx.view_history or {}
  local uniform_path = Utils.uniform_path(path)
  view_history[uniform_path] = true
  session_ctx.view_history = view_history
end

function M.mark_as_not_viewed(path, session_ctx)
  local view_history = session_ctx.view_history or {}
  local uniform_path = Utils.uniform_path(path)
  view_history[uniform_path] = nil
  session_ctx.view_history = view_history
end

---@param abs_path string
---@return integer bufnr
---@return string | nil error
function M.get_bufnr(abs_path)
  local sidebar = require("avante").get()
  if not sidebar then return 0, "Avante sidebar not found" end
  local bufnr ---@type integer
  vim.api.nvim_win_call(sidebar.code.winid, function()
    ---@diagnostic disable-next-line: param-type-mismatch
    pcall(vim.cmd, "edit " .. abs_path)
    bufnr = vim.api.nvim_get_current_buf()
  end)
  return bufnr, nil
end

return M
