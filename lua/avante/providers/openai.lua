---@mod avante-providers-openai OpenAI provider
local Utils = require("avante.utils")
local Config = require("avante.config")
local Providers = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local JsonParser = require("avante.libs.jsonparser")
local Prompts = require("avante.utils.prompts")
local LlmTools = require("avante.llm_tools")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "OPENAI_API_KEY"

M.role_map = {
  user = "user",
  assistant = "assistant",
}

function M:is_disable_stream() return false end

---@param tool AvanteLLMTool
---@return AvanteOpenAITool
function M:transform_tool(tool)
  local input_schema_properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
  ---@type AvanteOpenAIToolFunctionParameters
  local parameters = {
    type = "object",
    properties = input_schema_properties,
    required = required,
    additionalProperties = false,
  }
  ---@type AvanteOpenAITool
  local res = {
    type = "function",
    ["function"] = {
      name = tool.name,
      description = tool.get_description and tool.get_description() or tool.description,
      parameters = parameters,
    },
  }
  return res
end

---Check if url belongs to openrouter
---@return boolean
function M.is_openrouter(url) return url:match("^https://openrouter%.ai/") end

---Check if url belongs to mistral
---@return boolean
function M.is_mistral(url) return url:match("^https://api%.mistral%.ai/") end

---Asking remote provider to list available models
---@return AvanteProviderModelList
function M:list_models()
  Utils.info("Asking remote for available models")
  if self == nil or self == M then
    local ok, provider = pcall(function() return Providers[Config.provider] end)
    if not ok or provider.list_models ~= M.list_models then provider = Providers.openai end
    self = provider
  end
  if self._model_list_cache then return self._model_list_cache end

  local provider_conf = Providers.parse_config(self)
  if not provider_conf.endpoint then
    Utils.error("OpenAI-compatible provider requires endpoint configuration")
    return {}
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }

  if Providers.env.require_api_key(provider_conf) then
    local api_key = self.parse_api_key()
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return {}
    end
    headers["Authorization"] = "Bearer " .. api_key
  end

  local curl = require("plenary.curl")
  local response = curl.get(Utils.url_join(provider_conf.endpoint, "/models"), {
    headers = Utils.tbl_override(headers, self.extra_headers),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    timeout = provider_conf.timeout,
  })

  if response.status ~= 200 then
    Utils.error("Failed to fetch OpenAI-compatible models: " .. (response.body or response.status))
    return {}
  end

  local ok, res_body = pcall(vim.json.decode, response.body)
  if not ok or type(res_body) ~= "table" or type(res_body.data) ~= "table" then
    Utils.error("Failed to parse OpenAI-compatible model list response")
    return {}
  end

  local models = vim
    .iter(res_body.data)
    :filter(function(model) return type(model) == "table" and type(model.id) == "string" end)
    :map(
      function(model)
        return {
          id = model.id,
          name = model.id,
          display_name = model.id,
          version = tostring(model.created or model.owned_by or ""),
        }
      end
    )
    :totable()

  self._model_list_cache = models
  return models
end

---@param opts AvantePromptOptions
function M.get_user_message(opts)
  vim.deprecate("get_user_message", "parse_messages", "0.1.0", "avante.nvim")
  return table.concat(
    vim
      .iter(opts.messages)
      :filter(function(_, value) return value == nil or value.role ~= "user" end)
      :fold({}, function(acc, value)
        acc = vim.list_extend({}, acc)
        acc = vim.list_extend(acc, { value.content })
        return acc
      end),
    "\n"
  )
end

function M.is_reasoning_model(model)
  return model
    and (string.match(model, "^o%d+") ~= nil or (string.match(model, "gpt%-5") ~= nil and model ~= "gpt-5-chat"))
end

