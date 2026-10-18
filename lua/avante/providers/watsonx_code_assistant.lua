-- Documentation for setting up IBM Watsonx Code Assistant
--- Generating an access token: https://www.ibm.com/products/watsonx-code-assistant or https://github.ibm.com/code-assistant/wca-api
local P = require("avante.providers")
local Utils = require("avante.utils")
local curl = require("avante.utils.curl")
local Config = require("avante.config")
local Llm = require("avante.llm")
local ts_utils = pcall(require, "nvim-treesitter.ts_utils") and require("nvim-treesitter.ts_utils")
  or {
    get_node_at_cursor = function() return nil end,
  }
local OpenAI = require("avante.providers.openai")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "WCA_API_KEY" -- The name of the environment variable that contains the API key
M.role_map = {
  user = "USER",
  assistant = "ASSISTANT",
  system = "SYSTEM",
}
M.last_iam_token_time = nil
M.iam_bearer_token = ""

function M:is_disable_stream() return true end

---@type fun(self: AvanteProviderFunctor, opts: AvantePromptOptions): table
function M:parse_messages(opts)
  if opts == nil then return {} end
  local messages
  if opts.system_prompt == "WCA_COMMAND" then
    messages = {}
  else
    messages = {
      { content = opts.system_prompt, role = "SYSTEM" },
    }
  end
  vim
    .iter(opts.messages)
    :each(function(msg) table.insert(messages, { content = msg.content, role = M.role_map[msg.role] }) end)
  return messages
end

--- This function will be used to parse incoming SSE stream
--- It takes in the data stream as the first argument, followed by SSE event state, and opts
--- retrieved from given buffer.
--- This opts include:
--- - on_chunk: (fun(chunk: string): any) this is invoked on parsing correct delta chunk
--- - on_complete: (fun(err: string|nil): any) this is invoked on either complete call or error chunk
local function parse_response_wo_stream(self, data, _, opts)
  if Utils.debug then Utils.debug("WCA parse_response_without_stream called with opts: " .. vim.inspect(opts)) end

  local json = vim.json.decode(data)
  if Utils.debug then Utils.debug("WCA Response: " .. vim.inspect(json)) end
  if json.error ~= nil and json.error ~= vim.NIL then
    Utils.warn("WCA Error " .. tostring(json.error.code) .. ": " .. tostring(json.error.message))
  end
  if json.response and json.response.message and json.response.message.content then
    local content = json.response.message.content

    if Utils.debug then Utils.debug("WCA Original Content: " .. tostring(content)) end

    -- Clean up the content by removing XML-like tags that are not part of the actual response
    -- These tags appear to be internal formatting from watsonx that should not be shown to users
    -- Use more careful patterns to avoid removing too much content
    content = content:gsub("<file>\n?", "")
    content = content:gsub("\n?</file>", "")
    content = content:gsub("\n?<memory>.-</memory>\n?", "")
    content = content:gsub("\n?<write_todos>.-</write_todos>\n?", "")
    content = content:gsub("\n?<attempt_completion>.-</attempt_completion>\n?", "")

    -- Trim excessive whitespace but preserve structure
    content = content:gsub("^\n+", ""):gsub("\n+$", "")

    if Utils.debug then Utils.debug("WCA Cleaned Content: " .. tostring(content)) end

    -- Ensure we still have content after cleaning
    if content and content ~= "" then
      if opts.on_chunk then opts.on_chunk(content) end
      -- Add the text message for UI display (similar to OpenAI provider)
      OpenAI:add_text_message({}, content, "generated", opts)
    else
      Utils.warn("WCA: Content became empty after cleaning")
      if opts.on_chunk then
        opts.on_chunk(json.response.message.content) -- Fallback to original content
      end
      -- Add the original content as fallback
      OpenAI:add_text_message({}, json.response.message.content, "generated", opts)
    end
    vim.schedule(function()
      if opts.on_stop then opts.on_stop({ reason = "complete" }) end
    end)
  elseif json.error and json.error ~= vim.NIL then
    vim.schedule(function()
      if opts.on_stop then
        opts.on_stop({
          reason = "error",
          error = "WCA Error " .. tostring(json.error.code) .. ": " .. tostring(json.error.message),
        })
      end
    end)
  else
    -- Handle case where there's no response content and no explicit error
    if Utils.debug then Utils.debug("WCA: No content found in response, treating as empty response") end
    vim.schedule(function()
      if opts.on_stop then opts.on_stop({ reason = "complete" }) end
    end)
  end
end

M.parse_response_without_stream = parse_response_wo_stream

-- Needs to be language specific for each function and methods.
local get_function_name_under_cursor = function()
  local current_node = ts_utils.get_node_at_cursor()
  if not current_node then return "" end
  local expr = current_node

  while expr do
    if expr:type() == "function_definition" or expr:type() == "method_declaration" then break end
    expr = expr:parent()
  end

  if not expr then return "" end

  local result = (ts_utils.get_node_text(expr:child(1)))[1]
  return result
