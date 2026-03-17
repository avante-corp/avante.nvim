local fn = vim.fn
local Utils = require("avante.utils")
local Path = require("plenary.path")
local Scan = require("plenary.scandir")
local Config = require("avante.config")

---@class avante.Path
---@field history_path Path
---@field cache_path Path
---@field data_path Path
local P = {}

---@param bufnr integer | nil
---@return string dirname
local function generate_project_dirname_in_storage(bufnr)
  local project_root = Utils.root.get({
    buf = bufnr,
  })
  -- Replace path separators with double underscores
  local path_with_separators = string.gsub(project_root, "/", "__")
  -- Replace other non-alphanumeric characters with single underscores
  local dirname = string.gsub(path_with_separators, "[^A-Za-z0-9._]", "_")
  return tostring(Path:new("projects"):joinpath(dirname))
end

local function filepath_to_filename(filepath) return tostring(filepath):sub(tostring(filepath:parent()):len() + 2) end

-- History path
local History = {}

function History.get_history_dir(bufnr)
  local dirname = generate_project_dirname_in_storage(bufnr)
  local history_dir = Path:new(Config.history.storage_path):joinpath(dirname):joinpath("history")
  if not history_dir:exists() then
    history_dir:mkdir({ parents = true })

    local metadata_filepath = history_dir:joinpath("metadata.json")
    local metadata = {
      project_root = Utils.root.get({
        buf = bufnr,
      }),
    }
    metadata_filepath:write(vim.json.encode(metadata), "w")
  end
  return history_dir
end

---@return avante.ChatHistory[]
function History.list(bufnr)
  local history_dir = History.get_history_dir(bufnr)
  local files = vim.fn.glob(tostring(history_dir:joinpath("*.json")), true, true)
  local latest_filename = History.get_latest_filename(bufnr, false)
  local res = {}
  for _, filename in ipairs(files) do
    if not filename:match("metadata.json") then
      local filepath = Path:new(filename)
      local history = History.from_file(filepath)
      if history then table.insert(res, history) end
    end
  end
  --- sort by timestamp
  --- sort by latest_filename
  table.sort(res, function(a, b)
    local H = require("avante.history")
    if a.filename == latest_filename then return true end
    if b.filename == latest_filename then return false end
    local a_messages = H.get_history_messages(a)
    local b_messages = H.get_history_messages(b)
    local timestamp_a = #a_messages > 0 and a_messages[#a_messages].timestamp or a.timestamp
    local timestamp_b = #b_messages > 0 and b_messages[#b_messages].timestamp or b.timestamp
    return timestamp_a > timestamp_b
  end)
  return res
end

---List all chat histories across all projects
---@return avante.ChatHistory[]
function History.list_all()
  local Scan = require("plenary.scandir")
  local projects_dir = Path:new(Config.history.storage_path):joinpath("projects")
  if not projects_dir:exists() then return {} end

  local all_histories = {}
  local dirs = Scan.scan_dir(tostring(projects_dir), { depth = 1, add_dirs = true, only_dirs = true })

  for _, project_dir_path in ipairs(dirs) do
    local project_dir = Path:new(project_dir_path)
    local history_dir = project_dir:joinpath("history")

    if history_dir:exists() then
      local files = vim.fn.glob(tostring(history_dir:joinpath("*.json")), true, true)
      for _, filename in ipairs(files) do
        if not filename:match("metadata.json") then
          local filepath = Path:new(filename)
          local history = History.from_file(filepath)
          if history then
            table.insert(all_histories, history)
          end
        end
      end
    end
  end

  -- Sort by timestamp (most recent first)
  table.sort(all_histories, function(a, b)
    local H = require("avante.history")
    local a_messages = H.get_history_messages(a)
    local b_messages = H.get_history_messages(b)
    local timestamp_a = #a_messages > 0 and a_messages[#a_messages].timestamp or a.timestamp
    local timestamp_b = #b_messages > 0 and b_messages[#b_messages].timestamp or b.timestamp
    return timestamp_a > timestamp_b
  end)

  return all_histories
