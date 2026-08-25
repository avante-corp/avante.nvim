--- ACP Thread Data Model
---
--- Owns protocol-level thread state independent of UI.
--- Analogous to Zed's AcpThread entity (crates/acp_thread/src/acp_thread.rs).
---
--- Extracts session lifecycle, handler dispatch, plan tracking, and mode management
--- from sidebar.lua and llm.lua into a single coherent abstraction.

local Config = require("avante.config")
local Utils = require("avante.utils")
local History = require("avante.history")

---@alias AcpThreadState "idle" | "connecting" | "session_creating" | "prompting" | "generating" | "cancelled" | "error"

---@class avante.AcpThreadCallbacks
---@field on_messages_add? fun(messages: avante.HistoryMessage[])
---@field on_plan_update? fun(todos: avante.TODO[])
---@field on_state_change? fun(new_state: AcpThreadState, old_state: AcpThreadState)
---@field on_mode_change? fun(mode_id: string, mode_name: string|nil)
---@field on_stop? fun(opts: table)
---@field on_chunk? fun(chunk: string)
---@field on_error? fun(err: any)
---@field on_session_created? fun(session_id: string)
---@field on_session_loaded? fun(session_id: string, result: table|nil)
---@field on_session_expired? fun(old_session_id: string)
---@field on_available_commands? fun(commands: avante.acp.AvailableCommand[])
---@field on_config_options_change? fun(config_options: avante.acp.ConfigOption[])

---@class avante.AcpPlanStats
---@field total number
---@field completed number
---@field in_progress number
---@field pending number
---@field in_progress_entry avante.acp.PlanEntry|nil

---@class avante.AcpThread
---@field session_id string|nil
---@field connection nil unused; retained so older annotations still resolve
---@field state AcpThreadState
---@field history_messages avante.HistoryMessage[]
---@field tool_call_messages table<string, avante.HistoryMessage>
---@field last_tool_call_message avante.HistoryMessage|nil
---@field plan_entries avante.acp.PlanEntry[]
---@field current_mode_id string|nil
---@field available_modes avante.acp.SessionMode[]
---@field available_commands avante.acp.AvailableCommand[]
---@field config_options avante.acp.ConfigOption[]|nil
---@field in_plan_mode boolean
---@field plan_presented boolean
---@field title string|nil
---@field tags string[]
---@field parent_thread_id string|nil  -- for forked threads
---@field callbacks avante.AcpThreadCallbacks
---@field _prev_text_content string
local AcpThread = {}
AcpThread.__index = AcpThread

---Create a new AcpThread
---@param opts? { session_id?: string, title?: string, tags?: string[], parent_thread_id?: string }
---@return avante.AcpThread
function AcpThread:new(opts)
  opts = opts or {}
  local thread = setmetatable({
    session_id = opts.session_id,
    connection = nil,
    state = "idle",
    history_messages = {},
    tool_call_messages = {},
    last_tool_call_message = nil,
    plan_entries = {},
    current_mode_id = nil,
    available_modes = {},
    in_plan_mode = false,
    plan_presented = false,
    title = opts.title,
    tags = opts.tags or {},
    parent_thread_id = opts.parent_thread_id,
    callbacks = {},
    _prev_text_content = "",
  }, AcpThread)
  return thread
end

---Set callbacks for the thread
---@param callbacks avante.AcpThreadCallbacks
function AcpThread:set_callbacks(callbacks)
  self.callbacks = callbacks
end

---@param new_state AcpThreadState
function AcpThread:_set_state(new_state)
  local old_state = self.state
  if old_state == new_state then return end
  self.state = new_state
  if self.callbacks.on_state_change then
    vim.schedule(function()
      self.callbacks.on_state_change(new_state, old_state)
    end)
  end
end

