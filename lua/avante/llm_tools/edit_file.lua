local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")
local Providers = require("avante.providers")
local Utils = require("avante.utils")

---@class avante.tools.edit_file: AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "edit_file"

M.enabled = function()
  return require("avante.config").mode == "agentic" and require("avante.config").behaviour.enable_fastapply
end

M.description =
  [[Propose edits to a file for the apply model. Describe all edits to that file in one call. Include enough unchanged surrounding code to locate each change, and represent omitted unchanged regions with // ... existing code ... so they are preserved. For deletions, include the code before and after the removed section. Make the intended changes and their locations unambiguous.]]

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "The target file path to modify.",
      type = "string",
    },
    {
      name = "instructions",
      type = "string",
      description = "Describe the intended edits clearly enough for the apply model to resolve any ambiguity.",
    },
    {
      name = "code_edit",
      type = "string",
      description = "The edited code with sufficient unchanged context to locate each change. Use // ... existing code ... for omitted unchanged regions.",
    },
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the file was edited successfully",
    type = "boolean",
  },
  {
    name = "error",
    description = "Error message if the file could not be edited",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, instructions: string, code_edit: string }>
function M.func(input, opts)
  if opts.streaming then return false, "streaming not supported" end
  if not input.path then return false, "path not provided" end
  if not input.code_edit then return false, "code_edit not provided" end
  local on_complete = opts.on_complete
  if not on_complete then return false, "on_complete not provided" end
  local provider = Providers["morph"]
  if not provider then return false, "morph provider not found" end
  if not provider.is_env_set() then return false, "morph provider not set" end
  local path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(path) then return false, "No permission to access path: " .. path end
  if vim.fn.isdirectory(path) == 1 then return false, "path is a directory" end

  local ok, lines, read_error, errname = pcall(Utils.read_file_from_buf_or_disk, path)
  if not ok or (read_error and errname ~= "ENOENT") then
    on_complete(false, tostring(ok and read_error or lines))
    return
  end
  if lines and lines[#lines] == "" then lines = vim.list_slice(lines, 1, #lines - 1) end
  local original_code = table.concat(lines or {}, "\n")
  ---@type string[]
  local chunks = {}

  require("avante.llm").request({
    provider = provider,
    prompt_opts = {
      system_prompt = "Apply the requested edits. Return only the complete updated code without Markdown fences.",
      messages = {
        {
          role = "user",
          content = "<instructions>"
            .. (input.instructions or "")
            .. "</instructions>\n<code>"
            .. original_code
            .. "</code>\n<update>"
            .. input.code_edit
            .. "</update>",
        },
      },
    },
    handler_opts = {
      on_start = function() end,
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end,
      on_stop = function(result)
        if result.reason ~= "complete" then
          local err = result.error
          if type(err) == "table" then err = vim.inspect(err) end
          on_complete(false, err or ("Fast Apply stopped: " .. tostring(result.reason)))
          return
        end
        local new_code = Utils.trim_think_content(table.concat(chunks))
        if new_code == "" then
          on_complete(false, "Empty response from Fast Apply")
          return
        end
        local applied, err = require("avante.llm_tools.str_replace").func({
          path = path,
          old_str = original_code,
          new_str = new_code,
        }, opts)
        if applied ~= nil or err ~= nil then on_complete(applied, err) end
      end,
    },
  })
end

return M