end

-- Get a chat history file name given a buffer
---@param bufnr integer
---@param new boolean
---@return Path
function History.get_latest_filepath(bufnr, new)
  local history_dir = History.get_history_dir(bufnr)
  local filename = History.get_latest_filename(bufnr, new)
  return history_dir:joinpath(filename)
end

function History.get_filepath(bufnr, filename)
  local history_dir = History.get_history_dir(bufnr)
  return history_dir:joinpath(filename)
end

function History.get_metadata_filepath(bufnr)
  local history_dir = History.get_history_dir(bufnr)
  return history_dir:joinpath("metadata.json")
end

function History.get_latest_filename(bufnr, new)
  local history_dir = History.get_history_dir(bufnr)
  local filename
  local metadata_filepath = History.get_metadata_filepath(bufnr)
  if metadata_filepath:exists() and not new then
    local metadata_content = metadata_filepath:read()
    local metadata = vim.json.decode(metadata_content)
    filename = metadata.latest_filename
  end
  if not filename or filename == "" then
    local pattern = tostring(history_dir:joinpath("*.json"))
    local files = vim.fn.glob(pattern, true, true)
    filename = #files .. ".json"
    if #files > 0 and not new then filename = (#files - 1) .. ".json" end
  end
  return filename
end

function History.save_latest_filename(bufnr, filename)
  local metadata_filepath = History.get_metadata_filepath(bufnr)
  local metadata = {}
  if metadata_filepath:exists() then
    local metadata_content = metadata_filepath:read()
    metadata = vim.json.decode(metadata_content)
  end
  if metadata.project_root == nil then metadata.project_root = Utils.root.get({
    buf = bufnr,
  }) end
  metadata.latest_filename = filename
  metadata_filepath:write(vim.json.encode(metadata), "w")
end

---Save last-session info to metadata (working directory, selected files)
---@param bufnr integer
---@param session_info { working_directory?: string, selected_files?: string[] }
function History.save_last_session(bufnr, session_info)
  local metadata_filepath = History.get_metadata_filepath(bufnr)
  local metadata = {}
  if metadata_filepath:exists() then
    local ok, content = pcall(function() return metadata_filepath:read() end)
    if ok and content then
      local dok, decoded = pcall(vim.json.decode, content)
      if dok then metadata = decoded end
    end
  end
  metadata.last_session = session_info
  metadata_filepath:write(vim.json.encode(metadata), "w")
end

---Load last-session info from metadata
---@param bufnr integer
---@return { working_directory?: string, selected_files?: string[] } | nil
function History.load_last_session(bufnr)
  local metadata_filepath = History.get_metadata_filepath(bufnr)
  if not metadata_filepath:exists() then return nil end
  local ok, content = pcall(function() return metadata_filepath:read() end)
  if not ok or not content then return nil end
  local dok, metadata = pcall(vim.json.decode, content)
  if not dok or not metadata then return nil end
  return metadata.last_session
end

---@param bufnr integer
function History.new(bufnr)
  local filepath = History.get_latest_filepath(bufnr, true)
  ---@type avante.ChatHistory
  local history = {
    title = "untitled",
    timestamp = Utils.get_timestamp(),
    entries = {},
    messages = {},
    todos = {},
    tags = {},
    filename = filepath_to_filename(filepath),
    working_directory = vim.fn.getcwd(),
    avante_mode = nil,
  }
  return history
end

---Attempts to load chat history from a given file
---@param filepath Path
---@return avante.ChatHistory|nil
function History.from_file(filepath)
  if filepath:exists() then
    local content = filepath:read()
    if content ~= nil then
      local decode_ok, history = pcall(vim.json.decode, content)
      if decode_ok and type(history) == "table" then
        if not history.title or type(history.title) ~= "string" then history.title = "untitled" end
        if not history.timestamp or type(history.timestamp) ~= "string" then history.timestamp = Utils.get_timestamp() end
        -- TODO: sanitize individual entries of the lists below as well.
        if not vim.islist(history.entries) then history.entries = {} end
        if not vim.islist(history.messages) then history.messages = {} end
        if not vim.islist(history.todos) then history.todos = {} end
        if not vim.islist(history.tags) then history.tags = {} end
        if history.pinned == nil then history.pinned = history.starred or false end
        if history.last_seen_message_count == nil then
          history.last_seen_message_count = #(history.messages or {})
        end
        ---@cast history avante.ChatHistory
        history.filename = filepath_to_filename(filepath)
        return history
      end
    end
  end
