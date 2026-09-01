local Config = require("avante.config")

--- Shell-style recall of previously submitted prompts into the sidebar input
--- buffer: older prompts walking one way, back toward the draft the user was
--- typing walking the other. Recall only fills the buffer, it never submits.
---@class avante.utils.InputHistory
local M = {}

---@class avante.InputHistoryState
---@field items string[] recall candidates, newest first
---@field idx integer 0 is the user's own draft, 1..#items are recalled prompts
---@field draft string[] buffer lines stashed when recall started
---@field written string[] | nil the exact lines recall last wrote to the buffer

---@type table<integer, avante.InputHistoryState>
local states = {}

---@param text string
---@return string
local function trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end

---@param a string[]
---@param b string[] | nil
---@return boolean
local function lines_equal(a, b)
  if b == nil or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

---@param lines string[]
---@return string[]
local function normalize(lines)
  if #lines == 0 then return { "" } end
  return lines
end

---@return table
local function recall_config() return (Config.prompt_logger and Config.prompt_logger.recall) or {} end

---User prompts from the sidebar's current thread, newest first.
---@param sidebar table | nil
---@return string[]
function M.collect_thread_prompts(sidebar)
  local history = sidebar and sidebar.chat_history
  local messages = (history and history.messages) or {}
  local Helpers = require("avante.history.helpers")

  local prompts = {}
  for i = #messages, 1, -1 do
    local message = messages[i]
    if message and message.message and message.message.role == "user" and not message.just_for_display then
      -- get_text_data asserts on multi-part content, which tool calls produce
      local ok, text = pcall(Helpers.get_text_data, message)
      if ok and text and trim(text) ~= "" then table.insert(prompts, text) end
    end
  end
  return prompts
end

---Logged prompts for the whole project, newest first.
---@return string[]
function M.collect_project_prompts()
  local ok, PromptLogger = pcall(require, "avante.utils.promptLogger")
  if not ok then return {} end

  local prompts = {}
  for _, entry in ipairs(PromptLogger.list_entries()) do
    if entry.input and trim(entry.input) ~= "" then table.insert(prompts, entry.input) end
  end
  return prompts
end

---@param thread_prompts string[]
---@param project_prompts string[]
---@param source AvantePromptRecallSource | nil
---@return string[]
function M.merge_items(thread_prompts, project_prompts, source)
  source = source or "thread_then_project"

  local ordered = {}
  if source ~= "project" then vim.list_extend(ordered, thread_prompts) end
  if source ~= "thread" then vim.list_extend(ordered, project_prompts) end

  local items, seen = {}, {}
  for _, text in ipairs(ordered) do
    local key = trim(text)
    if not seen[key] then
      seen[key] = true
      table.insert(items, text)
    end
  end
  return items
end

---@param sidebar table | nil
---@return string[]
function M.build_items(sidebar)
  return M.merge_items(M.collect_thread_prompts(sidebar), M.collect_project_prompts(), recall_config().source)
end

---@param idx integer
---@param count integer
---@param delta integer 1 walks older, -1 walks newer
---@return integer
function M.clamp_index(idx, count, delta)
  local next_idx = idx + delta
  if next_idx < 0 then return 0 end
  if next_idx > count then return count end
  return next_idx
end

---Whether the cursor can no longer move in the direction being requested, in
---which case the arrow key is free to mean "recall" instead.
---@param winid integer | nil
---@param delta integer
---@return boolean
function M.at_edge(winid, delta)
  if winid == nil or not vim.api.nvim_win_is_valid(winid) then return true end
  local row = vim.api.nvim_win_get_cursor(winid)[1]
  if delta > 0 then return row <= 1 end
  return row >= vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
end

---@return boolean
function M.completion_visible()
  local ok, cmp = pcall(require, "cmp")
  if ok and cmp.visible and cmp.visible() then return true end
  return vim.fn.pumvisible() == 1
end

---@param bufnr integer | nil
function M.reset(bufnr)
  if bufnr == nil then return end
  states[bufnr] = nil
end

---Drop recall state as soon as the user edits the buffer themselves, so the
---next recall starts from what they have typed rather than mid-history.
---@param bufnr integer | nil
function M.on_text_changed(bufnr)
  local state = bufnr and states[bufnr]
  if not state then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    states[bufnr] = nil
    return
  end
  if lines_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), state.written) then return end
  states[bufnr] = nil
end

---@param sidebar table | nil
---@param delta integer 1 walks older prompts, -1 walks newer ones
function M.recall(sidebar, delta)
  local container = sidebar and sidebar.containers and sidebar.containers.input
  local bufnr = container and container.bufnr
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local state = states[bufnr]
  if not state then
    state = {
      items = M.build_items(sidebar),
      idx = 0,
      draft = normalize(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
    }
    states[bufnr] = state
  end

  if #state.items == 0 then
    if delta > 0 then vim.notify("No prompt history yet.", vim.log.levels.WARN) end
    return
  end

  local next_idx = M.clamp_index(state.idx, #state.items, delta)
  if next_idx == state.idx then return end
  state.idx = next_idx

  local lines = next_idx == 0 and state.draft or normalize(vim.split(state.items[next_idx], "\n", { plain = true }))
  state.written = lines
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local winid = container.winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_cursor(winid, { #lines, #(lines[#lines] or "") })
  end
end

---@param key string
local function feed(key) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false) end

---Build the keymap handler for one direction. Falls through to the arrow key's
---normal meaning while a completion menu is open or the cursor still has
---somewhere to go.
---@param sidebar table
---@param delta integer
---@param key string the key this handler is bound to
---@param opts { force: boolean? } | nil force recalls regardless of cursor position
---@return fun()
function M.make_handler(sidebar, delta, key, opts)
  local force = opts ~= nil and opts.force or false

  return function()
    if M.completion_visible() then
      local ok, cmp = pcall(require, "cmp")
      if ok and cmp.visible() then
        if delta > 0 then
          cmp.select_prev_item()
        else
          cmp.select_next_item()
        end
        return
      end
      return feed(key)
    end

    local container = sidebar.containers and sidebar.containers.input
    if not force and recall_config().edge_only and container and not M.at_edge(container.winid, delta) then
      return feed(key)
    end

    M.recall(sidebar, delta)
  end
end

return M