end

--- It takes in the provider options as the first argument, followed by code_opts retrieved from given buffer.
---@type fun(command_name: string): nil
M.method_command = function(command_name)
  if
    command_name ~= "document"
    and command_name ~= "unit-test"
    and command_name ~= "explain"
    and command_name:find("translate", 1, true) == 0
  then
    Utils.warn("Invalid command name" .. command_name)
  end

  local current_buffer = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buffer)

  -- Use file name for now. For proper extraction of method names, a lang specific TreeSitter querry is need
  -- local method_name = get_function_name_under_cursor()
  -- use whole file if we cannot get the method
  local method_name = ""
  if method_name == "" then
    local path_splits = vim.split(file_path, "/")
    method_name = path_splits[#path_splits]
  end

  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end
  sidebar.file_selector:add_current_buffer()

  local response_content = ""
  local provider = P[Config.provider]
  local content = "/" .. command_name .. " @" .. method_name
  Llm.curl({
    provider = provider,
    prompt_opts = {
      system_prompt = "WCA_COMMAND",
      messages = {
        { content = content, role = "user" },
      },
      selected_files = sidebar.file_selector:get_selected_files_contents(),
    },
    handler_opts = {
      on_start = function(_) end,
      on_chunk = function(chunk)
        if not chunk then return end
        response_content = response_content .. chunk
      end,
      on_stop = function(stop_opts)
        if stop_opts.error ~= nil then
          Utils.error(string.format("WCA Command " .. command_name .. " failed: %s", vim.inspect(stop_opts.error)))
          return
        end
        if stop_opts.reason == "complete" then
          if not sidebar:is_open() then sidebar:open({}) end
          sidebar:update_content(response_content, { focus = true })
        end
      end,
    },
  })
end

local function get_iam_bearer_token(provider)
  if M.last_iam_token_time ~= nil and os.time() - M.last_iam_token_time <= 3550 then return M.iam_bearer_token end

  local api_key = provider.parse_api_key()
  if api_key == nil then
    -- if no api key is available, make a request with a empty api key.
    api_key = ""
  end

  local url = "https://iam.cloud.ibm.com/identity/token"
  local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  local body = "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=" .. api_key

  local response = curl.post(url, { headers = header, body = body })
  if response.status == 200 then
    -- select first key value pair
    local access_token_field = vim.split(response.body, ",")[1]
    -- get value
    local token = vim.split(access_token_field, ":")[2]
    -- remove quotes
    M.iam_bearer_token = (token:gsub("^%p(.*)%p$", "%1"))
    M.last_iam_token_time = os.time()
  else
    Utils.error(
      "Failed to retrieve IAM token: " .. response.status .. ": " .. vim.inspect(response.body),
      { title = "Avante WCA" }
    )
    M.iam_bearer_token = ""
  end
  return M.iam_bearer_token
end

local random = math.random
math.randomseed(os.time())
local function uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
    return string.format("%x", v)
  end)
end

--- This function below will be used to parse in cURL arguments.
--- It takes in the provider options as the first argument, followed by code_opts retrieved from given buffer.
--- This code_opts include:
--- - question: Input from the users
--- - code_lang: the language of given code buffer
--- - code_content: content of code buffer
--- - selected_code_content: (optional) If given code content is selected in visual mode as context.
---@type fun(opts: AvanteProvider, code_opts: AvantePromptOptions): AvanteCurlOutput
---@param provider AvanteProviderFunctor
---@param code_opts AvantePromptOptions
---@return table
M.parse_curl_args = function(provider, code_opts)
  local base, _ = P.parse_config(provider)
  local headers = {
    ["Content-Type"] = "multipart/form-data",
    ["Authorization"] = "Bearer " .. get_iam_bearer_token(provider),
    ["Request-ID"] = uuid(),
  }

  -- Create the message_payload structure as required by WCA API
  local message_payload = {
    message_payload = {
      chat_session_id = uuid(), -- Required for granite-3-8b-instruct model
      messages = M:parse_messages(code_opts),
    },
  }

  -- Base64 encode the message payload as required by watsonx API
  local json_content = vim.json.encode(message_payload)
  local encoded_json_content = vim.base64.encode(json_content)

  -- Return form data structure - the message field contains the base64-encoded JSON
  local body = {
    message = encoded_json_content,
  }

  return {
    url = base.endpoint,
    timeout = base.timeout,
    insecure = false,
    headers = headers,
    body = body,
  }
end

--- The following function SHOULD only be used when providers doesn't follow SSE spec [ADVANCED]
--- this is mutually exclusive with parse_response_data

return M
