local ACPClient = require("avante.libs.acp_client")
local Config = require("avante.config")
local Path = require("avante.path")
local Selector = require("avante.ui.selector")
local Utils = require("avante.utils")

---@class avante.AcpSessionSelector
local M = {}

---Parses an ISO 8601 timestamp into epoch seconds. Timestamps without a zone are taken as local time.
---@param iso string|nil
---@return integer|nil
function M.parse_timestamp(iso)
  if type(iso) ~= "string" then return nil end
  local year, month, day, hour, min, sec = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not year then return nil end
  local ok, as_local = pcall(os.time, {
    year = tonumber(year) --[[@as integer]],
    month = tonumber(month) --[[@as integer]],
    day = tonumber(day) --[[@as integer]],
    hour = tonumber(hour) --[[@as integer]],
    min = tonumber(min) --[[@as integer]],
    sec = tonumber(sec) --[[@as integer]],
  })
  if not ok or not as_local then return nil end

  local zone = iso:match("Z$") or iso:match("[+-]%d%d:?%d%d$")
  if not zone then return as_local end

  -- The fields are UTC (plus an offset): shift by the local UTC offset in effect on that date.
  -- isdst is cleared so os.time works out daylight saving itself rather than assuming standard time.
  local utc_fields = os.date("!*t", as_local) --[[@as osdate]]
  utc_fields.isdst = nil
  local epoch = as_local + os.difftime(as_local, os.time(utc_fields))
  if zone ~= "Z" then
    local sign, zone_hours, zone_minutes = zone:match("([+-])(%d%d):?(%d%d)")
    local zone_offset = (tonumber(zone_hours) * 3600 + tonumber(zone_minutes) * 60) * (sign == "+" and 1 or -1)
    epoch = epoch - zone_offset
  end
  return math.floor(epoch)
end

---Formats an ISO 8601 timestamp as local "YYYY-MM-DD HH:MM"
---@param iso string|nil
---@return string
function M.format_updated_at(iso)
  if type(iso) ~= "string" then return "" end
  local epoch = M.parse_timestamp(iso)
  if not epoch then return iso end
  return os.date("%Y-%m-%d %H:%M", epoch) --[[@as string]]
end

---Whether the client was started for this provider exactly, so it lists the same account's sessions
---@param client avante.acp.ACPClient
---@param acp_provider table
---@return boolean
local function is_client_for_provider(client, acp_provider)
  local config = client.config
  return config ~= nil
    and config.command == acp_provider.command
    and vim.deep_equal(config.args, acp_provider.args)
    and vim.deep_equal(config.env, acp_provider.env)
    and vim.deep_equal(config.mcp_servers, acp_provider.mcp_servers)
end

-- Sidebar states while a request is in progress
local BUSY_STATES = {
  ["generating"] = true,
  ["tool calling"] = true,
  ["thinking"] = true,
  ["searching"] = true,
  ["compacting"] = true,
}

---Calls `callback` with a ready client for the current provider: the sidebar's own client when it
---is connected, otherwise a temporary one that `release` stops.
---@param sidebar avante.Sidebar|nil
---@param acp_provider table
---@param callback fun(client: avante.acp.ACPClient, release: fun())
local function with_client(sidebar, acp_provider, callback)
  local client = sidebar and sidebar.acp_client
  if client and client:is_ready() and is_client_for_provider(client, acp_provider) then
    callback(client, function() end)
    return
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  local temporary = ACPClient:new(vim.tbl_deep_extend("force", acp_provider, { handlers = {} }))
  local function release() pcall(temporary.stop, temporary) end
  local function fail(message)
    release()
    Utils.error("Failed to start the ACP agent: " .. message)
  end

  -- connect() raises (rather than calling back) when the agent command can't be spawned
  local ok, spawn_err = pcall(temporary.connect, temporary, function(err)
    vim.schedule(function()
      if err then return fail(err.message or tostring(err)) end
      callback(temporary, release)
    end)
  end)
  if not ok then fail((tostring(spawn_err):gsub("^.-:%d+: ", ""))) end
end

---@param bufnr integer
---@return table<string, avante.ChatHistory>
local function histories_by_session_id(bufnr)
  local histories = {}
  for _, history in ipairs(Path.history.list(bufnr)) do
    if history.acp_session_id and history.acp_session_id ~= "" then histories[history.acp_session_id] = history end
  end
  return histories
end

