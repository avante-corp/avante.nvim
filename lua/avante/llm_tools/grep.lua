local Path = require("plenary.path")
local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")

---@class avante.tools.grep: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "grep"

M.description = "Search for a keyword in a directory using grep in current project scope"

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "Relative path to the project directory",
      type = "string",
    },
    {
      name = "query",
      description = "Query to search for",
      type = "string",
    },
    {
      name = "case_sensitive",
      description = "Whether to search case sensitively",
      type = "boolean",
      default = false,
      optional = true,
    },
    {
      name = "include_pattern",
      description = "Glob pattern to include files",
      type = "string",
      optional = true,
    },
    {
      name = "exclude_pattern",
      description = "Glob pattern to exclude files",
      type = "string",
      optional = true,
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "files",
    description = "List of files that match the keyword",
    type = "string",
  },
  {
    name = "error",
    description = "Error message if the directory was not searched successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, query: string, case_sensitive?: boolean, include_pattern?: string, exclude_pattern?: string }>
function M.func(input, opts)
  local on_log = opts.on_log

  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return "", "No such file or directory: " .. abs_path end

  ---check if any search cmd is available
  local search_cmd = vim.fn.exepath("rg")
  if search_cmd == "" then search_cmd = vim.fn.exepath("ag") end
  if search_cmd == "" then search_cmd = vim.fn.exepath("ack") end
  if search_cmd == "" then search_cmd = vim.fn.exepath("grep") end
  if search_cmd == "" then return "", "No search command found" end

  ---execute the search command
  local cmd = {}
  if search_cmd:find("rg") then
    cmd = { search_cmd, "--files-with-matches", "--hidden" }
    if input.case_sensitive then
      table.insert(cmd, "--case-sensitive")
    else
      table.insert(cmd, "--ignore-case")
    end
    if input.include_pattern then
      table.insert(cmd, "--glob")
      table.insert(cmd, input.include_pattern)
    end
    if input.exclude_pattern then
      table.insert(cmd, "--glob")
      table.insert(cmd, "!" .. input.exclude_pattern)
    end
    table.insert(cmd, input.query)
    table.insert(cmd, abs_path)
  elseif search_cmd:find("ag") then
    cmd = { search_cmd, "--nocolor", "--nogroup", "--hidden" }
    if input.case_sensitive then table.insert(cmd, "--case-sensitive") end
    if input.include_pattern then
      table.insert(cmd, "--ignore")
      table.insert(cmd, "!" .. input.include_pattern)
    end
    if input.exclude_pattern then
      table.insert(cmd, "--ignore")
      table.insert(cmd, input.exclude_pattern)
    end
    table.insert(cmd, input.query)
    table.insert(cmd, abs_path)
  elseif search_cmd:find("ack") then
    cmd = { search_cmd, "--nocolor", "--nogroup", "--hidden" }
    if input.case_sensitive then table.insert(cmd, "--smart-case") end
    if input.exclude_pattern then
      table.insert(cmd, "--ignore-dir")
      table.insert(cmd, input.exclude_pattern)
    end
    table.insert(cmd, input.query)
    table.insert(cmd, abs_path)
  elseif search_cmd:find("grep") then
    local files =
      vim.system({ "git", "-C", abs_path, "ls-files", "-co", "--exclude-standard" }, { text = true }):wait().stdout
    cmd = { "grep", "-rH" }
    if not input.case_sensitive then table.insert(cmd, "-i") end
    if input.include_pattern then
      table.insert(cmd, "--include")
      table.insert(cmd, input.include_pattern)
    end
    if input.exclude_pattern then
      table.insert(cmd, "--exclude")
      table.insert(cmd, input.exclude_pattern)
    end
    table.insert(cmd, input.query)
    if files ~= "" then
      for _, path in ipairs(vim.split(files, "\n")) do
        if not path:match("^%s*$") then table.insert(cmd, vim.fs.joinpath(abs_path, path)) end
      end
    else
      table.insert(cmd, abs_path)
    end
  end

  Utils.debug("cmd", table.concat(cmd, " "))
  if on_log then on_log("Running command: " .. table.concat(cmd, " ")) end
  local result = vim.system(cmd, { text = true }):wait().stdout or ""
  local filepaths = vim.split(result, "\n")

  return vim.json.encode(filepaths), nil
end

return M
