---Plans delivered over the wire rather than written to disk.
---
---claude writes its plan to `~/.claude/plans/<name>.md` as a normal file edit,
---which is why `/open-plan` finds it by scanning history for that path. Cursor
---hands it over instead: `cursor/create_plan` carries the whole plan in the
---request payload and expects an approve/reject answer. Nothing was persisted,
---so the plan vanished once the prompt was answered and `/open-plan` had
---nothing to find.
---
---This renders such a plan to markdown, saves it, and records the path on the
---thread so `/open-plan` works the same way for either agent.
---
---Cursor does also keep a file of its own, in `~/.cursor/plans`, which it
---revises as the session goes on. `find_agent_file` locates it, because what is
---saved here is only ever the plan as first proposed.

local Utils = require("avante.utils")
local Config = require("avante.config")

local M = {}

M.DEFAULT_PLAN_DIR = "~/.avante/plans"

---Where cursor-agent keeps the plan it is working from.
M.CURSOR_PLAN_DIR = "~/.cursor/plans"

---@param text string
---@return string
local function slug(text)
  local cleaned = tostring(text or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if cleaned == "" then return "plan" end
  return cleaned:sub(1, 60)
end

---@param status string|nil
---@return string
local function checkbox(status)
  if status == "completed" then return "- [x] " end
  if status == "in_progress" then return "- [~] " end
  if status == "cancelled" then return "- [-] " end
  return "- [ ] "
end

---Render a cursor/create_plan payload as markdown.
---@param params table
---@return string
function M.render_markdown(params)
  params = params or {}
  local lines = { "# " .. (params.name or "Agent Plan"), "" }

  if params.overview and params.overview ~= "" then
    table.insert(lines, params.overview)
    table.insert(lines, "")
  end

  if params.plan and params.plan ~= "" then
    table.insert(lines, "## Plan")
    table.insert(lines, "")
    for _, line in ipairs(vim.split(params.plan, "\n", { plain = true })) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  local todos = params.todos or {}
  if #todos > 0 then
    table.insert(lines, "## Todos")
    table.insert(lines, "")
    for _, todo in ipairs(todos) do
      table.insert(lines, checkbox(todo.status) .. tostring(todo.content or ""))
    end
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

---Write a plan to disk.
---@param params table cursor/create_plan payload
---@param opts? { session_id?: string, dir?: string }
---@return string|nil path, string|nil err
function M.write(params, opts)
  opts = opts or {}
  local root = vim.fn.expand(opts.dir or Config.acp_plan_dir or M.DEFAULT_PLAN_DIR)
  local directory = root .. "/" .. os.date("%Y-%m-%d")

  if vim.fn.isdirectory(directory) == 0 then
    local ok = pcall(vim.fn.mkdir, directory, "p")
    if not ok then return nil, "Could not create plan directory: " .. directory end
  end

  local name = slug(params and params.name or "plan")
  local session = opts.session_id and slug(opts.session_id):sub(1, 8) or os.date("%H%M%S")
  local path = string.format("%s/%s-%s.md", directory, session, name)

  local file, open_err = io.open(path, "w")
  if not file then return nil, tostring(open_err) end
  file:write(M.render_markdown(params))
  file:close()

  return path, nil
end

---The agent's own plan file for `session_id`, if it keeps one.
---
---`cursor/create_plan` carries no path, but cursor does write the plan out, to
---`~/.cursor/plans/<title>-<first 8 of the session id>.plan.md`, with the whole
---session id stamped into the first line. It then keeps editing that file for
---the rest of the session, which makes it the plan: what was saved here when
---the plan was first proposed is a snapshot that stops being true as soon as
---the agent revises it.
---@param session_id string|nil
---@param dir? string
---@return string|nil
function M.find_agent_file(session_id, dir)
  if type(session_id) ~= "string" or #session_id < 8 then return nil end

  local root = vim.fn.expand(dir or M.CURSOR_PLAN_DIR)
  local matches = vim.fn.glob(root .. "/*-" .. session_id:sub(1, 8) .. ".plan.md", false, true)
  if #matches == 0 then return nil end

  -- Eight characters of a name could belong to another session; the id in the
  -- file could not, so files carrying it win outright. Re-planning under a new
  -- title leaves several of those behind, and only the last one written is the
  -- plan the agent is working from.
  local best, best_time, best_stamped = nil, -1, false
  for _, path in ipairs(matches) do
    local first_line = (vim.fn.readfile(path, "", 1) or {})[1] or ""
    local stamped = first_line:find(session_id, 1, true) ~= nil
    local time = vim.fn.getftime(path)
    if (stamped and not best_stamped) or (stamped == best_stamped and time > best_time) then
      best, best_time, best_stamped = path, time, stamped
    end
  end

  return best
end

---Convert plan todos into the sidebar's TODO shape.
---@param params table
---@return avante.TODO[]
function M.to_todos(params)
  local todos = {}
  for _, todo in ipairs((params or {}).todos or {}) do
    local status = todo.status or "pending"
    -- The sidebar plan panel understands the ACP statuses only.
    if status == "cancelled" then status = "completed" end
    if status ~= "pending" and status ~= "in_progress" and status ~= "completed" then
      status = "pending"
    end
    table.insert(todos, { content = tostring(todo.content or ""), status = status, priority = "medium" })
  end
  return todos
end

---Persist a plan against the current thread and refresh the UI.
---
---Called for every `cursor/create_plan`, including the re-plans that follow the
---first one, so the recorded path always points at the plan most recently
---proposed rather than the one the session opened with.
---
---Returns the path so the caller can tell the user where it went.
---@param params table
---@return string|nil path
function M.store(params)
  local ok, Avante = pcall(require, "avante")
  local sidebar = ok and Avante.get and Avante.get() or nil

  -- Without a thread there is nowhere to record the path, and a plan saved to
  -- disk that nothing points at is a plan `/open-plan` will never find.
  if sidebar and not sidebar.chat_history and sidebar.reload_chat_history then
    pcall(function() sidebar:reload_chat_history() end)
  end

  local session_id = sidebar and sidebar.chat_history and sidebar.chat_history.acp_session_id
  local path, err = M.write(params, { session_id = session_id })
  if not path then
    Utils.warn("Could not save the agent's plan: " .. tostring(err))
    return nil
  end

  if sidebar then
    if sidebar.chat_history then
      -- Recorded on the thread so /open-plan finds it without having to infer
      -- a path from tool calls.
      sidebar.chat_history.plan_file_path = path
      local ok_path, Path = pcall(require, "avante.path")
      if ok_path and sidebar.code then
        pcall(function() Path.history.save(sidebar.code.bufnr, sidebar.chat_history) end)
      end
    end

    local todos = M.to_todos(params)
    if #todos > 0 and sidebar.update_plan then pcall(function() sidebar:update_plan(todos) end) end
  end

  return path
end

M._slug = slug

return M
