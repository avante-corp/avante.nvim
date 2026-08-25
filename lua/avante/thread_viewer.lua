local History = require("avante.history")
local Utils = require("avante.utils")
local Path = require("avante.path")
local PlPath = require("plenary.path")
local ACPFactory = require("avante.acp")
local Config = require("avante.config")
local EnvUtils = require("avante.utils.environment")

---@class avante.ThreadViewer
local M = {}

-- Cache for external session info
local _external_sessions_cache = nil
local _acp_client_cache = nil
local _acp_available = nil

---Get cached external session info by session ID
---@param session_id string
---@return table|nil
function M.get_external_session_info(session_id)
  if not _external_sessions_cache then
    -- Use legacy filesystem scan for synchronous access
    _external_sessions_cache = scan_external_acp_sessions_legacy()
  end
  
  for _, session_info in ipairs(_external_sessions_cache) do
    if session_info.session_id == session_id then
      return session_info
    end
  end
  
  return nil
end

---Clear the external sessions cache
function M.clear_cache()
  _external_sessions_cache = nil
  _acp_available = nil
end

---Get or create a shared ACP client for listing sessions
---@return avante.acp.ACPClient|nil, string|nil error
local function get_or_create_acp_client()
  -- Return cached result if we already know ACP is unavailable
  if _acp_available == false then
    return nil, "ACP unavailable (cached)"
  end

  -- Return cached client if available and connected
  if _acp_client_cache and _acp_client_cache:is_connected() then
    return _acp_client_cache, nil
  end

  -- Try to reuse the sidebar's existing ACP client first
  local ok, Avante = pcall(require, "avante")
  if ok then
    local sidebar = Avante.get and Avante.get()
    if sidebar and sidebar.acp_client and sidebar.acp_client:is_connected() then
      _acp_client_cache = sidebar.acp_client
      _acp_available = true
      return _acp_client_cache, nil
    end
  end

  -- Create new ACP client — try acp_providers first, then legacy providers config
  local acp_config = nil
  local current_provider = Config.provider
  if Config.acp_providers and Config.acp_providers[current_provider] then
    acp_config = Config.acp_providers[current_provider]
  elseif Config.providers and Config.providers["claude"] and Config.providers["claude"].acp_args then
    acp_config = Config.providers["claude"].acp_args
  end

  if not acp_config or not acp_config.command then
    _acp_available = false
    return nil, "ACP not configured"
  end

  -- Get current working directory and resolve environment variables with path-based overrides
  local cwd = vim.fn.getcwd()
  local resolved_env = EnvUtils.merge_env_with_overrides(
    acp_config.env or {},
    acp_config.envOverrides,
    cwd
  )

  -- Built through the factory so this honours acp_backend. Constructing the
  -- Lua client directly here meant a second agent process was spawned just to
  -- list sessions, even when the sidebar already had one.
  local client = ACPFactory.new({
    transport_type = "stdio",
    provider = current_provider,
    command = acp_config.command,
    args = acp_config.args or {},
    env = resolved_env,
    cwd = cwd,
    timeout = 5000,
    handlers = {},
  })

  local connect_err = nil
  local connected = false

  client:connect(function(err)
    if err then
      connect_err = err
    else
      connected = true
    end
  end)

  -- Blocks the editor, but only while the thread viewer is opening. vim.wait
  -- pumps the event loop, so the connect callback can still fire.
  vim.wait(15000, function() return connected or connect_err ~= nil end, 50)

  if not connected or connect_err then
    _acp_available = false
    return nil, "Failed to connect to ACP: " .. (connect_err and connect_err.message or "timeout")
  end

  _acp_client_cache = client
  _acp_available = true
  return client, nil
end

