---@mod avante-providers-claude Anthropic provider
---
---@brief [[
--- Avante supports both the 'api' and 'max' authentications
---
--- Set the Claude provider `auth_type` to `"max"`:
---@brief ]]
---@see AvanteAnthropicProvider
---@usage [[
---   vim.g.avante = {
---     providers = {
---       claude = {
---         auth_type = "max",
---       },
---     },
---   })
---@usage ]]
---
---After reopening Neovim, complete the browser authentication flow. If needed,
---run:
--->
---   :AvanteSwitchProvider
---<

local Utils = require("avante.utils")
local Clipboard = require("avante.clipboard")
local P = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local JsonParser = require("avante.libs.jsonparser")
local Config = require("avante.config")
local Path = require("plenary.path")
local curl = require("plenary.curl")

---@class AvanteAnthropicProvider : AvanteDefaultBaseProvider
---@field auth_type "api" | "max"

---@class ClaudeAuthToken
---@field access_token string
---@field refresh_token string
---@field expires_at integer

---@class AvanteClaudeProviderFunctor
local M = {}

local claude_path = vim.fn.stdpath("data") .. "/avante/claude-auth.json"
local lockfile_path = vim.fn.stdpath("data") .. "/avante/claude-timer.lock"
local auth_endpoint = "https://claude.ai/oauth/authorize"
local token_endpoint = "https://platform.claude.com/v1/oauth/token"
local client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local claude_code_spoof_prompt = "You are Claude Code, Anthropic's official CLI for Claude."

---@private
---@class AvanteAnthropicState
---@field claude_token ClaudeAuthToken?
M.state = nil

M.api_key_name = "ANTHROPIC_API_KEY"
M.support_prompt_caching = true

M.tokenizer_id = "gpt-4o"
M.role_map = {
  user = "user",
  assistant = "assistant",
}

M._is_setup = false
M._refresh_timer = nil

-- Token validation helper
---@param token ClaudeAuthToken?
---@return boolean
local function is_valid_token(token)
  return token ~= nil
    and type(token.access_token) == "string"
    and type(token.refresh_token) == "string"
    and type(token.expires_at) == "number"
    and token.access_token ~= ""
    and token.refresh_token ~= ""
end

-- Lockfile management
local function is_process_running(pid)
  local result = vim.uv.kill(pid, 0)
  if result ~= nil and result == 0 then
    return true
  else
    return false
  end
end

local function try_acquire_claude_timer_lock()
  local lockfile = Path:new(lockfile_path)

  local tmp_lockfile = lockfile_path .. ".tmp." .. vim.fn.getpid()

  Path:new(tmp_lockfile):write(tostring(vim.fn.getpid()), "w")

  -- Check existing lock
  if lockfile:exists() then
    local content = lockfile:read()
    local pid = tonumber(content)
    if pid and is_process_running(pid) then
      os.remove(tmp_lockfile)
      return false -- Another instance is already managing
    end
  end

  -- Attempt to take ownership
  local success = os.rename(tmp_lockfile, lockfile_path)
  if not success then
    os.remove(tmp_lockfile)
    return false
  end

  return true
end

local function start_manager_check_timer()
  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
  end

  M._manager_check_timer = vim.uv.new_timer()
  M._manager_check_timer:start(
    30000,
    30000,
    vim.schedule_wrap(function()
      if not M._refresh_timer and try_acquire_claude_timer_lock() then M.setup_claude_timer() end
    end)
  )
end

---@private
function M.setup_claude_file_watcher()
  if M._file_watcher then return end

  local claude_token_file = Path:new(claude_path)
  M._file_watcher = vim.uv.new_fs_event()

  M._file_watcher:start(
    claude_path,
    {},
    vim.schedule_wrap(function()
      -- Reload token from file
      if claude_token_file:exists() then
        local ok, token = pcall(vim.json.decode, claude_token_file:read())
        if ok then M.state.claude_token = token end
      end
    end)
  )
end

-- Common token management setup (timer, file watcher, tokenizer)
local function setup_token_management()
  -- Setup timer management
  local timer_lock_acquired = try_acquire_claude_timer_lock()
  if timer_lock_acquired then
    M.setup_claude_timer()
  else
    vim.schedule(function()
      if M._is_setup then M.refresh_token(true, false) end
    end)
  end

  M.setup_claude_file_watcher()
  start_manager_check_timer()
  require("avante.tokenizers").setup(M.tokenizer_id)
  vim.g.avante_login = true
