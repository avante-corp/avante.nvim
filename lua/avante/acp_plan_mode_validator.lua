---@class avante.ACPPlanModeValidator
local M = {}

-- Tools that should be restricted in plan mode (write operations)
M.RESTRICTED_TOOLS_IN_PLAN_MODE = {
  "edit_file",
  "write_to_file",
  "write_text_file",
  "str_replace",
  "fs/write_text_file",
  "mcp__acp__Write",
  "mcp__acp__Edit",
  "Write",
  "Edit",
  "NotebookEdit",
  "Bash", -- Some bash commands can modify files
}

-- Tools that are always allowed in plan mode (read-only operations)
M.ALLOWED_TOOLS_IN_PLAN_MODE = {
  "read_file",
  "read_text_file",
  "fs/read_text_file",
  "mcp__acp__Read",
  "Read",
  "Glob",
  "Grep",
  "grep",
  "find",
  "ls",
  "cat",
  "Task", -- Task agent for exploration
  "TodoWrite", -- Todo management is allowed in plan mode
  "TodoRead",
  "AskUserQuestion",
  "ask_user_question", -- avante's own, for agents that cannot ask natively
  "EnterPlanMode",
  "ExitPlanMode",
  "WebFetch",
  "WebSearch",
}

---Check if a tool is allowed in plan mode
---@param tool_name string The name of the tool or method
---@return boolean allowed True if the tool is allowed in plan mode
---@return string|nil reason If not allowed, the reason why
function M.is_tool_allowed_in_plan_mode(tool_name)
  if not tool_name then
    return true, nil -- No tool name means it's probably a message, allow it
  end
  
  -- Check if explicitly allowed
  for _, allowed in ipairs(M.ALLOWED_TOOLS_IN_PLAN_MODE) do
    if tool_name:lower():match(allowed:lower()) then
      return true, nil
    end
  end
  
  -- Check if restricted
  for _, restricted in ipairs(M.RESTRICTED_TOOLS_IN_PLAN_MODE) do
    if tool_name:lower():match(restricted:lower()) then
      return false, "Tool '" .. tool_name .. "' is not allowed in plan mode (write operation)"
    end
  end
  
  -- Unknown tools are allowed by default (to avoid breaking things)
  -- but we log a warning for debugging
  require("avante.utils").debug("Unknown tool in plan mode check: " .. tool_name)
  return true, nil
end

---Check if we're currently in plan mode
---@param sidebar table|nil Optional sidebar instance
---@return boolean in_plan_mode True if currently in plan mode
---@return string|nil mode_name The name of the current mode if in plan mode
function M.is_in_plan_mode(sidebar)
  sidebar = sidebar or require("avante").get()
  
  if not sidebar or not sidebar.current_mode_id or not sidebar.acp_client then
    return false, nil
  end
  
  local mode = sidebar.acp_client:mode_by_id(sidebar.current_mode_id)
  if mode and (mode.name:lower():match("plan") or mode.id:lower():match("plan")) then
    return true, mode.name
  end
  
  return false, nil
end

---Validate a permission request in the context of plan mode
---@param permission_request table The permission request from ACP
---@param sidebar table|nil Optional sidebar instance
---@return boolean should_auto_reject True if the request should be auto-rejected
---@return string|nil rejection_reason If auto-rejecting, the reason
function M.validate_permission_in_plan_mode(permission_request, sidebar)
  local in_plan_mode, mode_name = M.is_in_plan_mode(sidebar)
  
  if not in_plan_mode then
    return false, nil -- Not in plan mode, no validation needed
  end
  
  -- Extract tool name from permission request
  local tool_name = permission_request.tool 
    or permission_request.method 
    or permission_request.name
    or (permission_request.params and permission_request.params.method)
  
  if not tool_name then
    -- If we can't determine the tool, allow it but log
    require("avante.utils").debug("Could not determine tool name from permission request in plan mode")
    return false, nil
  end
  
  local allowed, reason = M.is_tool_allowed_in_plan_mode(tool_name)
  
  if not allowed then
    return true, reason or ("Tool not allowed in " .. (mode_name or "plan mode"))
  end
  
  return false, nil
end

return M