---Scan external ACP session directories for sessions (legacy fallback)
---@return table[] -- Array of session info {path: string, session_id: string, mtime: number}
local function scan_external_acp_sessions_legacy()
  local sessions = {}
  
  -- Known ACP cache directories
  local acp_cache_dirs = {
    vim.fn.expand("~/.cache/claude-code-acp"),
    vim.fn.expand("~/Library/Caches/claude-code-acp"),
  }
  
  for _, cache_dir in ipairs(acp_cache_dirs) do
    local cache_path = PlPath:new(cache_dir)
    if cache_path:exists() and cache_path:is_dir() then
      -- List all session directories
      local session_dirs = vim.fn.glob(tostring(cache_path:joinpath("*")), true, true)
      for _, session_dir in ipairs(session_dirs) do
        local session_path = PlPath:new(session_dir)
        if session_path:is_dir() then
          -- Extract working directory from the encoded directory name
          local dir_name = session_path:basename()
          -- Decode the directory name (it's URL-encoded with - instead of /)
          local working_dir = dir_name:gsub("%-", "/")
          
          -- Get session modification time
          local stat = vim.loop.fs_stat(session_dir)
          local mtime = stat and stat.mtime.sec or 0
          
          -- Look for session state files
          local state_file = session_path:joinpath("state.json")
          local session_id = nil
          
          if state_file:exists() then
            local content = state_file:read()
            if content then
              local ok, state = pcall(vim.json.decode, content)
              if ok and state then
                session_id = state.session_id or state.sessionId
              end
            end
          end
          
          -- If no explicit session ID, use directory name as identifier
          if not session_id then
            session_id = dir_name
          end
          
          table.insert(sessions, {
            path = session_dir,
            session_id = session_id,
            working_directory = working_dir,
            mtime = mtime,
          })
        end
      end
    end
  end
  
  return sessions
end

---Fetch sessions from claude-code via ACP protocol
---@param callback fun(sessions: table[])
local function fetch_sessions_from_acp(callback)
  local client, err = get_or_create_acp_client()
  
  if not client then
    -- ACP not available, just use filesystem scanning
    Utils.debug("ACP client unavailable: " .. (err or "unknown") .. " - using filesystem scan")
    callback(scan_external_acp_sessions_legacy())
    return
  end

  Utils.debug("Fetching sessions via ACP...")
  -- cwd = false so threads from every worktree are listed, not just this one.
  client:list_sessions({ cwd = false }, function(sessions, list_err)
    if list_err then
      -- METHOD_NOT_FOUND means the agent genuinely cannot list sessions, which
      -- is the only case where scraping the cache directory is justified.
      local unsupported = list_err.code == -32601
      if unsupported then
        Utils.debug("Agent does not support session/list; scanning cache directories")
      else
        Utils.warn("Failed to list sessions via ACP: " .. (list_err.message or "unknown error"))
      end
      callback(scan_external_acp_sessions_legacy())
      return
    end

    if not sessions then
      Utils.warn("ACP returned no sessions (nil)")
      callback(scan_external_acp_sessions_legacy())
      return
    end

    Utils.debug("ACP returned " .. #sessions .. " sessions")

    -- Transform ACP session format to our internal format
    local transformed_sessions = {}
    for _, acp_session in ipairs(sessions) do
      table.insert(transformed_sessions, {
        session_id = acp_session.sessionId or acp_session.session_id,
        working_directory = acp_session.cwd or acp_session.workingDirectory or "unknown",
        mtime = (function()
          -- ACP SessionInfo spells this `updatedAt`; the other names are kept
          -- for agents that predate the field.
          local lm = acp_session.updatedAt
            or acp_session.updated_at
            or acp_session.lastModified
            or acp_session.last_modified
          if type(lm) == "string" then
            -- Must be numeric: mtime is sorted against os.time() fallbacks, and
            -- comparing a string with a number raises in table.sort.
            local ts = Utils.parse_iso8601_epoch(lm)
            if ts then return ts end
          end
          if type(lm) == "number" then return lm end
          return os.time()
        end)(),
        message_count = acp_session.messageCount or acp_session.message_count or 0,
        title = acp_session.title or acp_session.name or nil, -- Capture title from ACP response
        path = nil, -- ACP sessions don't have a local path
      })
    end

    Utils.debug("Transformed " .. #transformed_sessions .. " ACP sessions")

    -- An agent that supports session/list and reports none genuinely has none;
    -- scraping the cache here would resurrect sessions the agent has dropped.
    
    callback(transformed_sessions)
  end)
end

---Scan external ACP sessions (async, uses ACP when available)
---@param callback fun(sessions: table[])
local function scan_external_acp_sessions(callback)
  fetch_sessions_from_acp(callback)
end

---Create a synthetic history entry for an external ACP session
---@param session_info table
---@return avante.ChatHistory
local function create_synthetic_history(session_info)
  -- Use the title from ACP if available, otherwise fall back to generic name
  local title = session_info.title or "External ACP Session"
  
  return {
    title = title,
    timestamp = os.date("%Y-%m-%d %H:%M:%S", session_info.mtime),
    messages = {},
    entries = {},
    todos = {},
    tags = { "external" },
    memory = nil,
    filename = "__external_acp_" .. session_info.session_id,
    system_prompt = nil,
    tokens_usage = nil,
    acp_session_id = session_info.session_id,
    working_directory = session_info.working_directory,
    selected_files = nil,
    _is_external = true,
  }
end

---Message count for a thread, whether it is a full history or a bridge summary.
---Summaries deliberately omit the messages array; that is the whole reason
---listing is fast.
---@param history table
---@return integer
local function thread_message_count(history)
  if history.message_count then return history.message_count end
  return #History.get_history_messages(history)
end

---Timestamp used for ordering and display.
---@param history table
---@return string
local function thread_timestamp(history)
  if history.last_message_timestamp then return history.last_message_timestamp end
  local messages = History.get_history_messages(history)
  if #messages > 0 then return messages[#messages].timestamp end
  return history.timestamp or ""
end

---@param history avante.ChatHistory
---@param acp_message_counts? table<string, integer> Map of session_id to ACP message count
---@return string
local function format_thread_entry(history, acp_message_counts)
  local message_count = thread_message_count(history)
  local timestamp = thread_timestamp(history)
  local working_dir = history.working_directory or "unknown"

  -- Extract just the directory name for display
  local dir_name = working_dir:match("([^/]+)$") or working_dir

  -- Pin indicator
  local pin = history.pinned and "* " or "  "

  -- Add ACP indicator if this is an ACP session
  local acp_indicator = history.acp_session_id and " [ACP]" or ""

  -- Add tags as badges
  local tags_str = ""
  if history.tags and #history.tags > 0 then
    local tag_badges = {}
    for _, tag in ipairs(history.tags) do
      table.insert(tag_badges, "#" .. tag)
    end
    tags_str = " " .. table.concat(tag_badges, " ")
  end

  -- Unread indicator
  local unread = ""
  if acp_message_counts and history.acp_session_id then
    local acp_count = acp_message_counts[history.acp_session_id]
    local last_seen = history.last_seen_message_count or message_count
    if acp_count and acp_count > last_seen then
      unread = " [NEW]"
    end
  end

  -- Format: * [dir_name] title - timestamp (msg_count) #tag1 #tag2 [ACP] [NEW]
  return string.format("%s[%s] %s - %s (%d)%s%s%s",
    pin,
    dir_name,
    history.title or "(untitled)",
    timestamp,
    message_count,
    tags_str,
    acp_indicator,
    unread
  )
end

---Show telescope picker with histories
---@param histories table[]
---@param bufnr integer
---@param cb fun(filename: string)
---@param pickers table
---@param finders table
---@param conf table
---@param actions table
---@param action_state table
---@param previewers table
---@param opts? { filter?: string, show_unread?: boolean, acp_message_counts?: table<string, integer> }
local function show_telescope_picker(histories, bufnr, cb, pickers, finders, conf, actions, action_state, previewers, opts)
  opts = opts or {}
  local acp_message_counts = opts.acp_message_counts or {}

  if #histories == 0 then
    if opts.filter == "pinned" then
      Utils.warn("No pinned threads found. Pin a thread with 's' in :AvanteThreads or use /pin.")
    else
      Utils.warn("No thread history found.")
    end
    return
  end

  -- Create entries for telescope
  local entries = {}

  -- Add "Create New Thread" as the first entry (but not in filtered views)
  if not opts.filter then
    table.insert(entries, {
      value = "__create_new__",
      display = "[+] Create New Thread",
      ordinal = "[+] Create New Thread",
      is_new_thread = true,
    })
  end

  for _, history in ipairs(histories) do
    local display_text = format_thread_entry(history, acp_message_counts)
    -- Add [EXTERNAL] tag for sessions without Avante history
    if history._is_external then
      display_text = display_text .. " [EXTERNAL]"
    end

    table.insert(entries, {
      value = history.filename,
      display = display_text,
      ordinal = display_text,
      history = history,
    })
  end

  local prompt_title = (opts.filter == "pinned") and "Avante Pinned Threads" or "Avante Threads"

  pickers
    .new({}, {
      prompt_title = prompt_title,
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return entry
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Thread Preview",
        define_preview = function(self, entry)
          local preview_lines = {}
          
          -- Handle "Create New Thread" entry
          if entry.is_new_thread then
            table.insert(preview_lines, "# Create New Thread")
            table.insert(preview_lines, "")
            table.insert(preview_lines, "Start a fresh conversation with a new thread.")
            table.insert(preview_lines, "")
            table.insert(preview_lines, "Press **Enter** to create a new thread.")
            
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
            vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")
            return
          end
          
          local history = entry.history
          local Sidebar = require("avante.sidebar")
          local content = Sidebar.render_history_content(history)
          
          -- Add directory context at the top
          if history.working_directory then
            table.insert(preview_lines, "**Working Directory:** " .. history.working_directory)
            table.insert(preview_lines, "")
          end
          if history.acp_session_id then
            table.insert(preview_lines, "**ACP Session ID:** " .. history.acp_session_id)
            table.insert(preview_lines, "")
          end
          if history.tags and #history.tags > 0 then
            table.insert(preview_lines, "**Tags:** " .. table.concat(history.tags, ", "))
            table.insert(preview_lines, "")
          end
          if history.parent_thread_id then
            table.insert(preview_lines, "**Forked from:** " .. history.parent_thread_id)
            table.insert(preview_lines, "")
          end
          if history.pinned then
            table.insert(preview_lines, "**Pinned:** yes")
            table.insert(preview_lines, "")
          end
          table.insert(preview_lines, "---")
          table.insert(preview_lines, "")
          
          -- Append the actual content
          for line in content:gmatch("[^\r\n]+") do
            table.insert(preview_lines, line)
          end
          
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
          vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          -- Wrap close in pcall to handle potential autocmd errors
          pcall(actions.close, prompt_bufnr)
          if selection then
            vim.schedule(function()
              -- Handle "Create New Thread"
              if selection.is_new_thread then
                -- Create a new thread by calling AvanteChatNew
                vim.cmd("AvanteChatNew")
                return
              end
              
              -- Handle existing threads
              if cb then
                -- Pass external session ID if this is an external session
                local external_session_id = nil
                if selection.history and selection.history._is_external then
                  external_session_id = selection.history.acp_session_id
                end
                cb(selection.value, external_session_id, selection.history)
              end
            end)
          end
        end)

        -- Add delete mapping with 'd'
        map("n", "d", function()
          local selection = action_state.get_selected_entry()
          if selection then
            Path.history.delete(bufnr, selection.value)
            Utils.info("Deleted thread: " .. selection.display)
            -- Wrap close in pcall to handle potential autocmd errors
            pcall(actions.close, prompt_bufnr)
            -- Reopen the picker to refresh (with slight delay to avoid conflicts)
            vim.schedule(function()
              M.open_with_telescope(bufnr, cb, opts)
            end)
          end
        end)

        -- Add rename mapping with 'r'
        map("n", "r", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.history and not selection.is_new_thread then
            local current_title = selection.history.title or ""
            vim.ui.input({ prompt = "Rename thread: ", default = current_title }, function(new_title)
              if new_title and new_title ~= "" then
                selection.history.title = new_title
                Path.history.save(bufnr, selection.history)
                Utils.info("Renamed thread to: " .. new_title)
                pcall(actions.close, prompt_bufnr)
                vim.schedule(function()
                  M.open_with_telescope(bufnr, cb, opts)
                end)
              end
            end)
          end
        end)

        -- Add pin toggle mapping with 's'
        map("n", "s", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.history and not selection.is_new_thread then
            selection.history.pinned = not selection.history.pinned
            Path.history.save(bufnr, selection.history)
            local label = selection.history.pinned and "Pinned" or "Unpinned"
            Utils.info(label .. ": " .. (selection.history.title or selection.value))
            pcall(actions.close, prompt_bufnr)
            vim.schedule(function()
              M.open_with_telescope(bufnr, cb, opts)
            end)
          end
        end)

        return true
      end,
    })
    :find()
end

---@param bufnr integer
---@param cb fun(filename: string)
---@param opts? { filter?: string, show_unread?: boolean }
function M.open_with_telescope(bufnr, cb, opts)
  opts = opts or {}

  local has_telescope, _ = pcall(require, "telescope")
  if not has_telescope then
    Utils.warn("Telescope is not installed. Please install telescope.nvim to use :AvanteThreads")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  -- Load histories from all projects, not just current.
  -- Path.history.list_all() decodes every history file on the main loop, which
  -- is multi-second on a large store, so prefer the bridge's cached index.
  M.list_all_histories(function(histories)
  -- Fetch external ACP sessions asynchronously
  scan_external_acp_sessions(function(external_sessions)
    -- Build ACP message counts lookup for unread detection
    local acp_message_counts = {}
    for _, session_info in ipairs(external_sessions) do
      if session_info.session_id and session_info.message_count then
        acp_message_counts[session_info.session_id] = session_info.message_count
      end
    end

    -- Create deduplicated map by session ID
    local session_map = {}

    -- First, add all local histories (they have priority - more complete info)
    for _, history in ipairs(histories) do
      local session_id = history.acp_session_id
      if session_id then
        -- Use session_id as key
        if not session_map[session_id] then
          session_map[session_id] = history
          Utils.debug("Added local history with session_id: " .. session_id)
        else
          -- Session already exists - prefer the most recently modified copy
          -- This ensures that pin/unpin changes are picked up from the freshest save
          local existing = session_map[session_id]
          local existing_time = thread_timestamp(existing)
          local new_time = thread_timestamp(history)
          if new_time > existing_time then
            Utils.debug("Replacing session " .. session_id .. " with more recent copy")
            session_map[session_id] = history
          elseif new_time == existing_time and thread_message_count(history) > thread_message_count(existing) then
            Utils.debug("Replacing session " .. session_id .. " with more complete copy (same timestamp)")
            session_map[session_id] = history
          else
            Utils.debug("Skipping duplicate session: " .. session_id)
          end
        end
      else
        -- No session_id (legacy history), use filename as key
        local key = history.filename or tostring(history)
        if not session_map[key] then
          session_map[key] = history
          Utils.debug("Added legacy history: " .. key)
        end
      end
    end

    -- Now add external sessions that don't exist in local histories
    for _, session_info in ipairs(external_sessions) do
      local session_id = session_info.session_id
      if not session_map[session_id] then
        local synthetic_history = create_synthetic_history(session_info)
        session_map[session_id] = synthetic_history
        Utils.debug("Added external ACP session: " .. session_id)
      else
        Utils.debug("Skipping external session already in local histories: " .. session_id)
      end
    end

    -- Convert map back to array
    local deduplicated_histories = {}
    for _, history in pairs(session_map) do
      table.insert(deduplicated_histories, history)
    end

    -- Sort: pinned first, then by most recent activity (last message timestamp)
    table.sort(deduplicated_histories, function(a, b)
      local a_pinned = a.pinned or false
      local b_pinned = b.pinned or false
      if a_pinned ~= b_pinned then return a_pinned end
      return thread_timestamp(a) > thread_timestamp(b)
    end)

    -- Apply filter
    if opts.filter == "pinned" then
      deduplicated_histories = vim.tbl_filter(function(h) return h.pinned == true end, deduplicated_histories)
    end

    Utils.info("Loaded " .. #deduplicated_histories .. " unique threads (deduplicated from " .. #histories .. " local + " .. #external_sessions .. " external)")

    -- Pass acp_message_counts through opts for the picker
    local picker_opts = vim.tbl_extend("force", opts, { acp_message_counts = acp_message_counts })

    -- Continue with telescope picker inside the callback
    vim.schedule(function()
      show_telescope_picker(deduplicated_histories, bufnr, cb, pickers, finders, conf, actions, action_state, previewers, picker_opts)
    end)
  end)
  end)
end

---Load thread summaries for every project.
---
---Uses the bridge's cached index when the python backend is active: it only
---re-reads history files whose mtime changed, and does it off the main loop.
---Falls back to Path.history.list_all(), which decodes every file inline.
---@param callback fun(histories: table[])
function M.list_all_histories(callback)
  local ACPFactory = require("avante.acp")
  if ACPFactory.backend() ~= "python" then
    callback(Path.history.list_all())
    return
  end

  local ok, ACPClient = pcall(require, "avante.acp.client")
  if not ok or not ACPClient.list_threads then
    callback(Path.history.list_all())
    return
  end

  ACPClient.list_threads({}, function(threads, err, stats)
    if err or not threads then
      Utils.debug("threads/list failed (" .. vim.inspect(err) .. "); falling back to local scan")
      callback(Path.history.list_all())
      return
    end
    if stats then
      Utils.debug(
        string.format(
          "threads/list: %d scanned, %d parsed, %d cached",
          stats.scanned or 0,
          stats.parsed or 0,
          stats.cached or 0
        )
      )
    end
    callback(threads)
  end)
end

---@param bufnr integer
---@param cb fun(filename: string)
---@param opts? { filter?: string, show_unread?: boolean }
function M.open(bufnr, cb, opts)
  -- Try to use telescope first, fall back to native selector
  local has_telescope, _ = pcall(require, "telescope")

  if has_telescope then
    M.open_with_telescope(bufnr, cb, opts)
  else
    -- Fall back to the native history selector
    require("avante.history_selector").open(bufnr, cb)
  end
end

---Check pinned threads for unread messages via ACP session/list
---@param pinned_histories avante.ChatHistory[] Only pinned histories with acp_session_id
---@param callback fun(unread_count: integer)
function M.check_pinned_unread(pinned_histories, callback)
  fetch_sessions_from_acp(function(external_sessions)
    -- Build lookup of ACP message counts
    local acp_counts = {}
    for _, s in ipairs(external_sessions) do
      if s.session_id and s.message_count then
        acp_counts[s.session_id] = s.message_count
      end
    end

    local unread = 0
    for _, history in ipairs(pinned_histories) do
      local acp_count = acp_counts[history.acp_session_id]
      local last_seen = history.last_seen_message_count or #(history.messages or {})
      if acp_count and acp_count > last_seen then
        unread = unread + 1
      end
    end

    vim.schedule(function() callback(unread) end)
  end)
end

return M