--- Compute plan statistics (modeled after Zed's Plan::stats)
---@return avante.AcpPlanStats
function AcpThread:plan_stats()
  local stats = {
    total = #self.plan_entries,
    completed = 0,
    in_progress = 0,
    pending = 0,
    in_progress_entry = nil,
  }
  for _, entry in ipairs(self.plan_entries) do
    if entry.status == "completed" then
      stats.completed = stats.completed + 1
    elseif entry.status == "in_progress" then
      stats.in_progress = stats.in_progress + 1
      if not stats.in_progress_entry then
        stats.in_progress_entry = entry
      end
    else
      stats.pending = stats.pending + 1
    end
  end
  return stats
end

--- Format plan progress as a short string for status line
---@return string|nil
function AcpThread:plan_progress_string()
  if #self.plan_entries == 0 then return nil end
  local stats = self:plan_stats()
  local s = "Plan: " .. stats.completed .. "/" .. stats.total
  if stats.in_progress_entry then
    local name = stats.in_progress_entry.content or ""
    if #name > 40 then name = name:sub(1, 37) .. "..." end
    s = s .. " | " .. name
  end
  return s
end

--- Write plan to a temp file in markdown format for :AvantePlan
---@return string path The path to the plan file
function AcpThread:write_plan_file()
  local lines = { "# Agent Plan", "" }
  for _, entry in ipairs(self.plan_entries) do
    local checkbox = "- [ ] "
    if entry.status == "completed" then
      checkbox = "- [x] "
    elseif entry.status == "in_progress" then
      checkbox = "- [~] "
    end
    table.insert(lines, checkbox .. (entry.content or ""))
  end
  local path = vim.fn.tempname() .. "_avante_plan.md"
  local file = io.open(path, "w")
  if file then
    file:write(table.concat(lines, "\n"))
    file:close()
  end
  return path
end

--- Initialize modes after session creation.
---
--- `self.connection` is never assigned, so this used to return immediately and
--- the default-mode logic below never ran. Callers already have the modes, so
--- they are passed in.
---@param modes avante.acp.SessionMode[]|nil
---@param current_mode_id string|nil
function AcpThread:initialize_modes(modes, current_mode_id)
  modes = modes or {}

  if #modes > 0 then
    self.available_modes = modes
    self.current_mode_id = current_mode_id or self.current_mode_id

    Utils.debug("Initialized " .. #self.available_modes .. " modes from agent")
    -- Applying `behaviour.acp_default_mode` is Sidebar:initialize_modes's job;
    -- doing it here too would send session/set_mode twice per session.
  else
    self.available_modes = {}
    self.current_mode_id = nil
    Utils.debug("Agent does not provide session modes")
  end

  -- Config options (ACP spec: supersedes modes). Sidebar:ensure_acp_thread
  -- populates these from the client, so nothing is read from a connection here.
end

--- Apply config options fetched by the caller.
---@param config_options avante.acp.ConfigOption[]|nil
function AcpThread:initialize_config_options(config_options)
  self.config_options = config_options or {}
  if #self.config_options > 0 then
    Utils.debug("Initialized " .. #self.config_options .. " config options from agent")
    if self.callbacks.on_config_options_change then
      self.callbacks.on_config_options_change(self.config_options)
    end
  end
end

--- Cycle to next mode
function AcpThread:cycle_mode()
  if not self.connection or not self.connection:has_modes() then
    Utils.info("Mode cycling not supported by this agent")
    return
  end

  local all_modes = self.connection:all_modes()
  if #all_modes == 0 then
    Utils.info("Mode cycling not supported by this agent")
    return
  end

  local current_idx = 1
  for i, mode in ipairs(all_modes) do
    if mode.id == self.current_mode_id then
      current_idx = i
      break
    end
  end

  local next_idx = (current_idx % #all_modes) + 1
  local next_mode = all_modes[next_idx]

  self:set_mode(next_mode.id, function(_, err)
    if err then
      Utils.warn("Failed to set mode: " .. vim.inspect(err))
    end
  end)
end

--- Set mode
---@param mode_id string
---@param callback? fun(result: table|nil, err: avante.acp.ACPError|nil)
function AcpThread:set_mode(mode_id, callback)
  if not self.connection or not self.session_id then
    if callback then callback(nil, { code = -1, message = "No connection or session" }) end
    return
  end
  self.connection:set_mode(self.session_id, mode_id, function(result, err)
    if not err then
      self.current_mode_id = mode_id
      if self.callbacks.on_mode_change then
        local mode = self.connection:mode_by_id(mode_id)
        local mode_name = mode and mode.name or mode_id
        vim.schedule(function()
          self.callbacks.on_mode_change(mode_id, mode_name)
        end)
      end
    end
    if callback then callback(result, err) end
  end)
end

--- Get mode by ID
---@param mode_id string
---@return avante.acp.SessionMode|nil
function AcpThread:mode_by_id(mode_id)
  if self.connection then
    return self.connection:mode_by_id(mode_id)
  end
  for _, mode in ipairs(self.available_modes) do
    if mode.id == mode_id then return mode end
  end
  return nil
end

--- Handle a session/update notification. This is the main dispatch point
--- extracted from llm.lua:1097-1345.
---@param update table The session update payload
function AcpThread:handle_session_update(update)
  Utils.debug("AcpThread:handle_session_update: sessionUpdate=" .. tostring(update.sessionUpdate))

  if update.sessionUpdate == "plan" then
    self:_handle_plan_update(update)
  elseif update.sessionUpdate == "agent_message_chunk" then
    self:_handle_agent_message_chunk(update)
  elseif update.sessionUpdate == "agent_thought_chunk" then
    self:_handle_agent_thought_chunk(update)
  elseif update.sessionUpdate == "tool_call" then
    self:_handle_tool_call(update)
  elseif update.sessionUpdate == "tool_call_update" then
    self:_handle_tool_call_update(update)
  elseif update.sessionUpdate == "available_commands_update" then
    self:_handle_available_commands(update)
  elseif update.sessionUpdate == "current_mode_update" then
    -- Mode updates are handled by the connection layer via on_mode_changed callback
    -- But we also update local state
    self.current_mode_id = update.currentModeId
  elseif update.sessionUpdate == "config_options_update" then
    -- Config options updates are handled by the connection layer via on_config_options_changed callback
    -- But we also update local state
    if update.configOptions then
      self.config_options = update.configOptions
    end
  end
end

---@param update avante.acp.PlanUpdate
function AcpThread:_handle_plan_update(update)
  self.plan_entries = update.entries or {}
  Utils.debug("Plan update received with " .. #self.plan_entries .. " entries")

  local todos = {}
  for idx, entry in ipairs(self.plan_entries) do
    local status = "todo"
    if entry.status == "in_progress" then status = "doing" end
    if entry.status == "completed" then status = "done" end
    ---@type avante.TODO
    local todo = {
      id = tostring(idx),
      content = entry.content,
      status = status,
      priority = entry.priority,
    }
    table.insert(todos, todo)
  end

  if self.callbacks.on_plan_update then
    vim.schedule(function()
      self.callbacks.on_plan_update(todos)
    end)
  end
end

--- Convert TodoWrite tool input into plan entries and trigger plan update
---@param todos_input table[] Array of {content, status, activeForm} from TodoWrite
function AcpThread:_update_todos_from_tool(todos_input)
  local todos = {}
  for idx, item in ipairs(todos_input) do
    -- Map TodoWrite statuses to our plan statuses
    local status = "todo"
    if item.status == "in_progress" then
      status = "doing"
    elseif item.status == "completed" then
      status = "done"
    elseif item.status == "pending" then
      status = "todo"
    end
    table.insert(todos, {
      id = tostring(idx),
      content = item.content or item.activeForm or "",
      status = status,
    })
  end

  -- Also update plan_entries for consistency
  self.plan_entries = {}
  for _, todo in ipairs(todos) do
    table.insert(self.plan_entries, {
      content = todo.content,
      status = todo.status == "doing" and "in_progress" or (todo.status == "done" and "completed" or "pending"),
    })
  end

  Utils.debug("TodoWrite intercepted with " .. #todos .. " entries")

  if self.callbacks.on_plan_update then
    vim.schedule(function()
      self.callbacks.on_plan_update(todos)
    end)
  end
end

---@param update avante.acp.AgentMessageChunk
function AcpThread:_handle_agent_message_chunk(update)
  if update.content.type ~= "text" then return end

  local messages = self.history_messages
  local last_message = messages[#messages]

  if last_message and last_message.message.role == "assistant" then
    local has_text = false
    local content = last_message.message.content
    if type(content) == "string" then
      last_message.message.content = content .. update.content.text
      has_text = true
    elseif type(content) == "table" then
      for idx, item in ipairs(content) do
        if type(item) == "string" then
          content[idx] = item .. update.content.text
          has_text = true
        end
        if type(item) == "table" and item.type == "text" then
          item.text = item.text .. update.content.text
          has_text = true
        end
      end
    end
    if has_text then
      self:_emit_messages({ last_message })
      return
    end
  end

  local message = History.Message:new("assistant", update.content.text)
  table.insert(self.history_messages, message)
  self:_emit_messages({ message })
end

---@param update avante.acp.AgentThoughtChunk
function AcpThread:_handle_agent_thought_chunk(update)
  if update.content.type ~= "text" then return end

  local messages = self.history_messages
  local last_message = messages[#messages]

  if last_message and last_message.message.role == "assistant" then
    local is_thinking = false
    local content = last_message.message.content
    if type(content) == "table" then
      for idx, item in ipairs(content) do
        if type(item) == "table" and item.type == "thinking" then
          is_thinking = true
          content[idx].thinking = content[idx].thinking .. update.content.text
        end
      end
    end
    if is_thinking then
      self:_emit_messages({ last_message })
      return
    end
  end

  local message = History.Message:new("assistant", {
    type = "thinking",
    thinking = update.content.text,
  })
  table.insert(self.history_messages, message)
  self:_emit_messages({ message })
end

--- Create or update a tool call message
---@param update avante.acp.ToolCallUpdate
---@return avante.HistoryMessage
function AcpThread:_add_tool_call_message(update)
  local message = History.Message:new("assistant", {
    type = "tool_use",
    id = update.toolCallId,
    name = update.kind or update.title,
    input = update.rawInput or {},
  }, {
    uuid = update.toolCallId,
  })
  self.last_tool_call_message = message
  message.acp_tool_call = update
  if update.status == "pending" or update.status == "in_progress" then
    message.is_calling = true
  end
  self.tool_call_messages[update.toolCallId] = message
  if update.rawInput then
    local description = update.rawInput.description
    if description then
      message.tool_use_logs = message.tool_use_logs or {}
      table.insert(message.tool_use_logs, description)
    end
  end
  self:_emit_messages({ message })
  return message
end

--- Track file edits from an ACP tool call update (shared by tool_call and tool_call_update)
---@param update avante.acp.ToolCallUpdate
function AcpThread:_track_file_edit(update)
  local ChangedFiles = require("avante.changed_files")
  -- tool_call_update may not carry title/kind — fall back to the stored tool call message
  local stored = self.tool_call_messages[update.toolCallId]
  local stored_acp = stored and stored.acp_tool_call or {}
  local tool_title = update.title or stored_acp.title or ""
  local tool_kind = update.kind or stored_acp.kind or ""

  local is_write_tool = tool_kind == "edit" or tool_kind == "delete" or tool_kind == "move"
  if not is_write_tool then
    for _, name in ipairs(ChangedFiles.ACP_WRITE_TOOL_TITLES) do
      if tool_title == name or tool_title:match("^" .. vim.pesc(name) .. "[^%w]") then
        is_write_tool = true
        break
      end
    end
  end
  if not is_write_tool then return end

  local raw = update.rawInput or stored_acp.rawInput or {}
  local path = raw.file_path or raw.path or raw.rel_path or raw.filepath
  local locations = update.locations or stored_acp.locations
  if not path and locations and #locations > 0 then
    path = locations[1].path
  end

  -- ACP's `diff` tool-call content carries {path, oldText, newText}. Some
  -- agents (cursor) report an edit *only* this way: rawInput and locations stay
  -- empty and the title is a bare "Edit File", so without this the edit is
  -- invisible to /files.
  local diff_entry = nil
  for _, item in ipairs(update.content or stored_acp.content or {}) do
    if type(item) == "table" and item.type == "diff" and type(item.path) == "string" then
      diff_entry = item
      break
    end
  end
  if not path and diff_entry then path = diff_entry.path end
  -- Also try to extract path from the title (e.g. "Write(src/foo.lua)" or "Edit(src/foo.lua)")
  if not path then
    local title_path = tool_title:match("^%w+%((.+)%)$")
    if title_path then path = title_path end
  end
  if not path then return end

  vim.schedule(function()
    local sidebar = require("avante").get()
    if not sidebar or not sidebar._current_session_ctx then return end
    local abs_path = vim.fn.fnamemodify(path, ":p")
    local Helpers = require("avante.llm_tools.helpers")

    -- Prefer the agent's own "before" text: it is exact, and it survives the
    -- case where the path only arrives after the file has already been written.
    if diff_entry and type(diff_entry.oldText) == "string" then
      Helpers.record_file_snapshot(abs_path, sidebar._current_session_ctx, diff_entry.oldText)
    end

    if update.status == "completed" or update.status == "failed" then
      Helpers.track_edited_file(abs_path, sidebar._current_session_ctx, tool_title)
    else
      -- Snapshot on *any* pre-completion update that yields a path, not just
      -- pending/in_progress. Agents announce the tool with no path at all
      -- (rawInput = {}, locations = []) and only fill it in on later updates
      -- that carry no status field, so keying on status meant the "before"
      -- content was never captured and every change diffed against empty --
      -- which is why /files reported whole files as pure additions.
      -- snapshot_file_for_review is idempotent, so repeating this is free.
      Helpers.snapshot_file_for_review(abs_path, sidebar._current_session_ctx)
    end
  end)
end

---@param update avante.acp.ToolCallUpdate
function AcpThread:_handle_tool_call(update)
  self:_add_tool_call_message(update)

  -- Detect plan mode transitions
  local tool_title = update.title or ""
  if tool_title:match("EnterPlanMode") or tool_title:lower():match("enter.*plan.*mode") then
    self.in_plan_mode = true
    Utils.info("Agent entered plan mode")
    if self.callbacks.on_state_change then
      vim.schedule(function()
        self.callbacks.on_state_change(self.state, self.state) -- trigger re-render
      end)
    end
  elseif tool_title:match("ExitPlanMode") or tool_title:lower():match("exit.*plan.*mode") then
    self.plan_presented = true
    Utils.info("Plan ready for approval - provide feedback or approve to proceed")
  end

  -- Intercept TodoWrite tool calls to populate the plan container
  if tool_title:match("TodoWrite") or tool_title:match("write_todos") then
    local raw = update.rawInput or {}
    local todos_input = raw.todos
    if todos_input and type(todos_input) == "table" and #todos_input > 0 then
      self:_update_todos_from_tool(todos_input)
    end
  end

  -- Track file edits (some tools arrive already completed in the initial tool_call)
  self:_track_file_edit(update)
end

---@param update avante.acp.ToolCallUpdate
function AcpThread:_handle_tool_call_update(update)
  local tool_call_message = self.tool_call_messages[update.toolCallId]
  if not tool_call_message then
    tool_call_message = History.Message:new("assistant", {
      type = "tool_use",
      id = update.toolCallId,
      name = "",
    })
    self.tool_call_messages[update.toolCallId] = tool_call_message
    tool_call_message.acp_tool_call = update
  end

  if tool_call_message.acp_tool_call then
    if update.content and next(update.content) == nil then update.content = nil end
    tool_call_message.acp_tool_call = vim.tbl_deep_extend("force", tool_call_message.acp_tool_call, update)
  end

  tool_call_message.tool_use_logs = tool_call_message.tool_use_logs or {}
  tool_call_message.tool_use_log_lines = tool_call_message.tool_use_log_lines or {}

  local tool_result_message
  if update.status == "pending" or update.status == "in_progress" then
    tool_call_message.is_calling = true
    tool_call_message.state = "generating"
  elseif update.status == "completed" or update.status == "failed" then
    tool_call_message.is_calling = false
    tool_call_message.state = "generated"
    tool_result_message = History.Message:new("assistant", {
      type = "tool_result",
      tool_use_id = update.toolCallId,
      content = nil,
      is_error = update.status == "failed",
      is_user_declined = update.status == "cancelled",
    })
  end

  local messages = { tool_call_message }
  if tool_result_message then table.insert(messages, tool_result_message) end
  self:_emit_messages(messages)

  -- Follow mode: jump to file locations when agent is working
  if update.locations and #update.locations > 0 then
    vim.schedule(function()
      local sidebar = require("avante").get()
      if sidebar and sidebar.follow_mode then
        local location = update.locations[1]
        if location.path then
          local Utils = require("avante.utils")
          local abs_path = Utils.to_absolute_path and Utils.to_absolute_path(location.path)
            or vim.fn.fnamemodify(location.path, ":p")
          pcall(function()
            vim.api.nvim_win_call(sidebar.code.winid, function()
              pcall(vim.cmd, "edit " .. abs_path)
              if location.line and location.line > 0 then
                local bufnr = vim.api.nvim_get_current_buf()
                local line_count = vim.api.nvim_buf_line_count(bufnr)
                local line = math.min(location.line, line_count)
                pcall(vim.api.nvim_win_set_cursor, sidebar.code.winid, { line, 0 })
                pcall(vim.cmd, "normal! zz")
              end
            end)
          end)
        end
      end
    end)
  end

  -- Track file edits from ACP tool calls for the changed files list
  self:_track_file_edit(update)

  -- Intercept TodoWrite tool call updates to populate the plan container
  local tool_title = update.title or ""
  if tool_title:match("TodoWrite") or tool_title:match("write_todos") then
    local raw = update.rawInput or {}
    local todos_input = raw.todos
    if todos_input and type(todos_input) == "table" and #todos_input > 0 then
      self:_update_todos_from_tool(todos_input)
    end
  end
end

---@param update avante.acp.AvailableCommandsUpdate
function AcpThread:_handle_available_commands(update)
  local commands = update.availableCommands
  self.available_commands = commands

  if self.callbacks.on_available_commands then
    vim.schedule(function()
      self.callbacks.on_available_commands(commands)
    end)
  end

  Utils.register_acp_commands(commands)
end

--- Emit messages to the callback, handling chunk extraction for streaming
---@param messages avante.HistoryMessage[]
function AcpThread:_emit_messages(messages)
  -- Extract text chunks for on_chunk callback
  if self.callbacks.on_chunk then
    for _, message in ipairs(messages) do
      if message.message.role == "assistant" and type(message.message.content) == "string" then
        local chunk = message.message.content:sub(#self._prev_text_content + 1)
        if #chunk > 0 then
          self.callbacks.on_chunk(chunk)
          self._prev_text_content = message.message.content
        end
      end
    end
  end

  if self.callbacks.on_messages_add then
    self.callbacks.on_messages_add(messages)
  end
end

--- Cancel the current session prompt
function AcpThread:cancel()
  if self.connection and self.session_id then
    self.connection:cancel_session(self.session_id)
    self:_set_state("cancelled")
  end
end

--- Check if thread is currently generating
---@return boolean
function AcpThread:is_generating()
  return self.state == "generating" or self.state == "prompting"
end

--- Check if this thread has an active session
---@return boolean
function AcpThread:has_session()
  return self.session_id ~= nil and self.session_id ~= ""
end

--- Reset plan mode state
function AcpThread:reset_plan_mode()
  self.in_plan_mode = false
  self.plan_presented = false
  self.plan_entries = {}
end

--- Auto-generate title from first user message
---@param content string
function AcpThread:auto_title(content)
  if self.title and self.title ~= "" then return end
  local title = content:sub(1, 80)
  title = title:gsub("\n", " "):gsub("%s+", " ")
  if #content > 80 then title = title .. "..." end
  self.title = title
end

--- Fork this thread at the current position
---@param history_up_to_index? number If nil, use all history
---@return avante.AcpThread
function AcpThread:fork(history_up_to_index)
  local forked = AcpThread:new({
    title = (self.title or "Untitled") .. " (fork)",
    tags = vim.deepcopy(self.tags),
    parent_thread_id = self.session_id,
  })

  -- Copy history up to the specified index
  local end_idx = history_up_to_index or #self.history_messages
  for i = 1, math.min(end_idx, #self.history_messages) do
    table.insert(forked.history_messages, vim.deepcopy(self.history_messages[i]))
  end

  return forked
end

return AcpThread
