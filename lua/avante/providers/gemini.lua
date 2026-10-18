local Utils = require("avante.utils")
local Providers = require("avante.providers")
local Clipboard = require("avante.clipboard")
local OpenAI = require("avante.providers").openai
local Prompts = require("avante.utils.prompts")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "GEMINI_API_KEY"
M.role_map = {
  user = "user",
  assistant = "model",
}

function M:is_disable_stream() return false end

---@param tool AvanteLLMTool
function M:transform_to_function_declaration(tool)
  local input_schema_properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
  local parameters = nil
  if not vim.tbl_isempty(input_schema_properties) then
    parameters = {
      type = "object",
      properties = input_schema_properties,
      required = required,
    }
  end
  return {
    name = tool.name,
    description = tool.get_description and tool.get_description() or tool.description,
    parameters = parameters,
  }
end

function M:parse_messages(opts)
  local provider_conf, _ = Providers.parse_config(self)
  local use_ReAct_prompt = provider_conf.use_ReAct_prompt == true

  local contents = {}
  local prev_role = nil

  local tool_id_to_name = {}
  vim.iter(opts.messages):each(function(message)
    local role = message.role
    if role == prev_role then
      if role == M.role_map["user"] then
        table.insert(
          contents,
          { role = M.role_map["assistant"], parts = {
            { text = "Ok, I understand." },
          } }
        )
      else
        table.insert(contents, { role = M.role_map["user"], parts = {
          { text = "Ok" },
        } })
      end
    end
    prev_role = role
    local parts = {}
    local content_items = message.content
    if type(content_items) == "string" then
      table.insert(parts, { text = content_items })
    elseif type(content_items) == "table" then
      ---@cast content_items AvanteLLMMessageContentItem[]
      for _, item in ipairs(content_items) do
        if type(item) == "string" then
          table.insert(parts, { text = item })
        elseif type(item) == "table" and item.type == "text" then
          table.insert(parts, { text = item.text })
        elseif type(item) == "table" and item.type == "image" then
          table.insert(parts, {
            inline_data = {
              mime_type = "image/png",
              data = item.source.data,
            },
          })
        elseif type(item) == "table" and item.type == "tool_use" and not use_ReAct_prompt then
          tool_id_to_name[item.id] = item.name
          role = "model"
          table.insert(parts, {
            functionCall = {
              name = item.name,
              args = item.input,
            },
          })
        elseif type(item) == "table" and item.type == "tool_result" and not use_ReAct_prompt then
          role = "function"
          local ok, content = pcall(vim.json.decode, item.content)
          if not ok then content = item.content end
          -- item.name here refers to the name of the tool that was called,
          -- which is available in the tool_result content item prepared by llm.lua
          local tool_name = item.name
          if not tool_name then
            -- Fallback, though item.name should ideally always be present for tool_result
            tool_name = tool_id_to_name[item.tool_use_id]
          end
          table.insert(parts, {
            functionResponse = {
              name = tool_name,
              response = {
                name = tool_name, -- Gemini API requires the name in the response object as well
                content = content,
              },
            },
          })
        elseif type(item) == "table" and item.type == "thinking" then
          table.insert(parts, { text = item.thinking })
        elseif type(item) == "table" and item.type == "redacted_thinking" then
          table.insert(parts, { text = item.data })
        end
      end
      if not provider_conf.disable_tools and use_ReAct_prompt then
        if content_items[1].type == "tool_result" then
          local tool_use_msg = nil
          for _, msg_ in ipairs(opts.messages) do
            if type(msg_.content) == "table" and #msg_.content > 0 then
              if msg_.content[1].type == "tool_use" and msg_.content[1].id == content_items[1].tool_use_id then
                tool_use_msg = msg_
                break
              end
            end
          end
          if tool_use_msg then
            table.insert(contents, {
              role = "model",
              parts = {
                { text = Utils.tool_use_to_xml(tool_use_msg.content[1]) },
              },
            })
            role = "user"
            table.insert(parts, {
              text = "The result of tool use " .. Utils.tool_use_to_xml(tool_use_msg.content[1]) .. " is:\n",
            })
            table.insert(parts, {
              text = content_items[1].content,
            })
          end
        end
      end
    end
    if #parts > 0 then table.insert(contents, { role = M.role_map[role] or role, parts = parts }) end
  end)

  if Clipboard.support_paste_image() and opts.image_paths then
    for _, image_path in ipairs(opts.image_paths) do
      local image_data = {
        inline_data = {
          mime_type = "image/png",
          data = Clipboard.get_base64_content(image_path),
        },
      }

      table.insert(contents[#contents].parts, image_data)
    end
  end

  local system_prompt = opts.system_prompt

  if use_ReAct_prompt then system_prompt = Prompts.get_ReAct_system_prompt(provider_conf, opts) end

  return {
    systemInstruction = {
      role = "user",
      parts = {
        {
          text = system_prompt,
        },
      },
    },
    contents = contents,
  }
end

--- Prepares the main request body for Gemini-like APIs.
---@param provider_instance AvanteProviderFunctor The provider instance (self).
---@param prompt_opts AvantePromptOptions Prompt options including messages, tools, system_prompt.
---@param provider_conf table Provider configuration from config.lua (e.g., model, top-level temperature/max_tokens).
---@param request_body_ table Request-specific overrides, typically from provider_conf.request_config_overrides.
---@return table The fully constructed request body.
function M.prepare_request_body(provider_instance, prompt_opts, provider_conf, request_body_)
  local request_body = {}
  request_body.generationConfig = request_body_.generationConfig or {}

  local use_ReAct_prompt = provider_conf.use_ReAct_prompt == true

  if use_ReAct_prompt then request_body.generationConfig.stopSequences = { "</tool_use>" } end

  local disable_tools = provider_conf.disable_tools or false

  if not use_ReAct_prompt and not disable_tools and prompt_opts.tools then
    local function_declarations = {}
    for _, tool in ipairs(prompt_opts.tools) do
      table.insert(function_declarations, provider_instance:transform_to_function_declaration(tool))
    end

    if #function_declarations > 0 then
      request_body.tools = {
        {
          functionDeclarations = function_declarations,
        },
      }
    end
  end

  return vim.tbl_deep_extend("force", {}, provider_instance:parse_messages(prompt_opts), request_body)
end

---@param usage avante.GeminiTokenUsage | nil
---@return avante.LLMTokenUsage | nil
function M.transform_gemini_usage(usage)
  if not usage then return nil end
  ---@type avante.LLMTokenUsage
  local res = {
    prompt_tokens = usage.promptTokenCount,
    completion_tokens = usage.candidatesTokenCount,
  }
  return res
end

function M:parse_response(ctx, data_stream, _, opts)
  local ok, jsn = pcall(vim.json.decode, data_stream)
  if not ok then
    opts.on_stop({ reason = "error", error = "Failed to parse JSON response: " .. tostring(jsn) })
    return
  end

  if opts.update_tokens_usage and jsn.usageMetadata and jsn.usageMetadata ~= nil then
    local usage = M.transform_gemini_usage(jsn.usageMetadata)
    if usage ~= nil then opts.update_tokens_usage(usage) end
  end

  -- Handle prompt feedback first, as it might indicate an overall issue with the prompt
  if jsn.promptFeedback and jsn.promptFeedback.blockReason then
    local feedback = jsn.promptFeedback
    OpenAI:finish_pending_messages(ctx, opts) -- Ensure any pending messages are cleared
    opts.on_stop({
      reason = "error",
      error = "Prompt blocked or filtered. Reason: " .. feedback.blockReason,
      details = feedback,
    })
    return
  end

  if jsn.candidates and #jsn.candidates > 0 then
    local candidate = jsn.candidates[1]
    ---@type AvanteLLMToolUse[]
    ctx.tool_use_list = ctx.tool_use_list or {}

    -- Check if candidate.content and candidate.content.parts exist before iterating
    if candidate.content and candidate.content.parts then
      for _, part in ipairs(candidate.content.parts) do
        if part.text then
          if opts.on_chunk then opts.on_chunk(part.text) end
          OpenAI:add_text_message(ctx, part.text, "generating", opts)
        elseif part.functionCall then
          if not ctx.function_call_id then ctx.function_call_id = 0 end
          ctx.function_call_id = ctx.function_call_id + 1
          local tool_use = {
            id = ctx.turn_id .. "-" .. tostring(ctx.function_call_id),
            name = part.functionCall.name,
            input_json = vim.json.encode(part.functionCall.args),
          }
          table.insert(ctx.tool_use_list, tool_use)
          OpenAI:add_tool_use_message(ctx, tool_use, "generated", opts)
        end
      end
    end

    -- Check for finishReason to determine if this candidate's stream is done.
    if candidate.finishReason then
      OpenAI:finish_pending_messages(ctx, opts)
      local reason_str = candidate.finishReason
      local stop_details = { finish_reason = reason_str }
      stop_details.usage = M.transform_gemini_usage(jsn.usageMetadata)

      if reason_str == "TOOL_CODE" then
        -- Model indicates a tool-related stop.
        -- The tool_use list is added to the table in llm.lua
        opts.on_stop(vim.tbl_deep_extend("force", { reason = "tool_use" }, stop_details))
      elseif reason_str == "STOP" then
        if ctx.tool_use_list and #ctx.tool_use_list > 0 then
          -- Natural stop, but tools were found in this final chunk.
          opts.on_stop(vim.tbl_deep_extend("force", { reason = "tool_use" }, stop_details))
        else
          -- Natural stop, no tools in this final chunk.
          -- llm.lua will check its accumulated tools if tool_choice was active.
          opts.on_stop(vim.tbl_deep_extend("force", { reason = "complete" }, stop_details))
        end
      elseif reason_str == "MAX_TOKENS" then
        opts.on_stop(vim.tbl_deep_extend("force", { reason = "max_tokens" }, stop_details))
      elseif reason_str == "SAFETY" or reason_str == "RECITATION" then
        opts.on_stop(
          vim.tbl_deep_extend(
            "force",
            { reason = "error", error = "Generation stopped: " .. reason_str },
            stop_details
          )
        )
      else -- OTHER, FINISH_REASON_UNSPECIFIED, or any other unhandled reason.
        opts.on_stop(
          vim.tbl_deep_extend(
            "force",
            { reason = "error", error = "Generation stopped with unhandled reason: " .. reason_str },
            stop_details
          )
        )
      end
    end
    -- If no finishReason, it's an intermediate chunk; do not call on_stop.
  end
end

---@param prompt_opts AvantePromptOptions
---@return AvanteCurlOutput|nil
function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = Providers.parse_config(self)

  local api_key = self:parse_api_key()
  if api_key == nil then
    Utils.error("Gemini: API key is not set. Please set " .. M.api_key_name)
    return nil
  end

  return {
    url = Utils.url_join(provider_conf.endpoint, provider_conf.model .. ":streamGenerateContent?alt=sse"),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    -- In a header rather than the `key` query parameter, which would be visible on curl's command line
    headers = Utils.tbl_override({
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = api_key,
    }, self.extra_headers),
    body = M.prepare_request_body(self, prompt_opts, provider_conf, request_body),
  }
end

return M