function M.set_allowed_params(provider_conf, request_body)
  local use_response_api = Providers.resolve_use_response_api(provider_conf, nil)
  if M.is_reasoning_model(provider_conf.model) then
    -- Reasoning models have specific parameter requirements
    request_body.temperature = 1
    -- Response API doesn't support temperature for reasoning models
    if use_response_api then request_body.temperature = nil end
  else
    request_body.reasoning_effort = nil
    request_body.reasoning = nil
  end
  -- If max_tokens is set in config, unset max_completion_tokens
  if request_body.max_tokens then request_body.max_completion_tokens = nil end

  -- Handle Response API specific parameters
  if use_response_api then
    -- Convert reasoning_effort to reasoning object for Response API
    if request_body.reasoning_effort then
      request_body.reasoning = {
        effort = request_body.reasoning_effort,
      }
      request_body.reasoning_effort = nil
    end

    -- Response API doesn't support some parameters
    -- Remove unsupported parameters for Response API
    local unsupported_params = {
      "top_p",
      "frequency_penalty",
      "presence_penalty",
      "logit_bias",
      "logprobs",
      "top_logprobs",
      "n",
    }
    for _, param in ipairs(unsupported_params) do
      request_body[param] = nil
    end
  end
end

function M:parse_messages(opts)
  local messages = {}
  local provider_conf, _ = Providers.parse_config(self)
  local use_response_api = Providers.resolve_use_response_api(provider_conf, opts)
  local pending_reasoning_content = nil

  local use_ReAct_prompt = provider_conf.use_ReAct_prompt == true
  local system_prompt = opts.system_prompt

  if use_ReAct_prompt then system_prompt = Prompts.get_ReAct_system_prompt(provider_conf, opts) end

  if self.is_reasoning_model(provider_conf.model) then
    table.insert(messages, { role = "developer", content = system_prompt })
  else
    table.insert(messages, { role = "system", content = system_prompt })
  end

  local has_tool_use = false

  vim.iter(opts.messages):each(function(msg)
    if type(msg.content) == "string" then
      table.insert(messages, { role = self.role_map[msg.role], content = msg.content })
    elseif type(msg.content) == "table" then
      -- Check if this is a reasoning message (object with type "reasoning")
      if msg.content.type == "reasoning" then
        -- Add reasoning message directly (for Response API)
        table.insert(messages, {
          type = "reasoning",
          id = msg.content.id,
          encrypted_content = msg.content.encrypted_content,
          summary = msg.content.summary,
        })
        return
      end

      local content = {}
      local tool_calls = {}
      local tool_results = {}
      for _, item in ipairs(msg.content) do
        if type(item) == "string" then
          table.insert(content, { type = "text", text = item })
        elseif item.type == "text" then
          table.insert(content, { type = "text", text = item.text })
        elseif item.type == "image" then
          table.insert(content, {
            type = "image_url",
            image_url = {
              url = "data:" .. item.source.media_type .. ";" .. item.source.type .. "," .. item.source.data,
            },
          })
        elseif item.type == "reasoning" then
          -- Add reasoning message directly (for Response API)
          table.insert(messages, {
            type = "reasoning",
            id = item.id,
            encrypted_content = item.encrypted_content,
            summary = item.summary,
          })
        elseif item.type == "thinking" then
          local thinking_content = item.thinking or ""
          if thinking_content ~= "" then
            if pending_reasoning_content == nil then
              pending_reasoning_content = thinking_content
            else
              pending_reasoning_content = pending_reasoning_content .. thinking_content
            end
          end
        elseif item.type == "tool_use" and not use_ReAct_prompt then
          has_tool_use = true
          table.insert(tool_calls, {
            id = item.id,
            type = "function",
            ["function"] = { name = item.name, arguments = vim.json.encode(item.input) },
          })
        elseif item.type == "tool_result" and has_tool_use and not use_ReAct_prompt then
          table.insert(
            tool_results,
            { tool_call_id = item.tool_use_id, content = item.is_error and "Error: " .. item.content or item.content }
          )
        end
      end
      if not provider_conf.disable_tools and use_ReAct_prompt then
        if msg.content[1].type == "tool_result" then
          local tool_use_msg = nil
          for _, msg_ in ipairs(opts.messages) do
            if type(msg_.content) == "table" and #msg_.content > 0 then
              if msg_.content[1].type == "tool_use" and msg_.content[1].id == msg.content[1].tool_use_id then
                tool_use_msg = msg_
                break
              end
            end
          end
          if tool_use_msg then
            msg.role = "user"
            table.insert(content, {
              type = "text",
              text = "The result of tool use " .. Utils.tool_use_to_xml(tool_use_msg.content[1]) .. " is:\n",
            })
            table.insert(content, {
              type = "text",
              text = msg.content[1].content,
            })
          end
        end
      end
      if #content > 0 then table.insert(messages, { role = self.role_map[msg.role], content = content }) end
      if not provider_conf.disable_tools and not use_ReAct_prompt then
        if #tool_calls > 0 then
          -- Only skip tool_calls if using Response API with previous_response_id support
          -- Copilot uses Response API format but doesn't support previous_response_id
          local should_include_tool_calls = not use_response_api or not provider_conf.support_previous_response_id

          if should_include_tool_calls then
            -- For Response API without previous_response_id support (like Copilot),
            -- convert tool_calls to function_call items in input
            if use_response_api then
              for _, tool_call in ipairs(tool_calls) do
                table.insert(messages, {
                  type = "function_call",
                  call_id = tool_call.id,
                  name = tool_call["function"].name,
                  arguments = tool_call["function"].arguments,
                })
              end
            else
              -- Chat Completions API format
              local last_message = messages[#messages]
              if last_message and last_message.role == self.role_map["assistant"] and last_message.tool_calls then
                last_message.tool_calls = vim.list_extend(last_message.tool_calls, tool_calls)

                last_message.reasoning_content = pending_reasoning_content or ""
                pending_reasoning_content = nil

                if not last_message.content then last_message.content = "" end
              else
                local tool_call_message = {
                  role = self.role_map["assistant"],
                  tool_calls = tool_calls,
                  content = "",
                }

                tool_call_message.reasoning_content = pending_reasoning_content
                if tool_call_message.reasoning_content == nil and not self.is_mistral(provider_conf.endpoint) then
                  -- Strict-schema OpenAI-compatible servers (e.g. some Mistral deployments) reject unknown fields entirely
                  tool_call_message.reasoning_content = ""
                end
                pending_reasoning_content = nil

                table.insert(messages, tool_call_message)
              end
            end
          end
          -- If support_previous_response_id is true, Response API manages function call history
          -- So we can skip adding tool_calls to input messages
        end
        if #tool_results > 0 then
          for _, tool_result in ipairs(tool_results) do
            -- Response API uses different format for function outputs
            if use_response_api then
              table.insert(messages, {
                type = "function_call_output",
                call_id = tool_result.tool_call_id,
                output = tool_result.content or "",
              })
            else
              table.insert(
                messages,
                { role = "tool", tool_call_id = tool_result.tool_call_id, content = tool_result.content or "" }
              )
            end
          end
        end
      end
    end
  end)

  if Config.behaviour.support_paste_from_clipboard and opts.image_paths and #opts.image_paths > 0 then
    local Clipboard = require("avante.clipboard")
    local message_content = messages[#messages].content
    if type(message_content) ~= "table" or message_content[1] == nil then
      message_content = { { type = "text", text = message_content } }
    end
    for _, image_path in ipairs(opts.image_paths) do
      table.insert(message_content, {
        type = "image_url",
        image_url = {
          url = "data:image/png;base64," .. Clipboard.get_base64_content(image_path),
        },
      })
    end
    messages[#messages].content = message_content
  end

  local final_messages = {}
  local prev_role = nil
  local prev_type = nil

  vim.iter(messages):each(function(message)
    local role = message.role
    if
      role == prev_role
      and role ~= "tool"
      and prev_type ~= "function_call"
      and prev_type ~= "function_call_output"
    then
      if role == self.role_map["assistant"] then
        table.insert(final_messages, { role = self.role_map["user"], content = "Ok" })
      else
        table.insert(final_messages, { role = self.role_map["assistant"], content = "Ok, I understand." })
      end
    else
      if role == "user" and prev_role == "tool" and M.is_mistral(provider_conf.endpoint) then
        table.insert(final_messages, { role = self.role_map["assistant"], content = "Ok, I understand." })
      end
    end
    prev_role = role
    prev_type = message.type
    table.insert(final_messages, message)
  end)

  return final_messages
end

function M:finish_pending_messages(ctx, opts)
  if ctx.content ~= nil and ctx.content ~= "" then self:add_text_message(ctx, "", "generated", opts) end
  if ctx.tool_use_map then
    for _, tool_use in pairs(ctx.tool_use_map) do
      if tool_use.state == "generating" then self:add_tool_use_message(ctx, tool_use, "generated", opts) end
    end
  end
end

local llm_tool_names = nil

function M:add_text_message(ctx, text, state, opts)
  if llm_tool_names == nil then llm_tool_names = LlmTools.get_tool_names() end
  if ctx.content == nil then ctx.content = "" end
  ctx.content = ctx.content .. text
  local content =
    ctx.content:gsub("<tool_code>", ""):gsub("</tool_code>", ""):gsub("<tool_call>", ""):gsub("</tool_call>", "")
  ctx.content = content
  local msg = HistoryMessage:new("assistant", ctx.content, {
    state = state,
    uuid = ctx.content_uuid,
    original_content = ctx.content,
  })
  ctx.content_uuid = msg.uuid
  local msgs = { msg }
  local xml_content = ctx.content
  local xml_lines = vim.split(xml_content, "\n")
  local cleaned_xml_lines = {}
  local prev_tool_name = nil
  for _, line in ipairs(xml_lines) do
    if line:match("<tool_name>") then
      local tool_name = line:match("<tool_name>(.*)</tool_name>")
      if tool_name then prev_tool_name = tool_name end
    elseif line:match("<parameters>") then
      if prev_tool_name then table.insert(cleaned_xml_lines, "<" .. prev_tool_name .. ">") end
      goto continue
    elseif line:match("</parameters>") then
      if prev_tool_name then table.insert(cleaned_xml_lines, "</" .. prev_tool_name .. ">") end
      goto continue
    end
    table.insert(cleaned_xml_lines, line)
    ::continue::
  end
  local cleaned_xml_content = table.concat(cleaned_xml_lines, "\n")
  local ReActParser = require("avante.libs.ReAct_parser2")
  local xml = ReActParser.parse(cleaned_xml_content)
  if xml and #xml > 0 then
    local new_content_list = {}
    local xml_md_openned = false
    for idx, item in ipairs(xml) do
      if item.type == "text" then
        local cleaned_lines = {}
        local lines = vim.split(item.text, "\n")
        for _, line in ipairs(lines) do
          if line:match("^```xml") or line:match("^```tool_code") or line:match("^```tool_use") then
            xml_md_openned = true
          elseif line:match("^```$") then
            if xml_md_openned then
              xml_md_openned = false
            else
              table.insert(cleaned_lines, line)
            end
          else
            table.insert(cleaned_lines, line)
          end
        end
        table.insert(new_content_list, table.concat(cleaned_lines, "\n"))
        goto continue
      end
      if not vim.tbl_contains(llm_tool_names, item.tool_name) then goto continue end
      local input = {}
      for k, v in pairs(item.tool_input or {}) do
        local ok, jsn = pcall(vim.json.decode, v)
        if ok and jsn then
          input[k] = jsn
        else
          input[k] = v
        end
      end
      if next(input) ~= nil then
        local msg_uuid = ctx.content_uuid .. "-" .. idx
        local tool_use_id = msg_uuid
        local tool_message_state = item.partial and "generating" or "generated"
        local msg_ = HistoryMessage:new("assistant", {
          type = "tool_use",
          name = item.tool_name,
          id = tool_use_id,
          input = input,
        }, {
          state = tool_message_state,
          uuid = msg_uuid,
          turn_id = ctx.turn_id,
        })
        msgs[#msgs + 1] = msg_
        ctx.tool_use_map = ctx.tool_use_map or {}
        local input_json = type(input) == "string" and input or vim.json.encode(input)
        local exists = false
        for _, tool_use in pairs(ctx.tool_use_map) do
          if tool_use.id == tool_use_id then
            tool_use.input_json = input_json
            exists = true
          end
        end
        if not exists then
          local tool_key = tostring(vim.tbl_count(ctx.tool_use_map))
          ctx.tool_use_map[tool_key] = {
            uuid = tool_use_id,
            id = tool_use_id,
            name = item.tool_name,
            input_json = input_json,
            state = "generating",
          }
        end
        opts.on_stop({ reason = "tool_use", streaming_tool_use = item.partial })
      end
      ::continue::
    end
    msg.message.content = table.concat(new_content_list, "\n"):gsub("\n+$", "\n")
  end
  if opts.on_messages_add then opts.on_messages_add(msgs) end
end

function M:add_thinking_message(ctx, text, state, opts)
  if ctx.reasoning_content == nil then ctx.reasoning_content = "" end
  ctx.reasoning_content = ctx.reasoning_content .. text
  local msg = HistoryMessage:new("assistant", {
    type = "thinking",
    thinking = ctx.reasoning_content,
    signature = "",
  }, {
    state = state,
    uuid = ctx.reasoning_content_uuid,
    turn_id = ctx.turn_id,
  })
  ctx.reasoning_content_uuid = msg.uuid
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
end

function M:add_tool_use_message(ctx, tool_use, state, opts)
  local jsn = JsonParser.parse(tool_use.input_json)
  -- Fix: Ensure empty arguments are encoded as {} (object) not [] (array)
  if jsn == nil or (type(jsn) == "table" and vim.tbl_isempty(jsn)) then jsn = vim.empty_dict() end
  local msg = HistoryMessage:new("assistant", {
    type = "tool_use",
    name = tool_use.name,
    id = tool_use.id,
    input = jsn,
  }, {
    state = state,
    uuid = tool_use.uuid,
    turn_id = ctx.turn_id,
  })
  tool_use.uuid = msg.uuid
  tool_use.state = state
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
  if state == "generating" then opts.on_stop({ reason = "tool_use", streaming_tool_use = true }) end
end

function M:add_reasoning_message(ctx, reasoning_item, opts)
  local msg = HistoryMessage:new("assistant", {
    type = "reasoning",
    id = reasoning_item.id,
    encrypted_content = reasoning_item.encrypted_content,
    summary = reasoning_item.summary,
  }, {
    state = "generated",
    uuid = Utils.uuid(),
    turn_id = ctx.turn_id,
  })
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
end

---@param usage avante.OpenAITokenUsage | nil
---@return avante.LLMTokenUsage | nil
function M.transform_openai_usage(usage)
  if not usage then return nil end
  if usage == vim.NIL then return nil end
  ---@type avante.LLMTokenUsage
  local res = {
    prompt_tokens = usage.prompt_tokens,
    completion_tokens = usage.completion_tokens,
    -- total_tokens is the sum of both
  }
  return res
end

--- Parse response
--- Updates status
function M:parse_response(ctx, data_stream, _, opts)
  if data_stream:match('"%[DONE%]":') or data_stream == "[DONE]" then
    self:finish_pending_messages(ctx, opts)
    if ctx.tool_use_map and vim.tbl_count(ctx.tool_use_map) > 0 then
      ctx.tool_use_map = {}
      opts.on_stop({ reason = "tool_use" })
    else
      opts.on_stop({ reason = "complete" })
    end
    return
  end

  ---@type any
  local jsn = vim.json.decode(data_stream)

  -- Check if this is a Response API event (has 'type' field)
  if jsn.type and type(jsn.type) == "string" then
    -- Response API event-driven format
    if jsn.type == "response.output_text.delta" then
      -- Text content delta
      if jsn.delta and jsn.delta ~= vim.NIL and jsn.delta ~= "" then
        if opts.on_chunk then opts.on_chunk(jsn.delta) end
        self:add_text_message(ctx, jsn.delta, "generating", opts)
      end
    elseif jsn.type == "response.reasoning_summary_text.delta" then
      -- Reasoning summary delta
      if jsn.delta and jsn.delta ~= vim.NIL and jsn.delta ~= "" then
        if ctx.returned_think_start_tag == nil or not ctx.returned_think_start_tag then
          ctx.returned_think_start_tag = true
          if opts.on_chunk then opts.on_chunk("<think>\n") end
        end
        ctx.last_think_content = jsn.delta
        self:add_thinking_message(ctx, jsn.delta, "generating", opts)
        if opts.on_chunk then opts.on_chunk(jsn.delta) end
      end
    elseif jsn.type == "response.function_call_arguments.delta" then
      -- Function call arguments delta
      if jsn.delta and jsn.delta ~= vim.NIL and jsn.delta ~= "" then
        if not ctx.tool_use_map then ctx.tool_use_map = {} end
        local tool_key = tostring(jsn.output_index or 0)
        if not ctx.tool_use_map[tool_key] then
          ctx.tool_use_map[tool_key] = {
            name = jsn.name or "",
            id = jsn.call_id or "",
            input_json = jsn.delta,
          }
        else
          ctx.tool_use_map[tool_key].input_json = ctx.tool_use_map[tool_key].input_json .. jsn.delta
        end
      end
    elseif jsn.type == "response.output_item.added" then
      -- Output item added (could be function call or reasoning)
      if jsn.item and jsn.item.type == "function_call" then
        local tool_key = tostring(jsn.output_index or 0)
        if not ctx.tool_use_map then ctx.tool_use_map = {} end
        ctx.tool_use_map[tool_key] = {
          name = jsn.item.name or "",
          id = jsn.item.call_id or jsn.item.id or "",
          input_json = "",
        }
        self:add_tool_use_message(ctx, ctx.tool_use_map[tool_key], "generating", opts)
      elseif jsn.item and jsn.item.type == "reasoning" then
        -- Add reasoning item to history
        self:add_reasoning_message(ctx, jsn.item, opts)
      end
    elseif jsn.type == "response.output_item.done" then
      -- Output item done (finalize function call)
      if jsn.item and jsn.item.type == "function_call" then
        local tool_key = tostring(jsn.output_index or 0)
        if ctx.tool_use_map and ctx.tool_use_map[tool_key] then
          local tool_use = ctx.tool_use_map[tool_key]
          if jsn.item.arguments then tool_use.input_json = jsn.item.arguments end
          self:add_tool_use_message(ctx, tool_use, "generated", opts)
        end
      end
    elseif jsn.type == "response.completed" or jsn.type == "response.done" then
      -- Response completed - save response.id for future requests
      if jsn.response and jsn.response.id then
        ctx.last_response_id = jsn.response.id
        -- Store in provider for next request
        self.last_response_id = jsn.response.id
      end
      if
        ctx.returned_think_start_tag ~= nil and (ctx.returned_think_end_tag == nil or not ctx.returned_think_end_tag)
      then
        ctx.returned_think_end_tag = true
        if opts.on_chunk then
          if
            ctx.last_think_content
            and ctx.last_think_content ~= vim.NIL
            and ctx.last_think_content:sub(-1) ~= "\n"
          then
            opts.on_chunk("\n</think>\n")
          else
            opts.on_chunk("</think>\n")
          end
        end
        self:add_thinking_message(ctx, "", "generated", opts)
      end
      self:finish_pending_messages(ctx, opts)
      local usage = nil
      if jsn.response and jsn.response.usage then usage = self.transform_openai_usage(jsn.response.usage) end
      if ctx.tool_use_map and vim.tbl_count(ctx.tool_use_map) > 0 then
        opts.on_stop({ reason = "tool_use", usage = usage })
      else
        opts.on_stop({ reason = "complete", usage = usage })
      end
    elseif jsn.type == "error" then
      -- Error event
      local error_msg = jsn.error and vim.inspect(jsn.error) or "Unknown error"
      opts.on_stop({ reason = "error", error = error_msg })
    end
    return
  end

  -- Chat Completions API format (original code)
  if jsn.usage and jsn.usage ~= vim.NIL then
    if opts.update_tokens_usage then
      local usage = self.transform_openai_usage(jsn.usage)
      if usage then opts.update_tokens_usage(usage) end
    end
  end
  if jsn.error and jsn.error ~= vim.NIL then
    opts.on_stop({ reason = "error", error = vim.inspect(jsn.error) })
    return
  end
  ---@cast jsn AvanteOpenAIChatResponse
  if not jsn.choices then return end
  local choice = jsn.choices[1]
  if not choice then return end
  local delta = choice.delta
  if not delta then
    local provider_conf = Providers.parse_config(self)
    if provider_conf.model:match("o1") then delta = choice.message end
  end
  if not delta then return end
  if delta.reasoning_content and delta.reasoning_content ~= vim.NIL and delta.reasoning_content ~= "" then
    if ctx.returned_think_start_tag == nil or not ctx.returned_think_start_tag then
      ctx.returned_think_start_tag = true
      if opts.on_chunk then opts.on_chunk("<think>\n") end
    end
    ctx.last_think_content = delta.reasoning_content
    self:add_thinking_message(ctx, delta.reasoning_content, "generating", opts)
    if opts.on_chunk then opts.on_chunk(delta.reasoning_content) end
  elseif delta.reasoning and delta.reasoning ~= vim.NIL then
    if ctx.returned_think_start_tag == nil or not ctx.returned_think_start_tag then
      ctx.returned_think_start_tag = true
      if opts.on_chunk then opts.on_chunk("<think>\n") end
    end
    ctx.last_think_content = delta.reasoning
    self:add_thinking_message(ctx, delta.reasoning, "generating", opts)
    if opts.on_chunk then opts.on_chunk(delta.reasoning) end
  elseif delta.tool_calls and delta.tool_calls ~= vim.NIL then
    local choice_index = choice.index or 0
    for idx, tool_call in ipairs(delta.tool_calls) do
      --- In Gemini's so-called OpenAI Compatible API, tool_call.index is nil, which is quite absurd! Therefore, a compatibility fix is needed here.
      if tool_call.index == nil then tool_call.index = choice_index + idx - 1 end
      if not ctx.tool_use_map then ctx.tool_use_map = {} end
      local tool_key = tostring(tool_call.index)
      local prev_tool_key = tostring(tool_call.index - 1)
      if not ctx.tool_use_map[tool_key] then
        local prev_tool_use = ctx.tool_use_map[prev_tool_key]
        if tool_call.index > 0 and prev_tool_use then
          self:add_tool_use_message(ctx, prev_tool_use, "generated", opts)
        end
        local tool_use = {
          name = tool_call["function"].name,
          id = tool_call.id,
          input_json = type(tool_call["function"].arguments) == "string" and tool_call["function"].arguments or "",
        }
        ctx.tool_use_map[tool_key] = tool_use
        self:add_tool_use_message(ctx, tool_use, "generating", opts)
      else
        local tool_use = ctx.tool_use_map[tool_key]
        if tool_call["function"].arguments == vim.NIL then tool_call["function"].arguments = "" end
        tool_use.input_json = tool_use.input_json .. tool_call["function"].arguments
        -- self:add_tool_use_message(ctx, tool_use, "generating", opts)
      end
    end
  elseif delta.content then
    if
      ctx.returned_think_start_tag ~= nil and (ctx.returned_think_end_tag == nil or not ctx.returned_think_end_tag)
    then
      ctx.returned_think_end_tag = true
      if opts.on_chunk then
        if ctx.last_think_content and ctx.last_think_content ~= vim.NIL and ctx.last_think_content:sub(-1) ~= "\n" then
          opts.on_chunk("\n</think>\n")
        else
          opts.on_chunk("</think>\n")
        end
      end
      self:add_thinking_message(ctx, "", "generated", opts)
    end
    if delta.content ~= vim.NIL then
      if opts.on_chunk then opts.on_chunk(delta.content) end
      self:add_text_message(ctx, delta.content, "generating", opts)
    end
  end
  if choice.finish_reason == "stop" or choice.finish_reason == "eos_token" or choice.finish_reason == "length" then
    self:finish_pending_messages(ctx, opts)
    if ctx.tool_use_map and vim.tbl_count(ctx.tool_use_map) > 0 then
      opts.on_stop({ reason = "tool_use", usage = self.transform_openai_usage(jsn.usage) })
    else
      opts.on_stop({ reason = "complete", usage = self.transform_openai_usage(jsn.usage) })
    end
  end
  if choice.finish_reason == "tool_calls" then
    self:finish_pending_messages(ctx, opts)
    opts.on_stop({
      reason = "tool_use",
      usage = self.transform_openai_usage(jsn.usage),
    })
  end
end

function M:parse_response_without_stream(data, _, opts)
  ---@type AvanteOpenAIChatResponse
  local json = vim.json.decode(data)
  if json.choices and json.choices[1] then
    local choice = json.choices[1]
    if choice.message and choice.message.content then
      if opts.on_chunk then opts.on_chunk(choice.message.content) end
      self:add_text_message({}, choice.message.content, "generated", opts)
      vim.schedule(function() opts.on_stop({ reason = "complete" }) end)
    end
  end
end

---@param prompt_opts AvantePromptOptions
---@return AvanteCurlOutput|nil
function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = Providers.parse_config(self)
  local disable_tools = provider_conf.disable_tools or false

  local headers = {
    ["Content-Type"] = "application/json",
  }

  if Providers.env.require_api_key(provider_conf) then
    local api_key = self.parse_api_key()
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return nil
    end
    headers["Authorization"] = "Bearer " .. api_key
  end

  if M.is_openrouter(provider_conf.endpoint) then
    headers["HTTP-Referer"] = "https://github.com/yetone/avante.nvim"
    headers["X-Title"] = "Avante.nvim"
    request_body.include_reasoning = true
  end

  self.set_allowed_params(provider_conf, request_body)
  local use_response_api = Providers.resolve_use_response_api(provider_conf, prompt_opts)

  local use_ReAct_prompt = provider_conf.use_ReAct_prompt == true

  local tools = nil
  if not disable_tools and prompt_opts.tools and not use_ReAct_prompt then
    tools = {}
    for _, tool in ipairs(prompt_opts.tools) do
      local transformed_tool = self:transform_tool(tool)
      -- Response API uses flattened tool structure
      if use_response_api then
        -- Convert from {type: "function", function: {name, description, parameters}}
        -- to {type: "function", name, description, parameters}
        if transformed_tool.type == "function" and transformed_tool["function"] then
          transformed_tool = {
            type = "function",
            name = transformed_tool["function"].name,
            description = transformed_tool["function"].description,
            parameters = transformed_tool["function"].parameters,
          }
        end
      end
      table.insert(tools, transformed_tool)
    end
  end

  local stop = nil
  if use_ReAct_prompt then stop = { "</tool_use>" } end

  -- Determine endpoint path based on use_response_api
  local endpoint_path = use_response_api and "/responses" or "/chat/completions"

  local parsed_messages = self:parse_messages(prompt_opts)

  -- Build base body
  local base_body = {
    model = provider_conf.model,
    stop = stop,
    stream = true,
    tools = tools,
  }

  -- Response API uses 'input' instead of 'messages'
  if use_response_api then
    -- Check if we have tool results - if so, use previous_response_id
    local has_function_outputs = false
    for _, msg in ipairs(parsed_messages) do
      if msg.type == "function_call_output" then
        has_function_outputs = true
        break
      end
    end

    if has_function_outputs and self.last_response_id then
      -- When sending function outputs, use previous_response_id
      base_body.previous_response_id = self.last_response_id
      -- Only send the function outputs, not the full history
      local function_outputs = {}
      for _, msg in ipairs(parsed_messages) do
        if msg.type == "function_call_output" then table.insert(function_outputs, msg) end
      end
      base_body.input = function_outputs
      -- Clear the stored response_id after using it
      self.last_response_id = nil
    else
      -- Normal request without tool results
      base_body.input = parsed_messages
    end

    -- Response API uses max_output_tokens instead of max_tokens/max_completion_tokens
    if request_body.max_completion_tokens then
      request_body.max_output_tokens = request_body.max_completion_tokens
      request_body.max_completion_tokens = nil
    end
    if request_body.max_tokens then
      request_body.max_output_tokens = request_body.max_tokens
      request_body.max_tokens = nil
    end
    -- Response API doesn't use stream_options
    base_body.stream_options = nil
  else
    base_body.messages = parsed_messages
    base_body.stream_options = not M.is_mistral(provider_conf.endpoint) and {
      include_usage = true,
    } or nil
  end

  return {
    url = Utils.url_join(provider_conf.endpoint, endpoint_path),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = vim.tbl_deep_extend("force", base_body, request_body),
  }
end

return M