end

-- Loads the chat history for the given buffer.
---@param bufnr integer
---@param filename string?
---@return avante.ChatHistory
function History.load(bufnr, filename)
  local history_filepath = filename and History.get_filepath(bufnr, filename)
    or History.get_latest_filepath(bufnr, false)
  return History.from_file(history_filepath) or History.new(bufnr)
end

-- Saves the chat history for the given buffer.
---@param bufnr integer
---@param history avante.ChatHistory
function History.save(bufnr, history)
  local history_filepath = History.get_filepath(bufnr, history.filename)
  history_filepath:write(vim.json.encode(history), "w")
  History.save_latest_filename(bufnr, history.filename)
end

--- Deletes a specific chat history file.
---@param bufnr integer
---@param filename string
function History.delete(bufnr, filename)
  local history_filepath = History.get_filepath(bufnr, filename)
  if history_filepath:exists() then
    local was_latest = (filename == History.get_latest_filename(bufnr, false))
    history_filepath:rm()

    if was_latest then
      local remaining_histories = History.list(bufnr) -- This list is sorted by recency
      if #remaining_histories > 0 then
        History.save_latest_filename(bufnr, remaining_histories[1].filename)
      else
        -- No histories left, clear the latest_filename from metadata
        local metadata_filepath = History.get_metadata_filepath(bufnr)
        if metadata_filepath:exists() then
          local metadata_content = metadata_filepath:read()
          local metadata = vim.json.decode(metadata_content)
          metadata.latest_filename = nil -- Or "", depending on desired behavior for an empty latest
          metadata_filepath:write(vim.json.encode(metadata), "w")
        end
      end
    end
  else
    Utils.warn("History file not found: " .. tostring(history_filepath))
  end
end

P.history = History

---@return table[] List of projects with their information
---@type { data: table[]|nil, timestamp: number }
local _projects_cache = { data = nil, timestamp = 0 }
local PROJECTS_CACHE_TTL = 30 -- seconds

function P.list_projects()
  local now = vim.uv.now() / 1000
  if _projects_cache.data and (now - _projects_cache.timestamp) < PROJECTS_CACHE_TTL then
    return _projects_cache.data
  end

  local projects_dir = Path:new(Config.history.storage_path):joinpath("projects")
  if not projects_dir:exists() then return {} end

  local projects = {}
  local dirs = Scan.scan_dir(tostring(projects_dir), { depth = 1, add_dirs = true, only_dirs = true })

  for _, dir_path in ipairs(dirs) do
    local project_dir = Path:new(dir_path)
    local history_dir = project_dir:joinpath("history")

    local metadata_file = history_dir:joinpath("metadata.json")
    local project_root = ""
    if metadata_file:exists() then
      local content = metadata_file:read()
      if content then
        local metadata = vim.json.decode(content)
        if metadata and metadata.project_root then project_root = metadata.project_root end
      end
    end

    -- Skip if project_root is empty
    if project_root == "" then goto continue end

    -- Count history files
    local history_count = 0
    if history_dir:exists() then
      local history_files = vim.fn.glob(tostring(history_dir:joinpath("*.json")), true, true)
      for _, file in ipairs(history_files) do
        if not file:match("metadata.json") then history_count = history_count + 1 end
      end
    end

    table.insert(projects, {
      name = filepath_to_filename(project_dir),
      root = project_root,
      history_count = history_count,
      directory = tostring(project_dir),
    })

    ::continue::
  end

  -- Sort by history count (most active projects first)
  table.sort(projects, function(a, b) return a.history_count > b.history_count end)

  _projects_cache.data = projects
  _projects_cache.timestamp = now

  return projects
