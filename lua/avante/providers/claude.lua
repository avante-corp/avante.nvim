local Utils = require("avante.utils")
local Clipboard = require("avante.clipboard")
local P = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local JsonParser = require("avante.libs.jsonparser")
local Config = require("avante.config")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "ANTHROPIC_API_KEY"
M.support_prompt_caching = true

M.role_map = {
  user = "user",
  assistant = "assistant",
}

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

---@param tool AvanteLLMTool
---@return AvanteClaudeTool
function M:transform_tool(tool)
  local input_schema_properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
  return {
    name = tool.name,
    description = tool.get_description and tool.get_description() or tool.description,
    input_schema = {
      type = "object",
      properties = input_schema_properties,
      required = required,
    },
  }
end

function M:is_disable_stream() return false end

---@return AvanteClaudeMessage[]
function M:parse_messages(opts)
  ---@type AvanteClaudeMessage[]
  local messages = {}

  local provider_conf, _ = P.parse_config(self)

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
          table.insert(message_content, { type = "tool_use", name = item.name, id = item.id, input = item.input })
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
          name = content_block.name,
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
          name = content_block.name,
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
  local provider_conf, request_body = P.parse_config(self)
  local disable_tools = provider_conf.disable_tools or false

  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
    ["anthropic-beta"] = (function()
      local sidebar = require("avante").get()
      local in_plan_mode = sidebar and sidebar.current_avante_mode == "plan"
      return in_plan_mode
        and "prompt-caching-2024-07-31,interleaved-thinking-2025-05-14"
        or "prompt-caching-2024-07-31"
    end)(),
  }

  if P.env.require_api_key(provider_conf) then
    local api_key = self.parse_api_key()
    if not api_key then
      Utils.error("Claude: API key is not set. Please set " .. M.api_key_name)
      return nil
    end
    headers["x-api-key"] = api_key
  end

  local messages = self:parse_messages(prompt_opts)

  local tools = {}
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
      table.insert(tools, self:transform_tool(tool))
      ::continue::
    end
  end

  if prompt_opts.tools and #prompt_opts.tools > 0 and Config.mode == "agentic" then
    if provider_conf.model:match("claude%-sonnet%-4%-5") then
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

  local body = vim.tbl_deep_extend("force", {
    model = provider_conf.model,
    system = {
      {
        type = "text",
        text = prompt_opts.system_prompt,
        cache_control = self.support_prompt_caching and { type = "ephemeral" } or nil,
      },
    },
    messages = messages,
    tools = tools,
    stream = true,
  }, request_body)

  -- Enable extended thinking for plan mode
  local sidebar = require("avante").get()
  if sidebar and sidebar.current_avante_mode == "plan" then
    body.thinking = {
      type = "enabled",
      budget_tokens = 10000,  -- Allow substantial thinking for planning
    }
  end

  return {
    url = Utils.url_join(provider_conf.endpoint, "/v1/messages"),
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
    error_msg = "Invalid temperature value. Please ensure it's between 0 and 1."
  end

  Utils.error(error_msg, { once = true, title = "Avante" })
end

return M
