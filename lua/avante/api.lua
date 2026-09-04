---@mod avante-api Avante API
---
---@brief [[
---A collection of functions to build your own avante experience.
---@brief ]]
local Config = require("avante.config")
local Utils = require("avante.utils")

---@class avante.ApiToggle
---@operator call(): boolean
---@field debug ToggleBind.wrap
---@field hint ToggleBind.wrap

---@class avante.Api
---@field toggle avante.ApiToggle
local M = {}

---@param target_provider avante.SelectorProvider
function M.switch_selector_provider(target_provider)
  require("avante.config").override({
    selector = {
      provider = target_provider,
    },
  })
end

---@param target_provider avante.InputProvider
function M.switch_input_provider(target_provider)
  require("avante.config").override({
    input = {
      provider = target_provider,
    },
  })
end

---@param target avante.ProviderName
function M.switch_provider(target) require("avante.providers").refresh(target) end

---@param path string
local function to_windows_path(path)
  local winpath = path:gsub("/", "\\")

  if winpath:match("^%a:") then winpath = winpath:sub(1, 2):upper() .. winpath:sub(3) end

  winpath = winpath:gsub("\\$", "")

  return winpath
end

---Command to install the necessary rust libraries
---Defaults to download the libraries but passing `source=true` will force a local build via cargo
---Blocking as it waits for cargo to finish
---@param opts? {source: boolean}
function M.build(opts)
  opts = opts or { source = true }
  local dirname = Utils.trim(string.sub(debug.getinfo(1).source, 2, #"/init.lua" * -1), { suffix = "/" })
  local git_root = vim.fs.find(".git", { path = dirname, upward = true })[1]
  local build_directory = git_root and vim.fn.fnamemodify(git_root, ":h") or (dirname .. "/../../")

  if opts.source and vim.fn.executable("cargo") == 0 then
    error("Building avante.nvim requires cargo to be installed.", 2)
  end

  ---@type string[]
  local cmd
  local os_name = Utils.get_os_name()

  if vim.tbl_contains({ "linux", "darwin" }, os_name) then
    cmd = opts.source == true and {
      "sh",
      "-c",
      string.format("make -C %s", build_directory),
    } or { "sh", string.format("%s/build.sh", build_directory) }
  elseif os_name == "windows" then
    build_directory = to_windows_path(build_directory)
    cmd = {
      "powershell",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      string.format("%s\\Build.ps1", build_directory),
      "-WorkingDirectory",
      build_directory,
      "-BuildFromSource",
      string.format("%s", opts.source == true and "true" or "false"),
    }
  else
    error("Unsupported operating system: " .. os_name, 2)
  end

  local cmd_str = table.concat(cmd, " ")
  Utils.info("Starting command " .. cmd_str)
  local ok, job_or_err = pcall(vim.system, cmd, { text = true }, function(obj)
    if obj.code == 0 then
      local output = obj.stdout

      Utils.debug({ "build output:", output })
    else
      Utils.error({ "build error (stderr):", obj.stderr })
    end
  end)
  if not ok then Utils.error("Failed to run the build command: " .. cmd_str .. "\n" .. job_or_err, { once = true }) end

  return job_or_err:wait()
end

---@class AskOptions
---@field question? string optional questions
---@field win? table<string, any> windows options similar to |nvim_open_win()|
---@field ask? boolean
---@field floating? boolean whether to open a floating input to enter the question
---@field new_chat? boolean whether to open a new chat
---@field without_selection? boolean whether to open a new chat without selection
---@field sidebar_pre_render? fun(sidebar: avante.Sidebar)
---@field sidebar_post_render? fun(sidebar: avante.Sidebar)
---@field project_root? string optional project root
---@field show_logo? boolean whether to show the logo

function M.full_view_ask()
  M.ask({
    show_logo = true,
    sidebar_post_render = function(sidebar)
      sidebar:toggle_code_window()
      -- vim.wo[sidebar.containers.result.winid].number = true
      -- vim.wo[sidebar.containers.result.winid].relativenumber = true
    end,
  })
end

M.zen_mode = M.full_view_ask

---@param opts? AskOptions
function M.ask(opts)
  opts = opts or {}
  Config.ask_opts = opts
  if type(opts) == "string" then
    Utils.warn("passing 'ask' as string is deprecated, do {question = '...'} instead", { once = true })
    opts = { question = opts }
  end

  local has_question = opts.question ~= nil and opts.question ~= ""
  local new_chat = opts.new_chat == true

  if Utils.is_sidebar_buffer(0) and not has_question and not new_chat then
    require("avante").close_sidebar()
    return false
  end

  opts = vim.tbl_extend("force", { selection = Utils.get_visual_selection_and_range() }, opts)

  ---@param input string | nil
  local function ask(input)
    if input == nil or input == "" then input = opts.question end
    local sidebar = require("avante").get()
    if sidebar and sidebar:is_open() and sidebar.code.bufnr ~= vim.api.nvim_get_current_buf() then
      sidebar:close({ goto_code_win = false })
    end
    require("avante").open_sidebar(opts)
    sidebar = require("avante").get()
    if new_chat then sidebar:new_chat() end
    if opts.without_selection then
      sidebar.code.selection = nil
      sidebar.file_selector:reset()
      if sidebar.containers.selected_files then sidebar.containers.selected_files:unmount() end
    end
    if input == nil or input == "" then return true end
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteInputSubmitted", data = { request = input } })
    return true
  end

  if opts.floating == true or (Config.windows.ask.floating == true and not has_question and opts.floating == nil) then
    local PromptInput = require("avante.ui.prompt_input")
    local prompt_input = PromptInput:new({
      submit_callback = function(input) ask(input) end,
      close_on_submit = true,
      win_opts = {
        border = Config.windows.ask.border,
        title = { { "Avante Ask", "FloatTitle" } },
      },
      start_insert = Config.windows.ask.start_insert,
      default_value = opts.question,
    })
    prompt_input:open()
    return true
  end

  return ask()
end

---@param request? string
---@param line1? integer
---@param line2? integer
function M.edit(request, line1, line2)
  local _, selection = require("avante").get()
  if not selection then require("avante")._init(vim.api.nvim_get_current_tabpage()) end
  _, selection = require("avante").get()
  if not selection then return end
  selection:create_editing_input(request, line1, line2)
  if request ~= nil and request ~= "" then
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteEditSubmitted", data = { request = request } })
  end
end

---@return avante.Suggestion | nil
function M.get_suggestion()
  local _, _, suggestion = require("avante").get()
  return suggestion
end

---@param opts? AskOptions
function M.refresh(opts)
  opts = opts or {}
  local sidebar = require("avante").get()
  if not sidebar then return end
  if not sidebar:is_open() then return end
  local curbuf = vim.api.nvim_get_current_buf()

  local focused = sidebar.containers.result.bufnr == curbuf or sidebar.containers.input.bufnr == curbuf
  if focused or not sidebar:is_open() then return end
  local listed = vim.api.nvim_get_option_value("buflisted", { buf = curbuf })

  if Utils.is_sidebar_buffer(curbuf) or not listed then return end

  local curwin = vim.api.nvim_get_current_win()

  sidebar:close()
  sidebar.code.winid = curwin
  sidebar.code.bufnr = curbuf
  sidebar:render(opts)
end

---@param opts? AskOptions
function M.focus(opts)
  opts = opts or {}
  local sidebar = require("avante").get()
  if not sidebar then return end

  local curbuf = vim.api.nvim_get_current_buf()
  local curwin = vim.api.nvim_get_current_win()

  if sidebar:is_open() then
    if curbuf == sidebar.containers.input.bufnr then
      if sidebar.code.winid and sidebar.code.winid ~= curwin then vim.api.nvim_set_current_win(sidebar.code.winid) end
    elseif curbuf == sidebar.containers.result.bufnr then
      if sidebar.code.winid and sidebar.code.winid ~= curwin then vim.api.nvim_set_current_win(sidebar.code.winid) end
    else
      if sidebar.containers.input.winid and sidebar.containers.input.winid ~= curwin then
        vim.api.nvim_set_current_win(sidebar.containers.input.winid)
      end
    end
  else
    if sidebar.code.winid then vim.api.nvim_set_current_win(sidebar.code.winid) end
    ---@cast opts SidebarOpenOptions
    sidebar:open(opts)
    if sidebar.containers.input.winid then vim.api.nvim_set_current_win(sidebar.containers.input.winid) end
  end
end

---Select a model from current provider (default) or all providers
---@param all? boolean
---Saves the choice to stdpath("state")
function M.select_model(all) require("avante.model_selector").open(all) end

function M.select_acp_model() require("avante.acp_config_selector").open_model() end

function M.select_acp_mode() require("avante.acp_config_selector").open_mode() end

function M.select_history()
  local buf = vim.api.nvim_get_current_buf()
  require("avante.history_selector").open(buf, function(filename)
    vim.api.nvim_buf_call(buf, function()
      if not require("avante").is_sidebar_open() then require("avante").open_sidebar({}) end
      local Path = require("avante.path")
      Path.history.save_latest_filename(buf, filename)
      local sidebar = require("avante").get()
      sidebar:update_content_with_history()
      sidebar:create_todos_container()
      sidebar:initialize_token_count()
      vim.schedule(function() sidebar:focus_input() end)
    end)
  end)
end

function M.add_buffer_files()
  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end
  sidebar.file_selector:add_buffer_files()
end

function M.add_selected_file(filepath)
  local rel_path = Utils.uniform_path(filepath)

  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end
  sidebar.file_selector:add_selected_file(rel_path)
end

function M.remove_selected_file(filepath)
  ---@diagnostic disable-next-line: undefined-field
  local stat = vim.uv.fs_stat(filepath)
  local files
  if stat and stat.type == "directory" then
    files = Utils.scan_directory({ directory = filepath, add_dirs = true })
  else
    files = { filepath }
  end

  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end

  for _, file in ipairs(files) do
    local rel_path = Utils.uniform_path(file)
    sidebar.file_selector:remove_selected_file(rel_path)
  end
end

function M.stop() require("avante.llm").cancel_inflight_request() end

---@export M
return setmetatable(M, {
  __index = function(t, k)
    local module = require("avante")
    ---@class AvailableApi: ApiCaller
    ---@field api? boolean
    local has = module[k]
    if type(has) ~= "table" or not has.api then
      Utils.warn(k .. " is not a valid avante's API method", { once = true })
      return
    end
    t[k] = has
    return t[k]
  end,
}) --[[@as avante.Api]]
