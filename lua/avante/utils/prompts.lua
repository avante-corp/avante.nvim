---@mod avante-prompts Custom prompts
---@brief [[
---
--- Avante uses different prompts for planning, editing, suggesting, and
--- agentic flows. You can set a global prompt:
--->lua
---   vim.g.avante = {
---     system_prompt = "MY CUSTOM SYSTEM PROMPT",
---   }
---<
---
---By default Avante reads `avante.md` from the project root as
---project-specific instructions. Change the filename with:
--->lua
---   vim.g.avante = {
---     instructions_file = "avante.md",
---   }
---<
---
---Project prompt rules
---
---Avante can load `*.avanterules` files from a project. Configure rule
--- directories:
--->lua
---   vim.g.avante = {
---     rules = {
---       project_dir = ".avante/rules",
---       global_dir = "~/.config/avante/rules",
---     },
---   })
---<
---
--- Rule loading priority:
---
--- 1. `rules.project_dir`
--- 2. `rules.global_dir`
--- 3. Project root
---
--- Rules are jinja templates that can include other files.
---
--- Example files:
---
--- - `typescript.planning.avanterules`
--- - `snippets.editing.avanterules`
--- - `suggesting.avanterules`
---
--- `*.avanterules` files are Jinja templates rendered with minijinja.
---
--- avante can override the prompt directory:
--->lua
---   vim.g.avante = {
---     override_prompt_dir = vim.fn.expand("~/.config/nvim/avante_prompts"),
---   }
---<
---
---@brief ]]

local Utils = require("avante.utils")
local M = {}

---@param provider_conf AvanteDefaultBaseProvider
---@param opts AvantePromptOptions
---@return string
function M.get_ReAct_system_prompt(provider_conf, opts)
  local system_prompt = opts.system_prompt
  if provider_conf.disable_tools or not opts.tools or #opts.tools == 0 then return system_prompt end

  local tools_prompts = [[
====

TOOL USE

The host executes the available tools and returns their results. Some operations may require user approval. Use one tool per message and use its result to inform the next step.

Wrap each tool request in <tool_use></tool_use> with valid JSON containing "name" followed by "input":

<tool_use>{"name": "tool_name", "input": {"parameter_name": "value"}}</tool_use>

Replace the placeholders with an available tool name and input conforming to its JSON Schema below. If the input contains a "path" field, output that field first. Do not use native function-calling syntax in this format.

# Available Tools

]]
  for _, tool in ipairs(opts.tools) do
    local properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
    local schema = { type = "object", properties = properties, required = required, additionalProperties = false }
    local description = tool.get_description and tool.get_description() or (tool.description or "")
    tools_prompts = tools_prompts
      .. string.format(
        "## %s\nDescription: %s\nInput JSON Schema:\n%s\n\n",
        tool.name,
        description,
        vim.json.encode(schema)
      )
  end
  return system_prompt .. tools_prompts
end

--- Returns the content of the first file found in the list:
--- - AGENTS.md
--- - CLAUDE.md
--- - OPENCODE.md
--- - .cursorrules
--- - .windsurfrules
--- - .github/copilot-instructions.md
---@return string | nil
function M.get_agents_rules_prompt()
  local project_root = tostring(Utils.get_project_root())
  local file_names = {
    "AGENTS.md",
    "CLAUDE.md",
    "OPENCODE.md",
    ".cursorrules",
    ".windsurfrules",
    vim.fs.joinpath(".github", "copilot-instructions.md"),
  }
  for _, file_name in ipairs(file_names) do
    local file_path = vim.fs.joinpath(project_root, file_name)
    if vim.fn.filereadable(file_path) == 1 then
      Utils.debug("Reading prompt from " .. file_path)
      local content = vim.fn.readfile(file_path)
      return table.concat(content, "\n")
    end
  end
  return nil
end

---Load rules in *.cursor/rules*
---@param selected_files AvanteSelectedFile[]
---@return string | nil
function M.get_cursor_rules_prompt(selected_files)
  local project_root = tostring(Utils.get_project_root())
  local accumulated_content = ""

  ---@type string[]
  local mdc_files = vim.fn.globpath(vim.fs.joinpath(project_root, ".cursor/rules"), "*.mdc", false, true)
  for _, file_path in ipairs(mdc_files) do
    ---@type string[]
    local content = vim.fn.readfile(file_path)
    if content[1] ~= "---" or content[5] ~= "---" then goto continue end
    local header, body = table.concat(content, "\n", 2, 4), table.concat(content, "\n", 6)
    local _description, globs, alwaysApply = header:match("description:%s*(.*)\nglobs:%s*(.*)\nalwaysApply:%s*(.*)")

    if not globs then goto continue end
    globs = vim.trim(globs)
    -- TODO: When empty string, this means the agent should request for this rule ad-hoc.
    if globs == "" then goto continue end
    local globs_array = vim.split(globs, ",%s*")
    local path_regexes = {} ---@type string[]
    for _, glob in ipairs(globs_array) do
      path_regexes[#path_regexes + 1] = glob:gsub("%*%*", ".+"):gsub("%*", "[^/]*")
      path_regexes[#path_regexes + 1] = glob:gsub("%*%*/", ""):gsub("%*", "[^/]*")
    end
    local always_apply = alwaysApply == "true"

    if always_apply then
      accumulated_content = accumulated_content .. "\n" .. body
    else
      local matched = false
      for _, selected_file in ipairs(selected_files) do
        for _, path_regex in ipairs(path_regexes) do
          if string.match(selected_file.path, path_regex) then
            accumulated_content = accumulated_content .. "\n" .. body
            matched = true
            break
          end
        end
        if matched then break end
      end
    end
    ::continue::
  end
  return accumulated_content ~= "" and accumulated_content or nil
end

return M
