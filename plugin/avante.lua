if vim.fn.has("nvim-0.10") == 0 then
  vim.api.nvim_echo({
    { "Avante requires at least nvim-0.10", "ErrorMsg" },
    { "Please upgrade your neovim version", "WarningMsg" },
    { "Press any key to exit", "ErrorMsg" },
  }, true, {})
  vim.fn.getchar()
  vim.cmd([[quit]])
end

if vim.g.avante ~= nil then return end

vim.g.avante = 1

--- NOTE: We will override vim.paste if img-clip.nvim is available to work with avante.nvim internal logic paste
local Clipboard = require("avante.clipboard")
local Config = require("avante.config")
local Utils = require("avante.utils")
local P = require("avante.path")
local api = vim.api

if Config.support_paste_image() then
  vim.paste = (function(overridden)
    ---@param lines string[]
    ---@param phase -1|1|2|3
    return function(lines, phase)
      require("img-clip.util").verbose = false

      local bufnr = vim.api.nvim_get_current_buf()
      local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if filetype ~= "AvanteInput" then return overridden(lines, phase) end

      ---@type string
      local line = lines[1]

      local ok = Clipboard.paste_image(line)
      if not ok then return overridden(lines, phase) end

      -- After pasting, insert a new line and set cursor to this line
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
      local last_line = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(0, { last_line, 0 })
    end
  end)(vim.paste)
end

---@param n string
---@param c vim.api.keyset.user_command.callback
---@param o vim.api.keyset.user_command.opts
local function cmd(n, c, o)
  o = vim.tbl_extend("force", { nargs = 0 }, o or {})
  api.nvim_create_user_command("Avante" .. n, c, o)
end

local function ask_complete(prefix, _, _)
  local candidates = {} ---@type string[]
  vim.list_extend(
    candidates,
    ---@param x string
    vim.tbl_map(function(x) return "position=" .. x end, { "left", "right", "top", "bottom" })
  )
  vim.list_extend(
    candidates,
    ---@param x string
    vim.tbl_map(function(x) return "project_root=" .. x.root end, P.list_projects())
  )
  return vim.tbl_filter(function(candidate) return vim.startswith(candidate, prefix) end, candidates)
end

