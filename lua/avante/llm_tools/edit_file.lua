local Base = require("avante.llm_tools.base")
local Providers = require("avante.providers")
local Utils = require("avante.utils")
local Curl = require("avante.utils.curl")

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
M.func = vim.schedule_wrap(function(input, opts)
  if opts.streaming then return false, "streaming not supported" end
  if not input.path then return false, "path not provided" end
  if not input.instructions then input.instructions = "" end
  if not input.code_edit then return false, "code_edit not provided" end
  local on_complete = opts.on_complete
  if not on_complete then return false, "on_complete not provided" end
  local provider = Providers["morph"]
  if not provider then return false, "morph provider not found" end
  if not provider.is_env_set() then return false, "morph provider not set" end

  if not input.path then return false, "path not provided" end

  --- if input.path is a directory, return false
  if vim.fn.isdirectory(input.path) == 1 then return false, "path is a directory" end

  local ok, lines = pcall(Utils.read_file_from_buf_or_disk, input.path)
  if not ok then
    local f = io.open(input.path, "r")
    if f then
      local original_code = f:read("*all")
      f:close()
      lines = vim.split(original_code, "\n")
    end
  end

  if lines and #lines > 0 then
    if lines[#lines] == "" then lines = vim.list_slice(lines, 0, #lines - 1) end
  end
  local original_code = table.concat(lines or {}, "\n")

  local provider_conf = Providers.parse_config(provider)

  local body = {
    model = provider_conf.model,
    messages = {
      {
        role = "user",
        content = "<instructions>"
          .. input.instructions
          .. "</instructions>\n<code>"
          .. original_code
          .. "</code>\n<update>"
          .. input.code_edit
          .. "</update>",
      },
    },
  }

  local temp_file = vim.fn.tempname()
  local curl_body_file = temp_file .. "-request-body.json"
  local json_content = vim.json.encode(body)
  vim.fn.writefile(vim.split(json_content, "\n"), curl_body_file)

  local headers = { ["Content-Type"] = "application/json" }
  -- Add authorization header if available
  if Providers.env.require_api_key(provider_conf) then
    local api_key = provider.parse_api_key()
    headers["Authorization"] = "Bearer " .. api_key
  end
  -- Read by curl from a private file, as the command line is visible to other users
  local headers_file = Curl.write_headers_file(headers)

  -- Construct curl command with additional debugging and error handling
  local curl_cmd = {
    "curl",
    "-X",
    "POST",
    "-H",
    "@" .. headers_file,
    "-d",
    "@" .. curl_body_file,
    "--fail", -- Return error for HTTP status codes >= 400
    "--show-error", -- Show error messages
    "--verbose", -- Enable verbose output for better debugging
    "--connect-timeout",
    "30", -- Connection timeout in seconds
    "--max-time",
    "120", -- Maximum operation time
    Utils.url_join(provider_conf.endpoint, "/chat/completions"),
  }

  vim.system(
    curl_cmd,
    {
      text = true,
    },
    vim.schedule_wrap(function(result)
      -- Clean up temporary files
      vim.fn.delete(curl_body_file)
      vim.fn.delete(headers_file)

      if result.code ~= 0 then
        local error_msg = result.stderr
        if not error_msg or error_msg == "" then error_msg = result.stdout end
        if not error_msg or error_msg == "" then error_msg = "No detailed error message available" end

        -- 检查curl常见的错误码
        local curl_error_map = {
          [1] = "Unsupported protocol (curl error 1)",
          [2] = "Failed to initialize (curl error 2)",
          [3] = "URL malformed (curl error 3)",
          [4] = "Requested FTP action not supported (curl error 4)",
          [5] = "Failed to resolve proxy (curl error 5)",
          [6] = "Could not resolve host (DNS resolution failed)",
          [7] = "Failed to connect to host (connection refused)",
          [28] = "Operation timeout (connection timed out)",
          [35] = "SSL connection error (handshake failed)",
          [52] = "Empty reply from server",
          [56] = "Failure in receiving network data",
          [60] = "SSL certificate problem (certificate verification failed)",
          [77] = "Problem with reading SSL CA certificate",
        }

        local curl_cmd_str = table.concat(curl_cmd, " ")
        local error_hint = curl_error_map[result.code] or ("curl exited with code " .. result.code)
        local full_error = "curl command failed: "
          .. error_hint
          .. "\n"
          .. "Command: "
          .. curl_cmd_str
          .. "\n"
          .. "Exit code: "
          .. result.code

        if error_msg and error_msg ~= "" then full_error = full_error .. "\nError details: " .. error_msg end

        if provider_conf.endpoint and provider_conf.model then
          full_error = full_error
            .. "\nEndpoint: "
            .. provider_conf.endpoint
            .. "/chat/completions"
            .. "\nModel: "
            .. provider_conf.model
        end

        on_complete(false, full_error)
        return
      end

      local response_body = result.stdout or ""
      if response_body == "" then
        on_complete(false, "Empty response from server")
        return
      end

      local ok_, jsn = pcall(vim.json.decode, response_body)
      if not ok_ then
        on_complete(false, "Failed to parse JSON response: " .. response_body)
        return
      end

      if jsn.error then
        if type(jsn.error) == "table" and jsn.error.message then
          on_complete(false, jsn.error.message or vim.inspect(jsn.error))
        else
          on_complete(false, vim.inspect(jsn.error))
        end
        return
      end

      if not jsn.choices or not jsn.choices[1] or not jsn.choices[1].message then
        on_complete(false, "Invalid response format")
        return
      end

      local str_replace = require("avante.llm_tools.str_replace")
      local new_input = {
        path = input.path,
        old_str = original_code,
        new_str = jsn.choices[1].message.content,
      }
      str_replace.func(new_input, opts)
    end)
  )
end)

return M
