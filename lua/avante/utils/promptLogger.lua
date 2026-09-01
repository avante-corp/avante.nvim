local Config = require("avante.config")
local Utils = require("avante.utils")
local Path = require("plenary.path")

local AVANTE_PROMPT_INPUT_HL = "AvantePromptInputHL"

-- last one in entries is always to hold current input
local entries, idx = {}, 0
local filtered_entries = {}
local current_project_root = nil

---@class avante.utils.promptLogger
local M = {}

---Generate a unique 6-character alphanumeric ID
---@return string
local function generate_unique_id()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local id = ""
  math.randomseed(os.time() + vim.loop.hrtime())
  for _ = 1, 6 do
    local idx_char = math.random(1, #chars)
    id = id .. chars:sub(idx_char, idx_char)
  end
  return id
end

---Get or create the prompts directory for a project
---@param project_root string
---@return Path
local function get_prompts_dir(project_root)
  -- Generate SHA hash of the project root directory
  local hash = vim.fn.sha256(project_root)
  
  -- Use ~/.avante/prompts/HASH/
  local home = vim.fn.expand("~")
  local prompts_dir = Path:new(home)
    :joinpath(".avante")
    :joinpath("prompts")
    :joinpath(hash)
  
  if not prompts_dir:exists() then
    prompts_dir:mkdir({ parents = true })
  end
  
  return prompts_dir
end

---Get or create date-based subdirectory (YYYY/MM/DD)
---@param prompts_dir Path
---@return Path
local function get_date_subdir(prompts_dir)
  local date = os.date("*t")
  local date_dir = prompts_dir
    :joinpath(string.format("%04d", date.year))
    :joinpath(string.format("%02d", date.month))
    :joinpath(string.format("%02d", date.day))
  
  if not date_dir:exists() then
    date_dir:mkdir({ parents = true })
  end
  
  return date_dir
end

---Generate filename in format HHMMSS_ID.json
---@param timestamp string
---@param id string
---@return string
local function generate_filename(timestamp, id)
  -- Extract time from timestamp format "YYYY-MM-DD HH:MM:SS"
  local time_part = timestamp:match("%d%d:%d%d:%d%d")
  if time_part then
    time_part = time_part:gsub(":", "")
    return time_part .. "_" .. id .. ".json"
  end
  -- Fallback
  return os.date("%H%M%S") .. "_" .. id .. ".json"
end

---Extract key words from prompt for search optimization
---@param prompt_text string
---@return string[]
local function extract_search_keywords(prompt_text)
  -- Stop words to filter out
  local stop_words = {
    ["the"] = true, ["a"] = true, ["an"] = true, ["is"] = true, ["are"] = true,
    ["was"] = true, ["were"] = true, ["for"] = true, ["to"] = true, ["of"] = true,
    ["in"] = true, ["on"] = true, ["at"] = true, ["by"] = true, ["with"] = true,
    ["from"] = true, ["as"] = true, ["be"] = true, ["this"] = true, ["that"] = true,
    ["it"] = true, ["and"] = true, ["or"] = true, ["but"] = true, ["not"] = true,
    ["can"] = true, ["will"] = true, ["would"] = true, ["should"] = true, ["could"] = true,
  }
  
  -- Split by whitespace and punctuation, convert to lowercase
  local words = {}
  local word_counts = {}
  
  for word in prompt_text:lower():gmatch("[%w]+") do
    if not stop_words[word] and #word > 2 then  -- Filter stop words and very short words
      if not word_counts[word] then
        word_counts[word] = 1
        table.insert(words, word)
      else
        word_counts[word] = word_counts[word] + 1
      end
    end
  end
  
  -- Sort by frequency (most common first) and take top keywords
  table.sort(words, function(a, b)
    return word_counts[a] > word_counts[b]
  end)
  
  -- Get config or default to 10
  local max_keywords = 10
  if Config.prompt_logger and Config.prompt_logger.max_keywords then
    max_keywords = Config.prompt_logger.max_keywords
  end
  
  -- Return top N keywords
  local keywords = {}
  for i = 1, math.min(#words, max_keywords) do
    table.insert(keywords, words[i])
  end
  
  return keywords
end

---Load index file for a project
---@param project_root string
---@return table|nil
local function load_index(project_root)
  local prompts_dir = get_prompts_dir(project_root)
  local index_file = prompts_dir:joinpath("index.json")
  
  if not index_file:exists() then
    return nil
  end
  
  local content = index_file:read()
  if not content then
    return nil
  end
  
  local ok, index_data = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end
  
  return index_data
end

---Update index file with new prompt entry
---@param project_root string
---@param prompt_entry table
local function update_index(project_root, prompt_entry)
  local prompts_dir = get_prompts_dir(project_root)
  local index_file = prompts_dir:joinpath("index.json")
  
  -- Load existing index or create new with v2 schema
  local index_data = load_index(project_root) or {
    version = 2,
    last_updated = os.time(),
    prompts = {}
  }
  
  -- Extract keywords for search optimization
  local keywords = extract_search_keywords(prompt_entry.prompt)
  
  -- Create index entry with new fields
  local index_entry = {
    id = prompt_entry.id,
    timestamp = prompt_entry.timestamp,
    unix_time = prompt_entry.unix_time,
    usage_count = prompt_entry.usage_count or 0,
    last_used = prompt_entry.last_used,
    prompt_preview = prompt_entry.prompt:sub(1, 100):gsub("\n", " "),
    filepath = prompt_entry.filepath,
    search_keywords = keywords
  }
  
  -- Add to beginning (newest first)
  table.insert(index_data.prompts, 1, index_entry)
  index_data.last_updated = os.time()
  
  -- Enforce max_entries limit
  local max = Config.prompt_logger.max_entries
  if max > 0 and #index_data.prompts > max then
    -- Trim oldest entries
    for i = #index_data.prompts, max + 1, -1 do
      table.remove(index_data.prompts, i)
    end
  end
  
  -- Write atomically
  local ok, encoded = pcall(vim.json.encode, index_data)
  if ok then
    index_file:write(encoded, "w")
  end
end

---Rebuild index by scanning all prompt files
---@param project_root string
function M.rebuild_index(project_root)
  local prompts_dir = get_prompts_dir(project_root)
  local index_file = prompts_dir:joinpath("index.json")
  
  -- Find all JSON files recursively
  local Scan = require("plenary.scandir")
  local files = Scan.scan_dir(tostring(prompts_dir), {
    hidden = false,
    add_dirs = false,
    respect_gitignore = false,
    search_pattern = "%.json$"
  })
  
  local prompts = {}
  
  for _, filepath in ipairs(files) do
    -- Skip index.json itself
    if not filepath:match("index%.json$") then
      local file = Path:new(filepath)
      local content = file:read()
      if content then
        local ok, prompt_data = pcall(vim.json.decode, content)
        if ok and prompt_data then
          -- Calculate relative path from prompts_dir
          local rel_path = filepath:gsub("^" .. vim.pesc(tostring(prompts_dir)) .. "/", "")
          
          -- Extract keywords for v2 schema
          local keywords = extract_search_keywords(prompt_data.prompt)
          
          -- Build index entry with v2 fields (provide defaults for old prompts)
          table.insert(prompts, {
            id = prompt_data.id,
            timestamp = prompt_data.timestamp,
            unix_time = prompt_data.unix_time,
            usage_count = prompt_data.usage_count or 0,  -- Default to 0 for migration
            last_used = prompt_data.last_used,  -- Will be nil for old prompts
            prompt_preview = prompt_data.prompt:sub(1, 100):gsub("\n", " "),
            filepath = rel_path,
            search_keywords = keywords
          })
        end
      end
    end
  end
  
  -- Sort by usage_count DESC, then unix_time DESC (smart ranking)
  table.sort(prompts, function(a, b)
    local a_usage = a.usage_count or 0
    local b_usage = b.usage_count or 0
    
    if a_usage ~= b_usage then
      return a_usage > b_usage  -- Higher usage first
    end
    
    return (a.unix_time or 0) > (b.unix_time or 0)  -- Then by recency
  end)
  
  -- Enforce max_entries limit
  local max = Config.prompt_logger.max_entries
  if max > 0 and #prompts > max then
    for i = #prompts, max + 1, -1 do
      table.remove(prompts, i)
    end
  end
  
  -- Create index with v2 schema
  local index_data = {
    version = 2,
    last_updated = os.time(),
    prompts = prompts
  }
  
  -- Write index
  local ok, encoded = pcall(vim.json.encode, index_data)
  if ok then
    index_file:write(encoded, "w")
    Utils.info("Index rebuilt successfully with " .. #prompts .. " prompts")
  else
    Utils.error("Failed to rebuild index")
  end
end

---Increment usage count for a prompt when it's reused
---@param prompt_id string
function M.increment_usage_count(prompt_id)
  -- Need to find the prompt file across all projects
  local home = vim.fn.expand("~")
  local base_prompts_dir = Path:new(home):joinpath(".avante"):joinpath("prompts")
  
  if not base_prompts_dir:exists() then
    return
  end
  
  -- Scan all project directories
  local Scan = require("plenary.scandir")
  local project_dirs = Scan.scan_dir(tostring(base_prompts_dir), {
    hidden = false,
    add_dirs = true,
    only_dirs = true,
    depth = 1
  })
  
  -- Search for the prompt file by ID
  for _, project_dir_path in ipairs(project_dirs) do
    local project_dir = Path:new(project_dir_path)
    
    -- Scan all JSON files in this project
    local files = Scan.scan_dir(tostring(project_dir), {
      hidden = false,
      add_dirs = false,
      respect_gitignore = false,
      search_pattern = "%.json$"
    })
    
    for _, filepath in ipairs(files) do
      if not filepath:match("index%.json$") then
        local file = Path:new(filepath)
        local content = file:read()
        if content then
          local ok, prompt_data = pcall(vim.json.decode, content)
          if ok and prompt_data and prompt_data.id == prompt_id then
            -- Found the prompt! Increment usage count
            prompt_data.usage_count = (prompt_data.usage_count or 0) + 1
            prompt_data.last_used = os.time()
            
            -- Write it back
            local write_ok, encoded = pcall(vim.json.encode, prompt_data)
            if write_ok then
              file:write(encoded, "w")
              
              -- Update index if it exists and use_index is enabled
              if Config.prompt_logger.use_index and prompt_data.metadata and prompt_data.metadata.project_root then
                -- Rebuild index for this project to reflect new usage count
                M.rebuild_index(prompt_data.metadata.project_root)
              end
            end
            
            return  -- Found and updated, we're done
          end
        end
      end
    end
  end
end

---Log prompt with metadata (new file-based system)
---@param request string
---@param metadata table
function M.log_prompt_v2(request, metadata)
  if request == "" then return end
  if not metadata or not metadata.project_root then
    Utils.warn("Cannot log prompt: missing metadata")
    return
  end
  
  local project_root = metadata.project_root
  
  -- Get date-based directory
  local prompts_dir = get_prompts_dir(project_root)
  local date_dir = get_date_subdir(prompts_dir)
  
  -- Generate unique ID and filename
  local id = generate_unique_id()
  local timestamp = Utils.get_timestamp()
  local unix_time = os.time()
  local filename = generate_filename(timestamp, id)
  
  -- Calculate relative filepath for index (use string manipulation instead of make_relative)
  local date = os.date("*t")
  local rel_filepath = string.format("%04d/%02d/%02d/%s", date.year, date.month, date.day, filename)
  
  -- Create prompt entry
  local prompt_entry = {
    id = id,
    timestamp = timestamp,
    unix_time = unix_time,
    prompt = request,
    usage_count = 0,  -- Initialize to 0 for new prompts
    last_used = nil,  -- Not used yet
    metadata = {
      project_root = metadata.project_root,
      working_directory = metadata.working_directory,
      is_first_prompt = metadata.is_first_prompt or false,
      current_file = metadata.current_file or "",
      filetype = metadata.filetype or "unknown",
      provider = metadata.provider or "unknown",
      model = metadata.model or "unknown",
      chat_session_id = metadata.chat_session_id,
      selected_files = metadata.selected_files or {},
      current_mode_id = metadata.current_mode_id
    },
    filepath = rel_filepath
  }
  
  -- Write prompt file
  local prompt_file = date_dir:joinpath(filename)
  local ok, encoded = pcall(vim.json.encode, prompt_entry)
  if ok then
    prompt_file:write(encoded, "w")
    
    -- Update index if enabled
    if Config.prompt_logger.use_index then
      update_index(project_root, prompt_entry)
    end
    
    -- Update in-memory cache for Ctrl+N/P
    -- Convert to old format for compatibility
    local entry_compat = {
      time = timestamp,
      input = request,
      id = id
    }
    
    -- Remove duplicates
    for i = #entries - 1, 1, -1 do
      if entries[i].input == request then
        table.remove(entries, i)
      end
    end
    
    -- Add new entry
    if #entries > 0 then
      table.insert(entries, #entries, entry_compat)
      idx = #entries - 1
      filtered_entries = entries
    else
      table.insert(entries, entry_compat)
    end
  else
    Utils.error("Failed to log prompt: " .. tostring(encoded))
  end
end

---Initialize prompt logger
function M.init()
  vim.api.nvim_set_hl(0, AVANTE_PROMPT_INPUT_HL, {
    fg = "#ff7700",
    bg = "#333333",
    bold = true,
    italic = true,
    underline = true,
  })

  entries = {}
  
  -- Try to get current project root
  local ok, root = pcall(Utils.root.get)
  if ok and root then
    current_project_root = root
    
    -- Load from index if it exists and is enabled
    if Config.prompt_logger.use_index then
      local index_data = load_index(root)
      if index_data and index_data.prompts then
        -- Load prompts from index into entries
        for i = #index_data.prompts, 1, -1 do
          local prompt_info = index_data.prompts[i]
          table.insert(entries, {
            time = prompt_info.timestamp,
            input = prompt_info.prompt_preview,
            id = prompt_info.id,
            filepath = prompt_info.filepath
          })
        end
      elseif Config.prompt_logger.auto_rebuild_index then
        -- Rebuild index if it doesn't exist and auto_rebuild is enabled
        M.rebuild_index(root)
        -- Try loading again
        local index_data_retry = load_index(root)
        if index_data_retry and index_data_retry.prompts then
          for i = #index_data_retry.prompts, 1, -1 do
            local prompt_info = index_data_retry.prompts[i]
            table.insert(entries, {
              time = prompt_info.timestamp,
              input = prompt_info.prompt_preview,
              id = prompt_info.id,
              filepath = prompt_info.filepath
            })
          end
        end
      end
    end
  end
  
  -- Add empty entry for current input
  table.insert(entries, { input = "" })
  idx = #entries - 1
  filtered_entries = entries
end

---Entries loaded from the index only hold a 100 char preview, so swap in the
---full prompt from disk the first time an entry is actually used.
---@param entry table|nil
---@return table|nil
local function resolve_entry_input(entry)
  if entry and entry.filepath and entry.input and #entry.input <= 100 then
    if current_project_root then
      local prompts_dir = get_prompts_dir(current_project_root)
      local prompt_file = prompts_dir:joinpath(entry.filepath)
      if prompt_file:exists() then
        local content = prompt_file:read()
        if content then
          local ok, prompt_data = pcall(vim.json.decode, content)
          if ok and prompt_data then
            entry.input = prompt_data.prompt
          end
        end
      end
    end
  end

  return entry
end

---Read log entry (maintains compatibility with Ctrl+N/P)
---@param delta number
---@return table|nil
local function _read_log(delta)
  -- index of array starts from 1 in lua, while this idx starts from 0
  idx = ((idx - delta) % #filtered_entries + #filtered_entries) % #filtered_entries

  return resolve_entry_input(filtered_entries[idx + 1])
end

---Logged prompts for the current project, newest first, with full prompt text.
---The last in-memory entry is the placeholder holding the current input, so it
---is excluded here.
---@return table[]
function M.list_entries()
  local result = {}
  for i = #entries - 1, 1, -1 do
    local entry = resolve_entry_input(entries[i])
    if entry and entry.input and entry.input ~= "" then table.insert(result, entry) end
  end
  return result
end

---Update current input (maintains compatibility)
local function update_current_input()
  local user_input = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  if idx == #filtered_entries - 1 or filtered_entries[idx + 1].input ~= user_input then
    entries[#entries].input = user_input

    vim.fn.clearmatches()
    -- Apply filtering if there's user input
    if user_input and user_input ~= "" then
      filtered_entries = {}
      for i = 1, #entries - 1 do
        if entries[i].input:lower():find(user_input:lower(), 1, true) then
          table.insert(filtered_entries, entries[i])
        end
      end
      -- Add the current input as the last entry
      table.insert(filtered_entries, entries[#entries])

      vim.fn.matchadd(AVANTE_PROMPT_INPUT_HL, user_input)
    else
      filtered_entries = entries
    end
    idx = #filtered_entries - 1
  end
end

---Create callback for log retrieval (Ctrl+N/P compatibility)
---@param delta number
---@return function
function M.on_log_retrieve(delta)
  return function()
    update_current_input()
    local res = _read_log(delta)
    if not res or not res.input then
      vim.notify("No log entry found.", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(res.input, "\n", { plain = true }))
    vim.api.nvim_win_set_cursor(
      0,
      { vim.api.nvim_buf_line_count(0), #vim.api.nvim_buf_get_lines(0, -2, -1, false)[1] }
    )
  end
end

return M