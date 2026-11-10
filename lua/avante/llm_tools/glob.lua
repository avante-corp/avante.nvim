local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "glob"

M.description = 'Fast file pattern matching using glob patterns like "**/*.js", in current project scope'

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "pattern",
      description = "Glob pattern",
      type = "string",
    },
    {
      name = "path",
      description = "Relative path to the project directory, as cwd",
      type = "string",
    },
  },
  usage = {
    pattern = "Glob pattern",
    path = "Relative path to the project directory, as cwd",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "matches",
    description = "List of matched files",
    type = "string",
  },
  {
    name = "err",
    description = "Error message",
    type = "string",
    optional = true,
  },
}

-- Visit only glob syntax, leaving escaped characters and character classes intact.
local function syntax_positions(pattern)
  local index = 0
  return function()
    while index < #pattern do
      index = index + 1
      local char = pattern:sub(index, index)
      if char == "\\" then
        index = index + 1
      elseif char == "[" then
        local closing = pattern:find("]", index + 1, true)
        index = closing or #pattern
      else
        return index, char
      end
    end
  end
end

local function expand_braces(pattern)
  local opening, branch_start
  local depth = 0
  local branches = {}
  for index, char in syntax_positions(pattern) do
    if char == "{" then
      depth = depth + 1
      if depth == 1 then
        opening, branch_start = index, index + 1
      end
    elseif char == "," and depth == 1 then
      table.insert(branches, pattern:sub(branch_start, index - 1))
      branch_start = index + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then
        table.insert(branches, pattern:sub(branch_start, index - 1))
        local expanded = {}
        for _, branch in ipairs(branches) do
          for _, alternative in ipairs(expand_braces(pattern:sub(1, opening - 1) .. branch .. pattern:sub(index + 1))) do
            if #expanded >= 1024 then error("Too many glob alternatives") end
            table.insert(expanded, alternative)
          end
        end
        return expanded
      end
    end
  end
  return { pattern }
end

local function compile_patterns(pattern)
  -- Validate before expansion, including malformed braces and globstars.
  vim.glob.to_lpeg(pattern)
  local states = {}
  for _, alternative in ipairs(expand_braces(pattern)) do
    alternative = alternative:gsub("^%./", "")
    local parts = {}
    local start = 1
    for index, char in syntax_positions(alternative) do
      if char == "/" then
        table.insert(parts, alternative:sub(start, index - 1))
        start = index + 1
      end
    end
    local directory_only = start > #alternative
    if not directory_only then table.insert(parts, alternative:sub(start)) end
    local segments = {}
    for _, part in ipairs(parts) do
      table.insert(segments, {
        recursive = part == "**",
        hidden = part:sub(1, 1) == "." or part:sub(1, 2) == "\\.",
        matcher = part ~= "**" and vim.glob.to_lpeg(part) or nil,
      })
    end
    table.insert(states, { segments = segments, index = 1, directory_only = directory_only })
  end
  return states
end

local function advance_states(states, name)
  local next_states = {}
  local matches = {}
  local hidden = name:sub(1, 1) == "."
  local seen = {}
  local function advance(state, index)
    if not seen[state.segments] then seen[state.segments] = {} end
    local key = index .. (state.directory_only and "/" or "")
    if not seen[state.segments][key] then
      seen[state.segments][key] = true
      table.insert(next_states, { segments = state.segments, index = index, directory_only = state.directory_only })
    end
  end
  for _, state in ipairs(states) do
    local index = state.index
    local segment = state.segments[index]
    while segment and segment.recursive do
      -- Globstars may consume this visible component, or skip to the next segment.
      if not hidden then
        advance(state, index)
        if index == #state.segments then matches[state.directory_only and "directory" or "any"] = true end
      end
      index = index + 1
      segment = state.segments[index]
    end
    if segment and (not hidden or segment.hidden) and vim.lpeg.match(segment.matcher, name) then
      if index == #state.segments then
        matches[state.directory_only and "directory" or "any"] = true
      else
        advance(state, index + 1)
      end
    end
  end
  return next_states, matches
end

---@type AvanteLLMToolFunc<{ path: string, pattern: string }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  if type(input.pattern) ~= "string" or input.pattern == "" then return "", "Glob pattern must not be empty" end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if vim.fn.isdirectory(abs_path) == 0 then return "", "No such directory: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  if on_log then on_log("pattern: " .. input.pattern) end

  -- Expand braces before splitting components, including alternatives containing slashes.
  local ok, states = pcall(compile_patterns, input.pattern)
  if not ok then return "", "Glob search failed: " .. tostring(states) end
  local pending = { { path = abs_path, states = states } }
  local files = {}
  local found = {}
  local size = 0
  local finished = false
  local result, error
  local timer

  local function finish(err, is_truncated)
    if finished then return end
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if err then
      result, error = "", err
    else
      table.sort(files)
      result = vim.json.encode({ matches = files, is_truncated = is_truncated or false })
    end
    if on_complete then on_complete(result, error) end
  end

  local scan_directory
  scan_directory = function()
    if finished then return end
    local directory = table.remove(pending)
    if not directory then return finish() end

    local function on_scan(err, scan)
      if finished then return end
      if err then return finish("Glob search failed: " .. err) end

      local function consume_batch()
        if finished then return end
        -- Yield between batches, including within a single large directory.
        for _ = 1, 128 do
          local success, name, kind = pcall(vim.uv.fs_scandir_next, scan)
          if not success then return finish("Glob search failed: " .. tostring(name)) end
          if not name then return scan_directory() end
          local next_states, matches = advance_states(directory.states, name)
          local path = vim.fs.joinpath(directory.path, name)
          local matched_paths = {}
          if matches.any then table.insert(matched_paths, path) end
          if kind == "directory" and matches.directory then table.insert(matched_paths, path .. "/") end
          for _, matched_path in ipairs(matched_paths) do
            if not found[matched_path] then
              size = size + #matched_path
              if size > 1024 * 10 then return finish(nil, true) end
              found[matched_path] = true
              table.insert(files, matched_path)
            end
          end
          -- Only visit matching prefixes, and never follow directory symlinks.
          if kind == "directory" and #next_states > 0 then
            table.insert(pending, { path = path, states = next_states })
          end
        end
        vim.schedule(consume_batch)
      end
      consume_batch()
    end

    -- Directory enumeration runs in libuv's thread pool, not on the editor thread.
    local success, request, err = pcall(vim.uv.fs_scandir, directory.path, vim.schedule_wrap(on_scan))
    if not success then return finish("Glob search failed: " .. tostring(request)) end
    if not request then return finish("Glob search failed: " .. tostring(err)) end
  end

  timer = vim.defer_fn(
    function() finish("Glob search timed out after 10 seconds; use a narrower path or pattern") end,
    10000
  )
  vim.schedule(scan_directory)
  if not on_complete then
    vim.wait(11000, function() return finished end)
    if not finished then finish("Glob search timed out after 10 seconds; use a narrower path or pattern") end
    return result, error
  end
end

return M