end

-- Prompt path
local Prompt = {}

-- Given a mode, return the file name for the custom prompt.
---@param mode AvanteLlmMode
---@return string
function Prompt.get_custom_prompts_filepath(mode) return string.format("custom.%s.avanterules", mode) end

function Prompt.get_builtin_prompts_filepath(mode) return string.format("%s.avanterules", mode) end

---@class AvanteTemplates
---@field initialize fun(cache_directory: string, project_directory: string): nil
---@field render fun(template: string, context: AvanteTemplateOptions): string
local _templates_lib = nil

Prompt.custom_modes = {
  agentic = true,
  legacy = true,
  editing = true,
  suggesting = true,
}

Prompt.custom_prompts_contents = {}

---@param project_root string
---@return string templates_dir
function Prompt.get_templates_dir(project_root)
  if not P.available() then error("Make sure to build avante (missing avante_templates)", 2) end

  -- get root directory of given bufnr
  local directory = Path:new(project_root)
  if Utils.get_os_name() == "windows" then directory = Path:new(directory:absolute():gsub("^%a:", "")[1]) end
  ---@cast directory Path
  ---@type Path
  local cache_prompt_dir = P.cache_path:joinpath(directory)
  if not cache_prompt_dir:exists() then cache_prompt_dir:mkdir({ parents = true }) end

  local function find_rules(dir)
    if not dir then return end
    if vim.fn.isdirectory(dir) ~= 1 then return end

    local scanner = Scan.scan_dir(dir, { depth = 1, add_dirs = true })
    for _, entry in ipairs(scanner) do
      local file = Path:new(entry)
      if file:is_file() then
        local pieces = vim.split(entry, "/")
        local piece = pieces[#pieces]
        local mode = piece:match("([^.]+)%.avanterules$")
        if not mode or not Prompt.custom_modes[mode] then goto continue end
        if Prompt.custom_prompts_contents[mode] == nil then
          Utils.info(string.format("Using %s as %s system prompt", entry, mode))
          Prompt.custom_prompts_contents[mode] = file:read()
        end
      end
      ::continue::
    end
  end

  if Config.rules.project_dir then
    local project_rules_path = Path:new(Config.rules.project_dir)
    if not project_rules_path:is_absolute() then project_rules_path = directory:joinpath(project_rules_path) end
    find_rules(tostring(project_rules_path))
  end
  find_rules(Config.rules.global_dir)
  find_rules(directory:absolute())

  local source_dir =
    Path:new(debug.getinfo(1).source:match("@?(.*/)"):gsub("/lua/avante/path.lua$", "") .. "templates")
  -- Copy built-in templates to cache directory (only if not overridden by user templates)
  source_dir:copy({
    destination = cache_prompt_dir,
    recursive = true,
    override = true,
  })

  -- Check for override prompt
  local override_prompt_dir = Config.override_prompt_dir
  if override_prompt_dir then
    -- Handle the case where override_prompt_dir is a function
    if type(override_prompt_dir) == "function" then
      local ok, result = pcall(override_prompt_dir)
      if ok and result then override_prompt_dir = result end
    end

    if override_prompt_dir then
      local user_template_path = Path:new(override_prompt_dir)
      if user_template_path:exists() then
        local user_scanner = Scan.scan_dir(user_template_path:absolute(), { depth = 1, add_dirs = false })
        for _, entry in ipairs(user_scanner) do
          local file = Path:new(entry)
          if file:is_file() then
            local pieces = vim.split(entry, "/")
            local piece = pieces[#pieces]

            if piece == "base.avanterules" then
              local content = file:read()

              if not content:match("{%% block extra_prompt %%}[%s,\\n]*{%% endblock %%}") then
                file:write("{% block extra_prompt %}\n", "a")
                file:write("{% endblock %}\n", "a")
              end

              if not content:match("{%% block custom_prompt %%}[%s,\\n]*{%% endblock %%}") then
                file:write("{% block custom_prompt %}\n", "a")
                file:write("{% endblock %}", "a")
              end
            end
            file:copy({ destination = cache_prompt_dir:joinpath(piece) })
          end
        end
      end
    end
  end

  vim.iter(Prompt.custom_prompts_contents):filter(function(_, v) return v ~= nil end):each(function(k, v)
    local orig_file = cache_prompt_dir:joinpath(Prompt.get_builtin_prompts_filepath(k))
    local orig_content = orig_file:read()
    local f = cache_prompt_dir:joinpath(Prompt.get_custom_prompts_filepath(k))
    f:write(orig_content, "w")
    f:write("{% block custom_prompt -%}\n", "a")
    f:write(v, "a")
    f:write("\n{%- endblock %}", "a")
  end)

  local dir = cache_prompt_dir:absolute()
  return dir
end

---@param mode AvanteLlmMode
---@return string
function Prompt.get_filepath(mode)
  if Prompt.custom_prompts_contents[mode] ~= nil then return Prompt.get_custom_prompts_filepath(mode) end
  return Prompt.get_builtin_prompts_filepath(mode)
end

---@param path string
---@param opts AvanteTemplateOptions
function Prompt.render_file(path, opts) return _templates_lib.render(path, opts) end

---@param mode AvanteLlmMode
---@param opts AvanteTemplateOptions
function Prompt.render_mode(mode, opts)
  local filepath = Prompt.get_filepath(mode)
  return _templates_lib.render(filepath, opts)
end

function Prompt.initialize(cache_directory, project_directory)
  _templates_lib.initialize(cache_directory, project_directory)
end

P.prompts = Prompt

local RepoMap = {}

-- Get a chat history file name given a buffer
---@param project_root string
---@param ext string
---@return string
function RepoMap.filename(project_root, ext)
  -- Replace path separators with double underscores
  local path_with_separators = fn.substitute(project_root, "/", "__", "g")
  -- Replace other non-alphanumeric characters with single underscores
  return fn.substitute(path_with_separators, "[^A-Za-z0-9._]", "_", "g") .. "." .. ext .. ".repo_map.json"
end

function RepoMap.get(project_root, ext) return Path:new(P.data_path):joinpath(RepoMap.filename(project_root, ext)) end

function RepoMap.save(project_root, ext, data)
  local file = RepoMap.get(project_root, ext)
  file:write(vim.json.encode(data), "w")
end

function RepoMap.load(project_root, ext)
  local file = RepoMap.get(project_root, ext)
  if file:exists() then
    local content = file:read()
    return content ~= nil and vim.json.decode(content) or {}
  end
  return nil
end

P.repo_map = RepoMap

---@return AvanteTemplates|nil
function P._init_templates_lib()
  if _templates_lib ~= nil then return _templates_lib end
  local ok, module = pcall(require, "avante_templates")
  ---@cast module AvanteTemplates
  ---@cast ok boolean
  if not ok then return nil end
  _templates_lib = module

  return _templates_lib
end

function P.setup()
  local history_path = Path:new(Config.history.storage_path)
  if not history_path:exists() then history_path:mkdir({ parents = true }) end
  P.history_path = history_path

  local cache_path = Path:new(Utils.join_paths(vim.fn.stdpath("cache"), "avante"))
  if not cache_path:exists() then cache_path:mkdir({ parents = true }) end
  P.cache_path = cache_path

  local data_path = Path:new(Utils.join_paths(vim.fn.stdpath("data"), "avante"))
  if not data_path:exists() then data_path:mkdir({ parents = true }) end
  P.data_path = data_path

  vim.defer_fn(P._init_templates_lib, 1000)
end

function P.available() return P._init_templates_lib() ~= nil end

function P.clear()
  P.cache_path:rm({ recursive = true })
  P.history_path:rm({ recursive = true })

  if not P.cache_path:exists() then P.cache_path:mkdir({ parents = true }) end
  if not P.history_path:exists() then P.history_path:mkdir({ parents = true }) end
end

return P