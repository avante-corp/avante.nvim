local Utils = require("avante.utils")
local Path = require("plenary.path")
local Config = require("avante.config")
local Api = require("avante.api")

---@param bufnr integer | nil
---@param project_root? string
---@return string dirname
local function generate_project_dirname_in_storage(bufnr, project_root)
  project_root = project_root or Utils.root.get({
    buf = bufnr,
  })
  -- Replace path separators with double underscores
  local path_with_separators = string.gsub(project_root, "/", "__")
  -- Replace other non-alphanumeric characters with single underscores
  local dirname = string.gsub(path_with_separators, "[^A-Za-z0-9._]", "_")
  return tostring(Path:new("projects"):joinpath(dirname))
end

local function filepath_to_filename(filepath) return tostring(filepath):sub(tostring(filepath:parent()):len() + 2) end

local M = {}

---@param metadata {acp_provider?: string, acp_session_id?: string, acp_session_cwd?: string}
---@param filepath Path
---@return avante.ChatHistory|nil
local function acp_history_from_metadata(metadata, filepath)
  if
    type(metadata.acp_provider) ~= "string"
    or metadata.acp_provider == ""
    or type(metadata.acp_session_id) ~= "string"
    or metadata.acp_session_id == ""
  then
    return
  end
  return {
    title = "untitled",
    timestamp = Utils.get_timestamp(),
    entries = {},
    messages = {},
    todos = {},
    filename = filepath_to_filename(filepath),
    acp_provider = metadata.acp_provider,
    acp_session_id = metadata.acp_session_id,
    acp_session_cwd = metadata.acp_session_cwd,
    acp_session_import_pending = true,
  }
end

---@param history avante.ChatHistory
---@param is_acp_metadata boolean
---@return boolean
local function history_matches_current_provider(history, is_acp_metadata)
  if Api.is_acp_provider() then return is_acp_metadata and history.acp_provider == Config.provider end
  return not is_acp_metadata
end

---Returns the folder that contains past prompts
---@see avante.Config.History
---@param bufnr? integer
---@param project_root? string
---@return Path
function M.get_history_dir(bufnr, project_root)
  local dirname = generate_project_dirname_in_storage(bufnr, project_root)
  local history_dir = Path:new(Config.history.storage_path):joinpath(dirname):joinpath("history")
  if not history_dir:exists() then
    history_dir:mkdir({ parents = true })

    local metadata_filepath = history_dir:joinpath("metadata.json")
    local metadata = {
      project_root = project_root or Utils.root.get({
        buf = bufnr,
      }),
    }
    metadata_filepath:write(vim.json.encode(metadata), "w")
  end
  return history_dir
end

---Lists all conversations with the latest first, ordered by timestamp
---@param bufnr integer
---@param project_root? string
---@return avante.ChatHistory[]
function M.list(bufnr, project_root)
  local history_dir = M.get_history_dir(bufnr, project_root)
  ---@type string[]
  local files = vim.fn.glob(tostring(history_dir:joinpath("*.json")), true, true)
  local latest_filename = M.get_latest_filename(bufnr, false, project_root)
  ---@type avante.ChatHistory[]
  local res = {}
  for _, filename in ipairs(files) do
    if not filename:match("metadata.json") then
      local filepath = Path:new(filename)
      local history, is_acp_metadata = M.from_file(filepath)
      if history and history_matches_current_provider(history, is_acp_metadata == true) then
        table.insert(res, history)
      end
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

-- Get a chat history file name given a buffer
---@param bufnr integer
---@param new boolean
---@param project_root? string
---@return Path?
function M.get_latest_filepath(bufnr, new, project_root)
  local filename = M.get_latest_filename(bufnr, new, project_root)
  if not filename then return nil end
  return M.get_filepath(bufnr, filename, project_root)
end

function M.get_filepath(bufnr, filename, project_root)
  local history_dir = M.get_history_dir(bufnr, project_root)
  return history_dir:joinpath(filename)
end

function M.get_metadata_filepath(bufnr, project_root)
  local history_dir = M.get_history_dir(bufnr, project_root)
  return history_dir:joinpath("metadata.json")
end

function M.get_latest_filename(bufnr, new, project_root)
  if not new then
    local metadata_filepath = M.get_metadata_filepath(bufnr, project_root)
    if not metadata_filepath:exists() then return nil end
    local metadata_content = metadata_filepath:read()
    ---@type {latest_filename?: string}
    local metadata = vim.json.decode(metadata_content)
    return metadata.latest_filename ~= "" and metadata.latest_filename or nil
  end

  local history_dir = M.get_history_dir(bufnr, project_root)
  local pattern = tostring(history_dir:joinpath("*.json"))
  ---@type string[]
  local files = vim.fn.glob(pattern, true, true)
  local max_id = -1
  for _, file in ipairs(files) do
    local id = tonumber(vim.fs.basename(file):match("^(%d+)%.json$"))
    if id and id > max_id then max_id = id end
  end
  return (max_id + 1) .. ".json"
end