end

function M.setup()
  local claude_token_file = Path:new(claude_path)
  local auth_type = P[Config.provider].auth_type

  if auth_type == "api" then
    require("avante.tokenizers").setup(M.tokenizer_id)
    M._is_setup = true
    return
  end

  M.api_key_name = ""

  if not M.state then M.state = {
    claude_token = nil,
  } end

  if claude_token_file:exists() then
    local ok, token = pcall(vim.json.decode, claude_token_file:read())
    -- Note: We don't check expiration here because refresh logic needs the refresh_token field
    -- from the existing token. Expired tokens will be refreshed automatically on next use.
    if ok and is_valid_token(token) then
      M.state.claude_token = token
    elseif ok and not is_valid_token(token) then
      -- Token file exists but is malformed - delete and re-authenticate
      Utils.warn("Claude token file is corrupted or invalid, re-authenticating...", { title = "Avante" })
      vim.schedule(function() pcall(claude_token_file.rm, claude_token_file) end)
      M.authenticate()
    elseif not ok then
      -- JSON decode failed - file is corrupted
      Utils.warn(
        "Failed to parse Claude token file: " .. tostring(token) .. ", re-authenticating...",
        { title = "Avante" }
      )
      vim.schedule(function() pcall(claude_token_file.rm, claude_token_file) end)
      M.authenticate()
    end

    setup_token_management()
    M._is_setup = true
  else
    M.authenticate()
    setup_token_management()
    -- Note: M._is_setup is NOT set to true here because authenticate() is async
    -- and may fail. The flag indicates setup was attempted, not that it succeeded.
  end
end

---@nodoc
function M.setup_claude_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
  end

  -- Calculate time until token expires
  local now = math.floor(os.time())
  local expires_at = M.state.claude_token and M.state.claude_token.expires_at or now
  local time_until_expiry = math.max(0, expires_at - now)
  -- Refresh 2 minutes before expiration
  local initial_interval = math.max(0, (time_until_expiry - 120) * 1000)
  -- Regular interval of 28 minutes after the first refresh
  -- local repeat_interval = 28 * 60 * 1000
  local repeat_interval = 0 -- Try 0 as we should know exactly when the refresh is needed, rather than repeating

  M._refresh_timer = vim.uv.new_timer()
  M._refresh_timer:start(
    initial_interval,
    repeat_interval,
    vim.schedule_wrap(function()
      if M._is_setup then M.refresh_token(true, true) end
    end)
  )
end

---@param headers table<string, string>
---@return integer|nil
function M:get_rate_limit_sleep_time(headers)
  local remaining_tokens = tonumber(headers["anthropic-ratelimit-tokens-remaining"])
  if remaining_tokens == nil then return end
  if remaining_tokens > 10000 then return end
  local reset_dt_str = headers["anthropic-ratelimit-tokens-reset"]
  if remaining_tokens ~= 0 then reset_dt_str = reset_dt_str or headers["anthropic-ratelimit-requests-reset"] end
  local reset_dt, err = Utils.parse_iso8601_date(reset_dt_str)
  if err then
    Utils.warn(err)
    return
  end
  local now = Utils.utc_now()
  return Utils.datetime_diff(tostring(now), tostring(reset_dt))
end

-- Models that do not support the temperature parameter.
-- Claude 4+ generation models (new naming: claude-{tier}-{version}) use always-on extended thinking,
-- which is incompatible with the temperature parameter (API hard error if sent).
-- See: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking#important-considerations
---@param model string|nil
---@return boolean
function M.is_temperature_unsupported(model)
  if not model then return false end
  -- Claude 4+ models use new naming convention: claude-{tier}-{major}[-{minor}]-{date}
  -- e.g. claude-opus-4-20250514, claude-sonnet-4-5-20250929, claude-sonnet-4-20250514
  -- Also handles bedrock/vertex prefixed names like us.anthropic.claude-opus-4-*
  if model:match("claude%-opus%-[4-9]") then return true end
  if model:match("claude%-sonnet%-[4-9]") then return true end
  if model:match("claude%-haiku%-[4-9]") then return true end
  return false
end

-- Prefix for tool names when using OAuth to avoid Anthropic's tool name validation
local OAUTH_TOOL_PREFIX = "av_"