---Resume an ACP session in the sidebar, importing the conversation the agent replays.
---Picking a session that is already linked to a chat re-syncs that chat from the agent.
---@param bufnr integer
---@param session avante.acp.SessionInfo
function M.resume(bufnr, session)
  local Avante = require("avante")
  local sidebar = Avante.get(false)
  if sidebar and BUSY_STATES[sidebar.current_state or ""] then
    Utils.warn("Wait for the current request to finish before resuming another session")
    return
  end

  local history = histories_by_session_id(bufnr)[session.sessionId]
  local created = history == nil
  local previous_filename = Path.history.get_latest_filename(bufnr, false)
  if not history then
    history = Path.history.new(bufnr)
    history.acp_session_id = session.sessionId
  end
  history.acp_session_import_pending = true
  if session.title and session.title ~= "" then history.title = session.title end
  if session.cwd and session.cwd ~= "" then history.acp_session_cwd = session.cwd end
  local updated_at = M.parse_timestamp(session.updatedAt)
  if updated_at then
    history.timestamp = os.date("%Y-%m-%d %H:%M:%S", updated_at) --[[@as string]]
  end
  Path.history.save(bufnr, history)

  if not sidebar then
    Avante._init(vim.api.nvim_get_current_tabpage())
    sidebar = Avante.get(false)
  end

  -- An earlier import that hasn't finished is superseded; its client is stopped below
  if sidebar.pending_acp_import then sidebar:discard_acp_import_chat(sidebar.pending_acp_import) end

  -- A fresh agent process is needed: a connected client never sends session/load, and some
  -- agents keep a stale copy of a session that was continued elsewhere.
  sidebar:stop_acp_client()
  sidebar.pending_acp_import = {
    session_id = session.sessionId,
    filename = history.filename,
    created = created,
    previous_filename = created and previous_filename or nil,
    timestamp = updated_at and history.timestamp or nil,
  }

  if sidebar:is_open() then
    sidebar:switch_to_history_and_reconnect()
  else
    vim.api.nvim_buf_call(bufnr, function() Avante.open_sidebar({}) end)
  end
end

---List the current ACP provider's sessions for this project and resume the selected one
function M.open()
  local acp_provider = Config.acp_providers[Config.provider]
  if not acp_provider then
    Utils.warn("The current provider is not an ACP provider")
    return
  end

  local sidebar = require("avante").get(false)
  local bufnr = sidebar and vim.api.nvim_buf_is_valid(sidebar.code.bufnr) and sidebar.code.bufnr
    or vim.api.nvim_get_current_buf()
  local cwd = Utils.root.get({ buf = bufnr })

  with_client(sidebar, acp_provider, function(client, release)
    if not (client:supports_load_session() and client:supports_list_sessions()) then
      release()
      Utils.warn(Config.provider .. " does not support listing and resuming sessions")
      return
    end

    client:list_all_sessions(cwd, function(sessions, err)
      release()
      vim.schedule(function()
        if err then
          Utils.error("Failed to list sessions: " .. (err.message or tostring(err)))
          return
        end
        if #sessions == 0 then
          Utils.info("No " .. Config.provider .. " sessions found for this project")
          return
        end

        local times = {}
        for _, session in ipairs(sessions) do
          times[session] = M.parse_timestamp(session.updatedAt) or -math.huge
        end
        table.sort(sessions, function(a, b) return times[a] > times[b] end)
        local linked = histories_by_session_id(bufnr)
        ---@type table<string, avante.acp.SessionInfo>
        local by_id = {}
        local items = {}
        for _, session in ipairs(sessions) do
          by_id[session.sessionId] = session
          local title = session.title and session.title ~= "" and session.title or session.sessionId:sub(1, 8)
          local updated_at = M.format_updated_at(session.updatedAt)
          table.insert(items, {
            id = session.sessionId,
            title = (linked[session.sessionId] and "* " or "  ")
              .. title
              .. (updated_at ~= "" and ("  " .. updated_at) or ""),
          })
        end

        Selector:new({
          provider = Config.selector.provider,
          provider_opts = Config.selector.provider_opts,
          title = Config.provider .. " sessions (* = already in avante history)",
          items = items,
          on_select = function(item_ids)
            if not item_ids or #item_ids == 0 then return end
            local session = by_id[item_ids[1]]
            if session then M.resume(bufnr, session) end
          end,
          get_preview_content = function(item_id)
            local session = by_id[item_id]
            if not session then return "", "markdown" end
            local lines = {
              "# " .. (session.title or session.sessionId),
              "",
              "- **Session:** `" .. session.sessionId .. "`",
              "- **Directory:** `" .. (session.cwd or cwd) .. "`",
            }
            if session.updatedAt then
              table.insert(lines, "- **Updated:** " .. M.format_updated_at(session.updatedAt))
            end
            local history = linked[session.sessionId]
            if history then
              table.insert(lines, "- **Avante chat:** " .. history.title .. " (`" .. history.filename .. "`)")
            end
            return table.concat(lines, "\n"), "markdown"
          end,
        }):open()
      end)
    end)
  end)
end

return M