---Update metadata with latest history
function M.save_latest_filename(bufnr, filename, project_root)
  local metadata_filepath = M.get_metadata_filepath(bufnr, project_root)
  local metadata = {}
  if metadata_filepath:exists() then
    local metadata_content = metadata_filepath:read()
    metadata = vim.json.decode(metadata_content)
  end
  if metadata.project_root == nil then
    metadata.project_root = project_root or Utils.root.get({
      buf = bufnr,
    })
  end
  metadata.latest_filename = filename
  metadata_filepath:write(vim.json.encode(metadata), "w")
end

---@param bufnr integer
---@param project_root? string
---@return avante.ChatHistory
function M.new(bufnr, project_root)
  local filepath = M.get_latest_filepath(bufnr, true, project_root)
  local is_acp = Api.is_acp_provider()
  ---@type avante.ChatHistory
  local history = {
    title = "untitled",
    timestamp = Utils.get_timestamp(),
    entries = {},
    messages = {},
    todos = {},
    filename = filepath_to_filename(filepath),
    acp_provider = is_acp and Config.provider or nil,
    acp_session_cwd = is_acp and (project_root or Utils.root.get({ buf = bufnr })) or nil,
  }
  return history
end

---Attempts to load chat history from a given file
---@param filepath Path
---@return avante.ChatHistory|nil history
---@return boolean? is_acp_metadata
function M.from_file(filepath)
  if filepath:exists() then
    local content = filepath:read()
    if content ~= nil then
      local decode_ok, history = pcall(vim.json.decode, content)
      if decode_ok and type(history) == "table" then
        if history.acp_provider and history.acp_session_id then
          local acp_history = acp_history_from_metadata(history, filepath)
          if acp_history then return acp_history, true end
          return
        end
        if not history.title or type(history.title) ~= "string" then history.title = "untitled" end
        if type(history.timestamp) ~= "string" then history.timestamp = Utils.get_timestamp() end
        -- TODO: sanitize individual entries of the lists below as well.
        if not vim.islist(history.entries) then history.entries = {} end
        if not vim.islist(history.messages) then history.messages = {} end
        if not vim.islist(history.todos) then history.todos = {} end
        ---@cast history avante.ChatHistory
        history.filename = filepath_to_filename(filepath)
        return history, false
      end
    end
  end
end

-- Loads the chat history for the given buffer.
---@param bufnr integer
---@param filename string?
---@param project_root? string
---@return avante.ChatHistory
function M.load(bufnr, filename, project_root)
  local history_filepath = filename and M.get_filepath(bufnr, filename, project_root)
    or M.get_latest_filepath(bufnr, false, project_root)
  if not history_filepath then return M.new(bufnr, project_root) end

  local history, is_acp_metadata = M.from_file(history_filepath)
  if history and (not is_acp_metadata or (Config.acp_providers or {})[history.acp_provider]) then return history end
  return M.new(bufnr, project_root)
end

-- Writes chat contents without selecting the chat.
---@param bufnr integer
---@param history avante.ChatHistory
---@param project_root? string
---@return boolean
function M.write(bufnr, history, project_root)
  if history._discarded then return false end
  local history_filepath = M.get_filepath(bufnr, history.filename, project_root)
  if history.acp_provider then
    if not history.acp_session_id or history.acp_session_id == "" then
      local was_latest = history.filename == M.get_latest_filename(bufnr, false, project_root)
      if history_filepath:exists() then M.delete(bufnr, history.filename, project_root) end
      if was_latest then M.save_latest_filename(bufnr, nil, project_root) end
      return false
    end
    history_filepath:write(
      vim.json.encode({
        acp_provider = history.acp_provider,
        acp_session_id = history.acp_session_id,
        acp_session_cwd = history.acp_session_cwd,
      }),
      "w"
    )
    return true
  end
  history_filepath:write(vim.json.encode(history), "w")
  return true
end

-- Saves and selects the chat history for the given buffer.
---@param bufnr integer
---@param history avante.ChatHistory
---@param project_root? string
function M.save(bufnr, history, project_root)
  if M.write(bufnr, history, project_root) then M.save_latest_filename(bufnr, history.filename, project_root) end
end

--- Deletes a specific chat history file.
---@param bufnr integer
---@param filename string
---@param project_root? string
function M.delete(bufnr, filename, project_root)
  local history_filepath = M.get_filepath(bufnr, filename, project_root)
  if history_filepath:exists() then
    local was_latest = (filename == M.get_latest_filename(bufnr, false, project_root))
    vim.fs.rm(tostring(history_filepath))

    if was_latest then
      local remaining_histories = M.list(bufnr, project_root) -- This list is sorted by recency
      if #remaining_histories > 0 then
        M.save_latest_filename(bufnr, remaining_histories[1].filename, project_root)
      else
        -- No histories left, clear the latest_filename from metadata
        local metadata_filepath = M.get_metadata_filepath(bufnr, project_root)
        if metadata_filepath:exists() then
          local metadata_content = metadata_filepath:read()
          ---@type {latest_filename?: string, project_root?: string}
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

return M