-- Strip the OAuth tool prefix from a tool name
local function strip_tool_prefix(name)
  if name and name:sub(1, #OAUTH_TOOL_PREFIX) == OAUTH_TOOL_PREFIX then return name:sub(#OAUTH_TOOL_PREFIX + 1) end
  return name
end

---@param self AvanteProviderFunctor
---@param tool AvanteLLMTool
---@param use_prefix? boolean Whether to prefix tool names (for OAuth)
---@return AvanteClaudeTool
function M:transform_tool(tool, use_prefix)
  local input_schema_properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
  local tool_name = tool.name
  if use_prefix then tool_name = OAUTH_TOOL_PREFIX .. tool.name end
  local tool_def = {
    name = tool_name,
    description = tool.get_description and tool.get_description() or tool.description,
    input_schema = {
      type = "object",
      properties = input_schema_properties,
      required = required,
    },
    -- OAuth/claude-code beta requires discriminated tool type
    type = use_prefix and "custom" or nil,
  }
  return tool_def
end

function M:is_disable_stream() return false end

---@return AvanteClaudeMessage[]
function M:parse_messages(opts)
  ---@type AvanteClaudeMessage[]
  local messages = {}

  local provider_conf, _ = P.parse_config(self)
  ---@cast provider_conf AvanteAnthropicProvider

  ---@type {idx: integer, length: integer}[]
  local messages_with_length = {}
  for idx, message in ipairs(opts.messages) do
    table.insert(messages_with_length, { idx = idx, length = Utils.tokens.calculate_tokens(message.content) })
  end

  table.sort(messages_with_length, function(a, b) return a.length > b.length end)

  local has_tool_use = false
  for _, message in ipairs(opts.messages) do
    local content_items = message.content
    local message_content = {}
    if type(content_items) == "string" then
      if message.role == "assistant" then content_items = content_items:gsub("%s+$", "") end
      if content_items ~= "" then
        table.insert(message_content, {
          type = "text",
          text = content_items,
        })
      end
    elseif type(content_items) == "table" then
      ---@cast content_items AvanteLLMMessageContentItem[]
      for _, item in ipairs(content_items) do
        if type(item) == "string" then
          if message.role == "assistant" then item = item:gsub("%s+$", "") end
          table.insert(message_content, { type = "text", text = item })
        elseif type(item) == "table" and item.type == "text" then
          table.insert(message_content, { type = "text", text = item.text })
        elseif type(item) == "table" and item.type == "image" then
          table.insert(message_content, { type = "image", source = item.source })
        elseif not provider_conf.disable_tools and type(item) == "table" and item.type == "tool_use" then
          has_tool_use = true
          -- Prefix tool name for OAuth to bypass Anthropic's tool name validation
          local tool_name = item.name
          if provider_conf.auth_type == "max" then tool_name = OAUTH_TOOL_PREFIX .. item.name end
          table.insert(message_content, { type = "tool_use", name = tool_name, id = item.id, input = item.input })
        elseif
          not provider_conf.disable_tools
          and type(item) == "table"
          and item.type == "tool_result"
          and has_tool_use
        then
          table.insert(
            message_content,
            { type = "tool_result", tool_use_id = item.tool_use_id, content = item.content, is_error = item.is_error }
          )
        elseif type(item) == "table" and item.type == "thinking" then
          table.insert(message_content, { type = "thinking", thinking = item.thinking, signature = item.signature })
        elseif type(item) == "table" and item.type == "redacted_thinking" then
          table.insert(message_content, { type = "redacted_thinking", data = item.data })
        end
      end
    end
    if #message_content > 0 then
      table.insert(messages, {
        role = self.role_map[message.role],
        content = message_content,
      })
    end
  end

  if Clipboard.support_paste_image() and opts.image_paths and #opts.image_paths > 0 then
    local message_content = messages[#messages].content
    for _, image_path in ipairs(opts.image_paths) do
      table.insert(message_content, {
        type = "image",
        source = {
          type = "base64",
          media_type = "image/png",
          data = Clipboard.get_base64_content(image_path),
        },
      })
    end
    messages[#messages].content = message_content
  end

  return messages
end

---@param usage avante.AnthropicTokenUsage | nil
---@return avante.LLMTokenUsage | nil
function M.transform_anthropic_usage(usage)
  if not usage then return nil end
  ---@type avante.LLMTokenUsage
  local res = {
    prompt_tokens = usage.cache_creation_input_tokens and (usage.input_tokens + usage.cache_creation_input_tokens)
      or usage.input_tokens,
    completion_tokens = usage.cache_read_input_tokens and (usage.output_tokens + usage.cache_read_input_tokens)
      or usage.output_tokens,
  }

  return res
end

function M:parse_response(ctx, data_stream, event_state, opts)
  if event_state == nil then
    if data_stream:match('"message_start"') then
      event_state = "message_start"
    elseif data_stream:match('"message_delta"') then
      event_state = "message_delta"
    elseif data_stream:match('"message_stop"') then
      event_state = "message_stop"
    elseif data_stream:match('"content_block_start"') then
      event_state = "content_block_start"
    elseif data_stream:match('"content_block_delta"') then
      event_state = "content_block_delta"
    elseif data_stream:match('"content_block_stop"') then
      event_state = "content_block_stop"
    end
  end
  if ctx.content_blocks == nil then ctx.content_blocks = {} end

  ---@param content AvanteLLMMessageContentItem
  ---@param uuid? string
  ---@return avante.HistoryMessage
  local function new_assistant_message(content, uuid)
    assert(
      event_state == "content_block_start"
        or event_state == "content_block_delta"
        or event_state == "content_block_stop",
      "called with unexpected event_state: " .. event_state
    )
    return HistoryMessage:new("assistant", content, {
      state = event_state == "content_block_stop" and "generated" or "generating",
      turn_id = ctx.turn_id,
      uuid = uuid,
    })
  end

  if event_state == "message_start" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    ctx.usage = jsn.message.usage
  elseif event_state == "content_block_start" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = jsn.content_block
    content_block.stoppped = false
    ctx.content_blocks[jsn.index + 1] = content_block
    if content_block.type == "text" then
      local msg = new_assistant_message(content_block.text)
      content_block.uuid = msg.uuid
      if opts.on_messages_add then opts.on_messages_add({ msg }) end
    elseif content_block.type == "thinking" then
      if opts.on_chunk then opts.on_chunk("<think>\n") end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        })
        content_block.uuid = msg.uuid
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "tool_use" then
      if opts.on_messages_add then
        local incomplete_json = JsonParser.parse(content_block.input_json)
        local msg = new_assistant_message({
          type = "tool_use",
          -- Strip OAuth tool prefix from tool name
          name = strip_tool_prefix(content_block.name),
          id = content_block.id,
          input = incomplete_json or { dummy = "" },
        })
        content_block.uuid = msg.uuid
        opts.on_messages_add({ msg })
        -- opts.on_stop({ reason = "tool_use", streaming_tool_use = true })
      end
    end
  elseif event_state == "content_block_delta" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = ctx.content_blocks[jsn.index + 1]
    if jsn.delta.type == "input_json_delta" then
      if not content_block.input_json then content_block.input_json = "" end
      content_block.input_json = content_block.input_json .. jsn.delta.partial_json
      return
    elseif jsn.delta.type == "thinking_delta" then
      content_block.thinking = content_block.thinking .. jsn.delta.thinking
      if opts.on_chunk then opts.on_chunk(jsn.delta.thinking) end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif jsn.delta.type == "text_delta" then
      content_block.text = content_block.text .. jsn.delta.text
      if opts.on_chunk then opts.on_chunk(jsn.delta.text) end
      if opts.on_messages_add then
        local msg = new_assistant_message(content_block.text, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif jsn.delta.type == "signature_delta" then
      if ctx.content_blocks[jsn.index + 1].signature == nil then ctx.content_blocks[jsn.index + 1].signature = "" end
      ctx.content_blocks[jsn.index + 1].signature = ctx.content_blocks[jsn.index + 1].signature .. jsn.delta.signature
    end
  elseif event_state == "content_block_stop" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = ctx.content_blocks[jsn.index + 1]
    content_block.stoppped = true
    if content_block.type == "text" then
      if opts.on_messages_add then
        local msg = new_assistant_message(content_block.text, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "thinking" then
      if opts.on_chunk then
        if content_block.thinking and content_block.thinking ~= vim.NIL and content_block.thinking:sub(-1) ~= "\n" then
          opts.on_chunk("\n</think>\n\n")
        else
          opts.on_chunk("</think>\n\n")
        end
      end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "tool_use" then
      if opts.on_messages_add then
        local ok_, complete_json = pcall(vim.json.decode, content_block.input_json)
        if not ok_ then complete_json = nil end
        local msg = new_assistant_message({
          type = "tool_use",
          -- Strip OAuth tool prefix from tool name
          name = strip_tool_prefix(content_block.name),
          id = content_block.id,
          input = complete_json or { dummy = "" },
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    end
  elseif event_state == "message_delta" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    if jsn.usage and ctx.usage then ctx.usage.output_tokens = ctx.usage.output_tokens + jsn.usage.output_tokens end
    if jsn.delta.stop_reason == "end_turn" then
      opts.on_stop({ reason = "complete", usage = M.transform_anthropic_usage(ctx.usage) })
    elseif jsn.delta.stop_reason == "max_tokens" then
      opts.on_stop({ reason = "max_tokens", usage = M.transform_anthropic_usage(ctx.usage) })
    elseif jsn.delta.stop_reason == "tool_use" then
      opts.on_stop({
        reason = "tool_use",
        usage = M.transform_anthropic_usage(ctx.usage),
      })
    end
    return
  elseif event_state == "error" then
    opts.on_stop({ reason = "error", error = vim.json.decode(data_stream) })
  end
end

---@param prompt_opts AvantePromptOptions
---@return AvanteCurlOutput|nil
function M:parse_curl_args(prompt_opts)
  -- refresh token synchronously, only if it has expired
  -- (this should rarely happen, as we refresh the token in the background)
  M.refresh_token(false, false)

  local provider_conf, request_body = P.parse_config(self)
  ---@cast provider_conf AvanteAnthropicProvider
  local disable_tools = provider_conf.disable_tools or false

  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
    ["User-Agent"] = "axios/1.15.2",
  }

  if provider_conf.auth_type == "max" then
    local api_key = M.state.claude_token.access_token
    headers["authorization"] = string.format("Bearer %s", api_key)
    -- Match Claude CLI user-agent for OAuth requests (per opencode-anthropic-auth PR #11)
    headers["user-agent"] = "claude-cli/2.1.2 (external, cli)"
    -- OAuth beta headers - include claude-code identifier, exclude fine-grained-tool-streaming
    headers["anthropic-beta"] =
      "oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,prompt-caching-2024-07-31"
  else
    if P.env.require_api_key(provider_conf) then
      local api_key = self.parse_api_key()
      if not api_key then
        Utils.error("Claude: API key is not set. Please set " .. M.api_key_name)
        return nil
      end
      headers["x-api-key"] = api_key
      headers["anthropic-beta"] = "prompt-caching-2024-07-31"
    end
  end

  local messages = self:parse_messages(prompt_opts)

  local tools = {}
  -- Prefix tool names for OAuth to bypass Anthropic's tool name validation
  local use_prefix = provider_conf.auth_type == "max"
  if not disable_tools and prompt_opts.tools then
    for _, tool in ipairs(prompt_opts.tools) do
      if Config.mode == "agentic" then
        if tool.name == "create_file" then goto continue end
        if tool.name == "view" then goto continue end
        if tool.name == "str_replace" then goto continue end
        if tool.name == "create" then goto continue end
        if tool.name == "insert" then goto continue end
        if tool.name == "undo_edit" then goto continue end
        if tool.name == "replace_in_file" then goto continue end
      end
      table.insert(tools, self:transform_tool(tool, use_prefix))
      ::continue::
    end
  end

  if prompt_opts.tools and #prompt_opts.tools > 0 and Config.mode == "agentic" then
    if provider_conf.model:match("claude%-sonnet%-4%-[5-9]") then
      table.insert(tools, {
        type = "text_editor_20250728",
        name = "str_replace_based_edit_tool",
      })
    elseif provider_conf.model:match("claude%-sonnet%-4") then
      table.insert(tools, {
        type = "text_editor_20250429",
        name = "str_replace_based_edit_tool",
      })
    elseif provider_conf.model:match("claude%-3%-7%-sonnet") then
      table.insert(tools, {
        type = "text_editor_20250124",
        name = "str_replace_editor",
      })
    elseif provider_conf.model:match("claude%-3%-5%-sonnet") then
      table.insert(tools, {
        type = "text_editor_20250124",
        name = "str_replace_editor",
      })
    end
  end

  if self.support_prompt_caching then
    if #messages > 0 then
      local found = false
      for i = #messages, 1, -1 do
        local message = messages[i]
        message = vim.deepcopy(message)
        ---@cast message AvanteClaudeMessage
        local content = message.content
        ---@cast content AvanteClaudeMessageContentTextItem[]
        for j = #content, 1, -1 do
          local item = content[j]
          if item.type == "text" then
            item.cache_control = { type = "ephemeral" }
            found = true
            break
          end
        end
        if found then
          messages[i] = message
          break
        end
      end
    end
    if #tools > 0 then
      local last_tool = vim.deepcopy(tools[#tools])
      last_tool.cache_control = { type = "ephemeral" }
      tools[#tools] = last_tool
    end
  end

  local system = {}
  if provider_conf.auth_type == "max" then
    table.insert(system, {
      type = "text",
      text = claude_code_spoof_prompt,
    })
  end
  table.insert(system, {
    type = "text",
    text = prompt_opts.system_prompt,
    cache_control = self.support_prompt_caching and { type = "ephemeral" } or nil,
  })

  -- Add ?beta=true for OAuth requests (per opencode-anthropic-auth PR #11)
  local api_path = "/v1/messages"
  if provider_conf.auth_type == "max" then api_path = "/v1/messages?beta=true" end

  local body = vim.tbl_deep_extend("force", {
    model = provider_conf.model,
    system = system,
    messages = messages,
    tools = tools,
    stream = true,
  }, request_body)

  -- Strip temperature for models that don't support it (e.g. Opus 4 with always-on thinking)
  if M.is_temperature_unsupported(provider_conf.model) then body.temperature = nil end

  return {
    url = Utils.url_join(provider_conf.endpoint, api_path),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = body,
  }
end

function M.on_error(result)
  if result.status == 429 then return end
  if not result.body then
    return Utils.error("API request failed with status " .. result.status, { once = true, title = "Avante" })
  end

  local ok, body = pcall(vim.json.decode, result.body)
  if not (ok and body and body.error) then
    return Utils.error("Failed to parse error response", { once = true, title = "Avante" })
  end

  local error_msg = body.error.message
  local error_type = body.error.type

  if error_type == "insufficient_quota" then
    error_msg = "You don't have any credits or have exceeded your quota. Please check your plan and billing details."
  elseif error_type == "invalid_request_error" and error_msg:match("temperature") then
    error_msg = error_msg
      .. "\nPossible fixes:"
      .. "\n  - Remove 'temperature' from your provider's extra_request_body config"
      .. "\n  - Ensure the temperature value is between 0 and 1"
  end

  Utils.error(error_msg, { once = true, title = "Avante" })
end

function M.authenticate()
  local pkce = require("avante.auth.pkce")
  local verifier, verifier_err = pkce.generate_verifier()
  if not verifier then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE verifier: " .. (verifier_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local challenge, challenge_err = pkce.generate_challenge(verifier)
  if not challenge then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE challenge: " .. (challenge_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local state, state_err = pkce.generate_verifier()
  if not state then
    vim.schedule(
      function() vim.notify("Failed to generate PKCE state: " .. (state_err or "Unknown error"), vim.log.levels.ERROR) end
    )
    return
  end

  local auth_url = string.format(
    "%s?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256",
    auth_endpoint,
    client_id,
    vim.uri_encode("https://console.anthropic.com/oauth/code/callback"),
    vim.uri_encode("org:create_api_key user:profile user:inference"),
    state,
    challenge
  )

  -- Open browser to begin authentication
  -- Always show URL for terminal environments without browsers
  vim.schedule(function()
    vim.fn.setreg("+", auth_url)
    vim.notify("Please open this URL in your browser:\n" .. auth_url, vim.log.levels.WARN)
    pcall(vim.ui.open, auth_url)
  end)

  local function on_submit(input)
    if input then
      local splits = vim.split(input, "#")
      local response = curl.post(token_endpoint, {
        body = vim.json.encode({
          grant_type = "authorization_code",
          client_id = client_id,
          code = splits[1],
          state = splits[2],
          redirect_uri = "https://console.anthropic.com/oauth/code/callback",
          code_verifier = verifier,
        }),
        headers = {
          ["Content-Type"] = "application/json",
          ["User-Agent"] = "axios/1.15.2",
        },
      })

      if response.status >= 400 then
        vim.schedule(
          function() vim.notify(string.format("HTTP %d: %s", response.status, response.body), vim.log.levels.ERROR) end
        )
        return
      end

      local ok, tokens = pcall(vim.json.decode, response.body)
      if ok then
        M.store_tokens(tokens)
        vim.schedule(function() vim.notify("✓ Authentication successful!", vim.log.levels.INFO) end)
        M._is_setup = true
      else
        vim.schedule(function() vim.notify("Failed to decode JSON", vim.log.levels.ERROR) end)
      end
    else
      vim.schedule(function() vim.notify("Failed to parse code, authentication failed!", vim.log.levels.ERROR) end)
    end
  end

  local Input = require("avante.ui.input")
  local input = Input:new({
    provider = Config.input.provider,
    title = "Enter Auth Key: ",
    default = "",
    conceal = false, -- Key input should be concealed
    provider_opts = Config.input.provider_opts,
    on_submit = on_submit,
  })
  input:open()
end

--- Function to refresh an expired claude auth token
---@param async boolean whether to refresh the token asynchronously
---@param force boolean whether to force the refresh
function M.refresh_token(async, force)
  if not M.state or not M.state.claude_token then return false end -- Exit early if no state
  async = async == nil and true or async
  force = force or false

  -- Do not refresh token if not forced or not expired
  if
    not force
    and M.state.claude_token
    and M.state.claude_token.expires_at
    and M.state.claude_token.expires_at > math.floor(os.time())
  then
    return false
  end

  local base_url = token_endpoint
  local body = {
    grant_type = "refresh_token",
    client_id = client_id,
    refresh_token = M.state.claude_token.refresh_token,
  }
  local curl_opts = {
    body = vim.json.encode(body),
    headers = {
      ["Content-Type"] = "application/json",
      ["User-Agent"] = "axios/1.15.2",
    },
  }

  local function handle_response(response)
    if response.status >= 400 then
      vim.schedule(
        function()
          vim.notify(
            string.format("[%s]Failed to refresh access token: %s", response.status, response.body),
            vim.log.levels.ERROR
          )
        end
      )
      return false
    else
      local ok, tokens = pcall(vim.json.decode, response.body)
      if ok then
        M.store_tokens(tokens)

        return true
      else
        return false
      end
    end
  end

  if async then
    curl.post(
      base_url,
      vim.tbl_deep_extend("force", {
        callback = handle_response,
      }, curl_opts)
    )
  else
    local response = curl.post(base_url, curl_opts)
    handle_response(response)
  end
end

function M.store_tokens(tokens)
  local json = {
    access_token = tokens["access_token"],
    refresh_token = tokens["refresh_token"],
    expires_at = os.time() + tokens["expires_in"],
  }
  M.state.claude_token = json

  vim.schedule(function()
    local data_path = vim.fn.stdpath("data") .. "/avante/claude-auth.json"

    -- Safely encode JSON
    local ok, json_str = pcall(vim.json.encode, json)
    if not ok then
      Utils.error("Failed to encode token data: " .. tostring(json_str), { once = true, title = "Avante" })
      return
    end

    -- Open file for writing
    local file, open_err = io.open(data_path, "w")
    if not file then
      Utils.error("Failed to save token file: " .. tostring(open_err), { once = true, title = "Avante" })
      return
    end

    -- Write token data
    local write_ok, write_err = pcall(file.write, file, json_str)
    file:close()

    if not write_ok then
      Utils.error("Failed to write token file: " .. tostring(write_err), { once = true, title = "Avante" })
      return
    end

    -- Set file permissions (Unix only)
    if vim.fn.has("unix") == 1 then
      local chmod_ok = vim.loop.fs_chmod(data_path, 384) -- 0600 in decimal
      if not chmod_ok then Utils.warn("Failed to set token file permissions", { once = true, title = "Avante" }) end
    end
  end)
end

function M.cleanup_claude()
  -- Cleanup refresh timer
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil

    -- Remove lockfile if we were the manager
    local lockfile = Path:new(lockfile_path)
    if lockfile:exists() then
      local content = lockfile:read()
      local pid = tonumber(content)
      if pid and pid == vim.fn.getpid() then vim.fs.rm(tostring(lockfile)) end
    end
  end

  -- Cleanup manager check timer
  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
    M._manager_check_timer = nil
  end

  -- Cleanup file watcher
  if M._file_watcher then
    ---@diagnostic disable-next-line: param-type-mismatch
    M._file_watcher:stop()
    pcall(function() M._file_watcher:close() end)
    M._file_watcher = nil
  end
end

-- Register cleanup on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() M.cleanup_claude() end,
})

return M