cmd("Ask", function(opts)
  ---@type AskOptions
  local args = { question = nil, win = {} }

  local parsed_args, question = Utils.parse_args(opts.fargs, {
    collect_remaining = true,
    boolean_keys = { "ask" },
  })

  if parsed_args.position then args.win.position = parsed_args.position end

  require("avante.api").ask(vim.tbl_deep_extend("force", args, {
    ask = parsed_args.ask,
    project_root = parsed_args.project_root,
    question = question or nil,
  }))
end, {
  desc = "avante: ask AI for code suggestions",
  nargs = "*",
  complete = ask_complete,
})
cmd("Chat", function(opts)
  local args = Utils.parse_args(opts.fargs)
  args.ask = false

  require("avante.api").ask(args)
end, {
  desc = "avante: chat with the codebase",
  nargs = "*",
  complete = ask_complete,
})
cmd("ChatNew", function(opts)
  local args = Utils.parse_args(opts.fargs)
  require("avante.api").new_chat_picker(args)
end, { desc = "avante: create new chat (with worktree picker if configured)", nargs = "*", complete = ask_complete })
cmd("Toggle", function() require("avante").toggle() end, { desc = "avante: toggle AI panel" })
cmd("Build", function(opts)
  local args = Utils.parse_args(opts.fargs)

  if args.source == nil then args.source = false end

  require("avante.api").build(args)
end, {
  desc = "avante: build dependencies",
  nargs = "*",
  complete = function(_, _, _) return { "source=true", "source=false" } end,
})
cmd(
  "Edit",
  function(opts) require("avante.api").edit(vim.trim(opts.args), opts.line1, opts.line2) end,
  { desc = "avante: edit selected block", nargs = "*", range = 2 }
)
cmd("Refresh", function() require("avante.api").refresh() end, { desc = "avante: refresh windows" })
cmd("Focus", function() require("avante.api").focus() end, { desc = "avante: switch focus windows" })
cmd("SwitchProvider", function(opts) require("avante.api").switch_provider(vim.trim(opts.args or "")) end, {
  nargs = 1,
  desc = "avante: switch provider",
  complete = function(_, line, _)
    local prefix = line:match("AvanteSwitchProvider%s*(.*)$") or ""
    local providers = vim.tbl_filter(
      ---@param key string
      function(key) return key:find(prefix, 1, true) == 1 end,
      vim.tbl_keys(Config.providers)
    )
    for acp_provider_name, _ in pairs(Config.acp_providers) do
      if acp_provider_name:find(prefix, 1, true) == 1 then providers[#providers + 1] = acp_provider_name end
    end
    return providers
  end,
})
cmd(
  "SwitchSelectorProvider",
  function(opts) require("avante.api").switch_selector_provider(vim.trim(opts.args or "")) end,
  {
    nargs = 1,
    desc = "avante: switch selector provider",
  }
)
cmd("SwitchInputProvider", function(opts) require("avante.api").switch_input_provider(vim.trim(opts.args or "")) end, {
  nargs = 1,
  desc = "avante: switch input provider",
  complete = function(_, line, _)
    local prefix = line:match("AvanteSwitchInputProvider%s*(.*)$") or ""
    local providers = { "native", "dressing", "snacks" }
    return vim.tbl_filter(function(key) return key:find(prefix, 1, true) == 1 end, providers)
  end,
})
cmd("Clear", function(opts)
  local arg = vim.trim(opts.args or "")
  arg = arg == "" and "history" or arg
  if arg == "history" then
    local sidebar = require("avante").get()
    if not sidebar then
      Utils.error("No sidebar found")
      return
    end
    sidebar:clear_history()
  elseif arg == "cache" then
    local history_path = P.history_path:absolute()
    local cache_path = P.cache_path:absolute()
    local prompt = string.format("Recursively delete %s and %s?", history_path, cache_path)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then P.clear() end
  else
    Utils.error("Invalid argument. Valid arguments: 'history', 'memory', 'cache'")
    return
  end
end, {
  desc = "avante: clear history, memory or cache",
  nargs = "?",
  complete = function(_, _, _) return { "history", "cache" } end,
})
cmd("ShowRepoMap", function() require("avante.repo_map").show() end, { desc = "avante: show repo map" })
cmd("Models", function() require("avante.model_selector").open() end, { desc = "avante: show models" })
cmd("History", function() require("avante.api").select_history() end, { desc = "avante: show histories" })
cmd("Threads", function() require("avante.api").view_threads() end, { desc = "avante: view all threads with telescope" })
cmd("PinnedThreads", function() require("avante.api").view_pinned_threads() end, { desc = "avante: view pinned threads with unread detection" })
cmd("NextPinnedThread", function() require("avante.api").next_pinned_thread() end, { desc = "avante: switch to next pinned thread" })
cmd("PrevPinnedThread", function() require("avante.api").prev_pinned_thread() end, { desc = "avante: switch to previous pinned thread" })
cmd("Debug", function()
  local Config = require("avante.config")
  Config.debug = not Config.debug
  local status = Config.debug and "enabled" or "disabled"
  Utils.info("Debug mode " .. status .. (Config.debug and " - logs at /tmp/avante-debug.log and /tmp/avante-acp-session.log" or ""))
end, { desc = "avante: toggle debug mode" })
cmd("RequestPlanMode", function() require("avante.api").request_plan_mode() end, { desc = "avante: request agent to enter plan mode" })
cmd("SessionRestore", function() require("avante.api").restore_session() end, { desc = "avante: restore last session" })
cmd("RestoreSession", function(opts)
  require("avante.api").restore_acp_session(vim.trim(opts.args or ""))
end, { desc = "avante: restore an ACP session by session ID", nargs = 1 })
cmd("Stop", function() require("avante.api").stop() end, { desc = "avante: stop current AI request" })
cmd("Mode", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found. Open Avante first with :AvanteChat or :AvanteChatNew")
    return
  end
  sidebar:cycle_mode()
end, { desc = "avante: cycle through session modes" })
cmd("Prompts", function()
  require("avante.prompt_selector").open({ mode = "copy" })
end, { desc = "avante: browse and copy prompts to clipboard" })
cmd("Modes", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found. Open Avante first with :AvanteChat or :AvanteChatNew")
    return
  end
  
  -- Build mode information
  local lines = { "Available Session Modes:", "" }
  
  if sidebar.acp_client and sidebar.acp_client:has_modes() then
    -- Show ACP client modes
    table.insert(lines, "Source: ACP Agent")
    table.insert(lines, "")
    for _, mode in ipairs(sidebar.acp_client:all_modes()) do
      local is_current = mode.id == sidebar.current_mode_id
      local marker = is_current and "→ " or "  "
      local name = mode.name or mode.id
      local desc = mode.description or "No description"
      table.insert(lines, string.format("%s%s (%s)", marker, name, mode.id))
      table.insert(lines, string.format("    %s", desc))
      table.insert(lines, "")
    end
  else
    -- No modes available
    table.insert(lines, "No modes available from agent")
    table.insert(lines, "")
    table.insert(lines, "The connected agent does not provide session modes.")
  end
  
  table.insert(lines, "")
  table.insert(lines, "Use :AvanteMode or 'M' in the sidebar to cycle modes")
  
  -- Display in a floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  
  local width = 80
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
    title = " Session Modes ",
    title_pos = "center",
  })
  
  -- Close on q or <Esc>
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, noremap = true, silent = true })
end, { desc = "avante: show available session modes" })
cmd("Options", function(args)
  require("avante.config_option_selector").open({
    category = args.args ~= "" and args.args or nil,
  })
end, { nargs = "?", desc = "avante: open agent config options selector" })
cmd("Plan", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found. Open Avante first with :AvanteChat or :AvanteChatNew")
    return
  end
  -- Focus the plan container if it exists in the sidebar
  if sidebar.containers and sidebar.containers.plan and sidebar.containers.plan.winid
    and vim.api.nvim_win_is_valid(sidebar.containers.plan.winid) then
    vim.api.nvim_set_current_win(sidebar.containers.plan.winid)
    return
  end
  -- If no plan container but we have plan entries, create the container first
  if sidebar.chat_history and sidebar.chat_history.todos and #sidebar.chat_history.todos > 0 then
    sidebar:create_plan_container()
    if sidebar.containers and sidebar.containers.plan and sidebar.containers.plan.winid
      and vim.api.nvim_win_is_valid(sidebar.containers.plan.winid) then
      vim.api.nvim_set_current_win(sidebar.containers.plan.winid)
      return
    end
  end
  Utils.info("No plan available")
end, { desc = "avante: focus the plan pane in the sidebar" })
cmd("FollowToggle", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found. Open Avante first with :AvanteChat or :AvanteChatNew")
    return
  end
  sidebar.follow_mode = not sidebar.follow_mode
  local status = sidebar.follow_mode and "enabled" or "disabled"
  Utils.info("Follow mode " .. status)
  sidebar._history_cache_invalidated = true
  sidebar:update_content("")
end, { desc = "avante: toggle follow mode (auto-jump to agent edits)" })
cmd("Review", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found. Open Avante first with :AvanteChat or :AvanteChatNew")
    return
  end
  local session_ctx = sidebar._current_session_ctx
  if not session_ctx then
    Utils.error("No active session")
    return
  end
  require("avante.review").open(session_ctx)
end, { desc = "avante: review all agent changes with per-hunk accept/reject" })
cmd("ChangedFiles", function()
  require("avante.changed_files").open()
end, { desc = "avante: show location list of files changed by the agent" })
cmd("ThreadRename", function(opts)
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found")
    return
  end
  local new_name = vim.trim(opts.args or "")
  if new_name == "" then
    vim.ui.input({ prompt = "Thread name: ", default = sidebar.chat_history and sidebar.chat_history.title or "" }, function(input)
      if input and input ~= "" then
        sidebar:rename_thread(input)
      end
    end)
  else
    sidebar:rename_thread(new_name)
  end
end, { desc = "avante: rename current thread", nargs = "?" })
cmd("ThreadFork", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found")
    return
  end
  if not sidebar.chat_history then
    Utils.error("No active thread to fork")
    return
  end
  sidebar:fork_thread()
end, { desc = "avante: fork current thread at current position" })
cmd("Context", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found")
    return
  end
  -- Toggle context visibility in the sidebar
  if sidebar._context_panel_visible then
    sidebar._context_panel_visible = false
    Utils.info("Context panel hidden")
  else
    sidebar._context_panel_visible = true
    Utils.info("Context panel shown")
  end
  -- Re-render to show/hide context
  if sidebar.render_result then sidebar:render_result() end
end, { desc = "avante: toggle context visibility panel" })
cmd("PromptPreview", function()
  local sidebar = require("avante").get()
  if not sidebar then
    Utils.error("No sidebar found")
    return
  end
  -- Build the prompt that would be sent and show it in a scratch buffer
  local Llm = require("avante.llm")
  local prompt_opts = Llm.generate_prompts({
    bufnr = sidebar.code.bufnr,
    ask = true,
    instructions = "",
    mode = Config.mode,
  })
  local lines = {}
  table.insert(lines, "# Prompt Preview")
  table.insert(lines, "")
  table.insert(lines, "## System Prompt")
  table.insert(lines, "")
  table.insert(lines, "```")
  table.insert(lines, prompt_opts.system_prompt or "(none)")
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "## Messages (" .. #(prompt_opts.messages or {}) .. ")")
  table.insert(lines, "")
  for i, msg in ipairs(prompt_opts.messages or {}) do
    table.insert(lines, "### " .. i .. ". " .. (msg.role or "unknown"))
    table.insert(lines, "```")
    local content = msg.content or ""
    if type(content) == "table" then content = vim.inspect(content) end
    table.insert(lines, content)
    table.insert(lines, "```")
    table.insert(lines, "")
  end
  -- Selected files
  if sidebar.file_selector then
    local files = sidebar.file_selector:get_selected_filepaths()
    if #files > 0 then
      table.insert(lines, "## Selected Files (" .. #files .. ")")
      table.insert(lines, "")
      for _, f in ipairs(files) do
        table.insert(lines, "- " .. f)
      end
      table.insert(lines, "")
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
end, { desc = "avante: preview the full prompt in a scratch buffer" })