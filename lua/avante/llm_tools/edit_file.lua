local Base = require("avante.llm_tools.base")
local Helpers = require("avante.llm_tools.helpers")
local Providers = require("avante.providers")
local Utils = require("avante.utils")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "edit_file"

M.enabled = function()
  return require("avante.config").mode == "agentic" and require("avante.config").behaviour.enable_fastapply
end

M.description =
  "Use this tool to propose an edit to an existing file.\n\nThis will be read by a less intelligent model, which will quickly apply the edit. You should make it clear what the edit is, while also minimizing the unchanged code you write.\nWhen writing the edit, you should specify each edit in sequence, with the special comment // ... existing code ... to represent unchanged code in between edited lines.\n\nFor example:\n\n// ... existing code ...\nFIRST_EDIT\n// ... existing code ...\nSECOND_EDIT\n// ... existing code ...\nTHIRD_EDIT\n// ... existing code ...\n\nYou should still bias towards repeating as few lines of the original file as possible to convey the change.\nBut, each edit should contain sufficient context of unchanged lines around the code you're editing to resolve ambiguity.\nDO NOT omit spans of pre-existing code (or comments) without using the // ... existing code ... comment to indicate its absence. If you omit the existing code comment, the model may inadvertently delete these lines.\nIf you plan on deleting a section, you must provide context before and after to delete it. If the initial code is ```code \\n Block 1 \\n Block 2 \\n Block 3 \\n code```, and you want to remove Block 2, you would output ```// ... existing code ... \\n Block 1 \\n  Block 3 \\n // ... existing code ...```.\nMake sure it is clear what the edit should be, and where it should be applied.\nALWAYS make all edits to a file in a single edit_file instead of multiple edit_file calls to the same file. The apply model can handle many distinct edits at once."

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
      description = "A single sentence instruction describing what you are going to do for the sketched edit. This is used to assist the less intelligent model in applying the edit. Use the first person to describe what you are going to do. Use it to disambiguate uncertainty in the edit.",
    },
    {
      name = "code_edit",
      type = "string",
      description = "Specify ONLY the precise lines of code that you wish to edit. NEVER specify or write out unchanged code. Instead, represent all unchanged code using the comment of the language you're editing in - example: // ... existing code ...",
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
