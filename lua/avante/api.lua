local Config = require("avante.config")
local Utils = require("avante.utils")
local PromptInput = require("avante.ui.prompt_input")

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

---@param opts? {source: boolean}
function M.build(opts)
  opts = opts or { source = true }
  local dirname = Utils.trim(string.sub(debug.getinfo(1).source, 2, #"/init.lua" * -1), { suffix = "/" })
  local git_root = vim.fs.find(".git", { path = dirname, upward = true })[1]
  local build_directory = git_root and vim.fn.fnamemodify(git_root, ":h") or (dirname .. "/../../")

  if opts.source and not vim.fn.executable("cargo") then
    error("Building avante.nvim requires cargo to be installed.", 2)
  end

  ---@type string[]
  local cmd
  local os_name = Utils.get_os_name()

  if vim.tbl_contains({ "linux", "darwin" }, os_name) then
    cmd = {
      "sh",
      "-c",
      string.format("make BUILD_FROM_SOURCE=%s -C %s", opts.source == true and "true" or "false", build_directory),
    }
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

  ---@type integer
  local pid
  local exit_code = { 0 }

  local ok, job_or_err = pcall(vim.system, cmd, { text = true }, function(obj)
    local stderr = obj.stderr and vim.split(obj.stderr, "\n") or {}
    local stdout = obj.stdout and vim.split(obj.stdout, "\n") or {}
    if vim.tbl_contains(exit_code, obj.code) then
      local output = stdout
      if #output == 0 then
        table.insert(output, "")
        Utils.debug("build output:", output)
      else
        Utils.debug("build error:", stderr)
      end
    end
  end)
  if not ok then Utils.error("Failed to build the command: " .. cmd .. "\n" .. job_or_err, { once = true }) end
  pid = job_or_err.pid
  return pid
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
    -- Skip ACP connect and session restore on open if new_chat — new_thread() handles everything
    local open_opts = vim.tbl_extend("force", opts, {})
    if new_chat then
      open_opts.skip_acp_connect = true
      open_opts.skip_session_restore = true
      open_opts.new_chat = true
    end
    require("avante").open_sidebar(open_opts)
    sidebar = require("avante").get()
    if new_chat then
      sidebar:new_thread({
        avante_mode = opts.avante_mode,
        acp_provider = opts.acp_provider,
        starter_prompt = opts.starter_prompt,
      })
    end
    if opts.without_selection then
      sidebar.code.selection = nil
      sidebar.file_selector:reset()
      if sidebar.containers.selected_files then sidebar.containers.selected_files:unmount() end
    end
    if input == nil or input == "" then return true end
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteInputSubmitted", data = { request = input } })
    return true
  end

  if opts.floating == true or (Config.windows and Config.windows.ask and Config.windows.ask.floating == true and not has_question and opts.floating == nil) then
    local ask_config = (Config.windows and Config.windows.ask) or {}
    local prompt_input = PromptInput:new({
      submit_callback = function(input) ask(input) end,
      close_on_submit = true,
      win_opts = {
        border = ask_config.border or "rounded",
        title = { { "Avante Ask", "FloatTitle" } },
      },
      start_insert = ask_config.start_insert ~= false,
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

function M.select_model() require("avante.model_selector").open() end

function M.select_history()
  local buf = vim.api.nvim_get_current_buf()
  require("avante.history_selector").open(buf, function(filename)
    vim.api.nvim_buf_call(buf, function()
      if not require("avante").is_sidebar_open() then require("avante").open_sidebar({ skip_acp_connect = true }) end
      local Path = require("avante.path")
      Path.history.save_latest_filename(buf, filename)
      local sidebar = require("avante").get()
      sidebar:update_content_with_history()
      sidebar:create_plan_container()
      sidebar:initialize_token_count()
      vim.schedule(function() sidebar:focus_input() end)
    end)
  end)
end

function M.select_prompt()
  require("avante.prompt_selector").open()
end

---Shared callback factory for thread viewer pickers
---@param buf integer
---@return fun(filename: string, external_session_id?: string, history?: avante.ChatHistory)
local function make_thread_open_callback(buf)
  return function(filename, external_session_id, history)
    vim.api.nvim_buf_call(buf, function()
      if not require("avante").is_sidebar_open() then require("avante").open_sidebar({ skip_acp_connect = true }) end
      local Path = require("avante.path")
      local Utils = require("avante.utils")
      local sidebar = require("avante").get()

      -- Change to the thread's working directory first (critical for cross-project threads)
      local wd = history and history.working_directory
      if not wd and external_session_id then
        local thread_viewer = require("avante.thread_viewer")
        local external_info = thread_viewer.get_external_session_info(external_session_id)
        if external_info then wd = external_info.working_directory end
      end
      if wd and vim.fn.isdirectory(wd) == 1 then
        vim.cmd("cd " .. vim.fn.fnameescape(wd))
        Utils.info("Changed directory to: " .. wd)
      end

      -- Handle external ACP sessions (sessions created outside Avante)
      if external_session_id then
        sidebar:reload_chat_history()
        sidebar.chat_history.acp_session_id = external_session_id
        if wd then sidebar.chat_history.working_directory = wd end
        Path.history.save(sidebar.code.bufnr, sidebar.chat_history)
        Path.history.save_latest_filename(sidebar.code.bufnr, sidebar.chat_history.filename)
      elseif history and history.messages then
        -- Handle regular Avante history — use the history object directly.
        -- Guarded on `messages`: the thread picker lists lightweight summaries
        -- that carry none, and saving one of those would overwrite the stored
        -- conversation with an empty stub. thread_viewer.hydrate() fills them
        -- in; this is the backstop for when that fails.
        sidebar.chat_history = history
        Path.history.save(sidebar.code.bufnr, history)
        Path.history.save_latest_filename(sidebar.code.bufnr, history.filename)
      elseif history then
        Utils.warn("Thread contents could not be loaded; opening from disk instead")
        Path.history.save_latest_filename(sidebar.code.bufnr, history.filename)
        sidebar:reload_chat_history()
      else
        Path.history.save_latest_filename(sidebar.code.bufnr, filename)
        sidebar:reload_chat_history()
      end

      -- Restore selected files from history
      local loaded_history = sidebar.chat_history
      if loaded_history and loaded_history.selected_files and sidebar.file_selector then
        sidebar.file_selector.selected_files = {}
        for _, filepath in ipairs(loaded_history.selected_files) do
          sidebar.file_selector:add_selected_file(filepath)
        end
      end

      if loaded_history then
        loaded_history.last_seen_message_count = #(loaded_history.messages or {})
        Path.history.save(sidebar.code.bufnr, loaded_history)
      end

      -- Fold the backlog so an old thread opens readable: only the most
      -- recent turn is expanded.
      if Config.collapse_threads_on_open ~= false then
        sidebar:collapse_all_messages({ keep_last = true, silent = true, defer_render = true })
      end

      -- Update UI
      sidebar:update_content_with_history()
      sidebar:create_plan_container()
      sidebar:initialize_token_count()

      -- Connect ACP — will load existing session if acp_session_id present, or create new
      sidebar:connect_acp({
        on_ready = function()
          vim.schedule(function() sidebar:focus_input() end)
        end,
      })
    end)
  end
end

function M.view_threads()
  local buf = vim.api.nvim_get_current_buf()
  require("avante.thread_viewer").open(buf, make_thread_open_callback(buf))
end

function M.view_pinned_threads()
  local buf = vim.api.nvim_get_current_buf()
  require("avante.thread_viewer").open(buf, make_thread_open_callback(buf), { filter = "pinned", show_unread = true })
end

---Get sorted list of pinned thread filenames
---@return string[] filenames
---@return integer current_index (0 if current thread is not pinned)
local function get_pinned_thread_list()
  local Path = require("avante.path")
  local History = require("avante.history")
  local all = Path.history.list_all()
  local pinned = {}
  for _, h in ipairs(all) do
    if h.pinned then table.insert(pinned, h) end
  end
  -- Sort by most recent message timestamp descending
  table.sort(pinned, function(a, b)
    local a_msgs = History.get_history_messages(a)
    local b_msgs = History.get_history_messages(b)
    local a_time = #a_msgs > 0 and a_msgs[#a_msgs].timestamp or a.timestamp
    local b_time = #b_msgs > 0 and b_msgs[#b_msgs].timestamp or b.timestamp
    return a_time > b_time
  end)
  -- Find current thread index
  local sidebar = require("avante").get()
  local current_filename = sidebar and sidebar.chat_history and sidebar.chat_history.filename or nil
  local current_idx = 0
  local filenames = {}
  for i, h in ipairs(pinned) do
    table.insert(filenames, h.filename)
    if current_filename and h.filename == current_filename then
      current_idx = i
    end
  end
  return filenames, current_idx
end

---Cycle to next/prev pinned thread
---@param direction integer 1 for next, -1 for prev
local function cycle_pinned_thread(direction)
  local Utils = require("avante.utils")
  local Path = require("avante.path")
  local filenames, current_idx = get_pinned_thread_list()
  if #filenames == 0 then
    Utils.warn("No pinned threads. Use /pin to pin a thread.")
    return
  end
  local next_idx
  if current_idx == 0 then
    -- Not on a pinned thread, go to first
    next_idx = 1
  else
    next_idx = ((current_idx - 1 + direction) % #filenames) + 1
  end
  local buf = vim.api.nvim_get_current_buf()
  local open_cb = make_thread_open_callback(buf)
  open_cb(filenames[next_idx])
end

---Switch to the next pinned thread
function M.next_pinned_thread()
  cycle_pinned_thread(1)
end

---Switch to the previous pinned thread
function M.prev_pinned_thread()
  cycle_pinned_thread(-1)
end

--- Open sidebar with a new chat in a specific directory
---@param dir string Absolute path to cd into
---@param title string|nil Optional thread title
---@param avante_mode string|nil Optional avante mode name
---@param template table|nil Optional template: may pin an agent and a starter prompt
local function open_new_chat_in_dir(dir, title, avante_mode, template)
  local Utils = require("avante.utils")
  local Path = require("avante.path")

  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  Utils.info("Changed directory to: " .. dir)

  require("avante").open_sidebar({ skip_acp_connect = true, skip_session_restore = true })
  local sidebar = require("avante").get()
  if sidebar then
    sidebar:new_thread({
      avante_mode = avante_mode,
      acp_provider = template and template.acp_provider or nil,
      starter_prompt = template and template.starter_prompt or nil,
    })
    if title and sidebar.chat_history then
      sidebar.chat_history.title = title
      Path.history.save(sidebar.code.bufnr, sidebar.chat_history)
      sidebar:show_input_hint()
    end
  end
end

--- Create a git worktree and start a new chat in it
---@param worktree_name string
function M.new_worktree_chat(worktree_name)
  local Utils = require("avante.utils")
  local Config = require("avante.config")

  local git_root = Utils.root.git()

  -- Validate we're in a git repo
  local check = vim.system({ "git", "-C", git_root, "rev-parse", "--git-dir" }, { text = true }):wait()
  if check.code ~= 0 then
    Utils.error("Not in a git repository")
    return
  end

  -- Determine worktree target path
  local worktrees_root = Config.behaviour and Config.behaviour.worktrees_root
  local base_dir = worktrees_root and vim.fn.expand(worktrees_root) or vim.fn.fnamemodify(git_root, ":h")
  local worktree_path = base_dir .. "/" .. worktree_name

  -- Prune stale worktrees before creating a new one
  vim.system({ "git", "-C", git_root, "worktree", "prune" }, { text = true }):wait()

  -- Create the worktree
  Utils.info("Creating worktree: " .. worktree_path)
  local result = vim.system(
    { "git", "-C", git_root, "worktree", "add", worktree_path, "-b", worktree_name },
    { text = true }
  ):wait()

  if result.code ~= 0 then
    Utils.error("Failed to create worktree: " .. (result.stderr or "unknown error"))
    return
  end

  open_new_chat_in_dir(worktree_path, worktree_name)
end

--- List existing git worktrees (excluding the main worktree)
---@return {name: string, path: string}[]
local function list_worktrees()
  local Utils = require("avante.utils")
  local git_root = Utils.root.git()
  local result = vim.system({ "git", "-C", git_root, "worktree", "list", "--porcelain" }, { text = true }):wait()
  if result.code ~= 0 then return {} end

  local worktrees = {}
  local current_path = nil
  for line in result.stdout:gmatch("[^\n]+") do
    if line:match("^worktree ") then
      current_path = line:sub(10)
    elseif line:match("^branch ") and current_path then
      -- Skip the main worktree (same as git root)
      if current_path ~= git_root then
        local name = vim.fn.fnamemodify(current_path, ":t")
        table.insert(worktrees, { name = name, path = current_path })
      end
      current_path = nil
    end
  end
  return worktrees
end

--- Show avante mode picker, then call the action with the selected mode.
--- If default_avante_mode is set, skips the picker. If no modes configured, skips.
---@param action fun(avante_mode: string|nil)
local function pick_avante_mode(action)
  local Config = require("avante.config")
  local modes = Config.avante_modes or {}

  -- If no modes configured, skip picker
  if #modes == 0 then
    action(nil)
    return
  end

  -- If default is set, skip picker
  if Config.default_avante_mode then
    action(Config.default_avante_mode)
    return
  end

  -- Build selection list
  local items = {}
  for _, m in ipairs(modes) do
    table.insert(items, m)
  end
  table.insert(items, { name = "none", description = "No mode" })

  vim.ui.select(items, {
    prompt = "Select mode:",
    format_item = function(item)
      if item.name == "none" then return "No mode" end
      local label = item.name .. " — " .. item.description
      -- Surface what the template will actually do, so the choice is informed.
      if item.acp_provider then label = label .. "  [" .. item.acp_provider .. "]" end
      if item.starter_prompt then label = label .. "  [starts a prompt]" end
      return label
    end,
  }, function(choice)
    if not choice then return end
    if choice.name == "none" then
      action(nil, nil)
      return
    end
    -- Second value is the full template: callers need its acp_provider and
    -- starter_prompt, not just the name.
    action(choice.name, choice)
  end)
end

--- Pick the ACP provider for a new chat.
---
--- Skipped when a template already pins one, when disabled, or when there is
--- nothing to choose between.
---@param template table|nil
---@param action fun(provider: string|nil)
local function pick_acp_provider(template, action)
  local Config = require("avante.config")

  if template and template.acp_provider then
    action(template.acp_provider)
    return
  end
  if Config.ask_acp_provider_on_new_chat == false then
    action(nil)
    return
  end

  -- Only what the config file declares. Config.acp_providers is a deep merge
  -- with avante's built-in table, so using it would list every agent avante
  -- knows about -- most of them not installed.
  local names = Config._user_acp_provider_names or {}
  if #names < 2 then
    action(nil)
    return
  end

  local items = { { name = nil, label = "Default ACP provider (" .. tostring(Config.provider) .. ")" } }
  for _, name in ipairs(names) do
    table.insert(items, { name = name, label = name })
  end

  vim.ui.select(items, {
    prompt = "Select ACP provider:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    action(choice.name)
  end)
end

--- Show a telescope picker for creating a new chat: current dir, repo root, worktrees, favorite dirs
---@param ask_args table|nil Arguments to pass through to api.ask for "use current" path
function M.new_chat_picker(ask_args)
  local Utils = require("avante.utils")
  local Config = require("avante.config")

  local worktrees_root = Config.behaviour and Config.behaviour.worktrees_root
  local favorite_root_dirs = Config.behaviour and Config.behaviour.favorite_root_dirs or {}

  -- Build entries before deciding whether to show the picker
  local entries = {}
  local cwd = vim.fn.getcwd()
  local cwd_abs = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")

  -- "Use current directory" option (always first)
  table.insert(entries, {
    display = "📂 " .. vim.fn.fnamemodify(cwd, ":~"),
    ordinal = "use current directory " .. cwd,
    action = "current",
  })

  -- Git repo root (if different from cwd)
  local git_root = Utils.root.git()
  if git_root then
    local git_root_abs = vim.fn.fnamemodify(git_root, ":p"):gsub("/$", "")
    if git_root_abs ~= cwd_abs then
      table.insert(entries, {
        display = "📁 " .. vim.fn.fnamemodify(git_root, ":t") .. " (" .. vim.fn.fnamemodify(git_root, ":~") .. ")",
        ordinal = "repo root " .. git_root,
        action = "dir",
        dir = git_root,
        title = vim.fn.fnamemodify(git_root, ":t"),
      })
    end
  end

  -- Favorite root dirs from config
  for _, dir_raw in ipairs(favorite_root_dirs) do
    local dir = vim.fn.expand(dir_raw)
    if vim.fn.isdirectory(dir) == 1 then
      local dir_abs = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
      -- Skip if same as cwd or git root (already listed)
      if dir_abs ~= cwd_abs and (not git_root or dir_abs ~= vim.fn.fnamemodify(git_root, ":p"):gsub("/$", "")) then
        table.insert(entries, {
          display = "⭐ " .. vim.fn.fnamemodify(dir, ":t") .. " (" .. vim.fn.fnamemodify(dir, ":~") .. ")",
          ordinal = "favorite " .. dir,
          action = "dir",
          dir = dir,
          title = vim.fn.fnamemodify(dir, ":t"),
        })
      end
    end
  end

  -- Existing worktrees (only if worktrees_root is configured)
  if worktrees_root then
    local worktrees = list_worktrees()
    for _, wt in ipairs(worktrees) do
      local wt_abs = vim.fn.fnamemodify(wt.path, ":p"):gsub("/$", "")
      if wt_abs ~= cwd_abs then
        table.insert(entries, {
          display = "🌲 " .. wt.name .. " (" .. vim.fn.fnamemodify(wt.path, ":~") .. ")",
          ordinal = wt.name .. " " .. wt.path,
          action = "dir",
          dir = wt.path,
          title = wt.name,
        })
      end
    end

    -- "Create new worktree" option
    table.insert(entries, {
      display = "🌱 Create new worktree",
      ordinal = "create new worktree",
      action = "create",
    })
  end

  -- If there's only the "current dir" entry, skip the dir picker
  if #entries <= 1 then
    pick_avante_mode(function(avante_mode)
      ask_args = ask_args or {}
      ask_args.ask = false
      ask_args.new_chat = true
      ask_args.avante_mode = avante_mode
      M.ask(ask_args)
    end)
    return
  end

  local ok, telescope = pcall(require, "telescope.pickers")
  if not ok then
    -- No telescope, fall back to normal new chat
    pick_avante_mode(function(avante_mode)
      ask_args = ask_args or {}
      ask_args.ask = false
      ask_args.new_chat = true
      ask_args.avante_mode = avante_mode
      M.ask(ask_args)
    end)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  telescope.new({}, {
    prompt_title = "New Chat",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.ordinal,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not selection then return end

        local entry = selection.value
        if entry.action == "current" then
          pick_avante_mode(function(avante_mode, template)
            pick_acp_provider(template, function(acp_provider)
              local args = ask_args or {}
              args.ask = false
              args.new_chat = true
              args.avante_mode = avante_mode
              args.acp_provider = acp_provider
              args.starter_prompt = template and template.starter_prompt or nil
              M.ask(args)
            end)
          end)
        elseif entry.action == "dir" then
          pick_avante_mode(function(avante_mode, template)
            pick_acp_provider(template, function(acp_provider)
              local merged = vim.tbl_extend("force", template or {}, { acp_provider = acp_provider })
              open_new_chat_in_dir(entry.dir, entry.title, avante_mode, merged)
            end)
          end)
        elseif entry.action == "create" then
          vim.ui.input({ prompt = "Worktree name: " }, function(input)
            if input and input ~= "" then
              M.new_worktree_chat(vim.trim(input))
            end
          end)
        end
      end)
      return true
    end,
  }):find()
end

--- Request agent to enter plan mode (for ACP agents like claude-code)
function M.request_plan_mode()
  local Utils = require("avante.utils")
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.warn("Sidebar not available")
    return
  end
  
  local message = "Please enter plan mode to explore the codebase and design an implementation approach before making changes."
  sidebar:add_message(message)
  Utils.info("Requested agent to enter plan mode")
end

--- Restore session — now simply opens sidebar which auto-restores last thread
function M.restore_session()
  local avante = require("avante")
  if not avante.is_sidebar_open() then
    avante.open_sidebar({})
  else
    -- Sidebar already open — reconnect ACP to restore session
    local sidebar = avante.get()
    if sidebar then
      sidebar:connect_acp()
    end
  end
end

--- Restore an ACP session by its session ID.
--- Connects to ACP agent and loads the specified session.
--- Works even without local Avante history cache.
---@param session_id string The ACP session ID to restore
function M.restore_acp_session(session_id)
  if not session_id or session_id == "" then
    Utils.error("Usage: :AvanteRestoreSession <session-id>")
    return
  end

  if not Config.acp_providers[Config.provider] then
    Utils.error("Current provider (" .. (Config.provider or "nil") .. ") is not an ACP provider")
    return
  end

  local avante = require("avante")
  if not avante.is_sidebar_open() then avante.open_sidebar({ skip_session_restore = true, skip_acp_connect = true }) end
  local sidebar = avante.get()
  if not sidebar then
    Utils.error("Failed to open sidebar")
    return
  end

  -- Set up chat_history with the session ID and persist to disk
  local Path = require("avante.path")
  if not sidebar.chat_history then
    sidebar.chat_history = Path.history.new(sidebar.code.bufnr)
  end
  sidebar.chat_history.acp_session_id = session_id
  Path.history.save(sidebar.code.bufnr, sidebar.chat_history)

  Utils.info("Restoring ACP session: " .. session_id)
  sidebar:connect_acp({
    on_ready = function()
      sidebar:update_content_with_history()
      sidebar:create_plan_container()
      sidebar:initialize_token_count()
      vim.schedule(function() sidebar:focus_input() end)
    end,
  })
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