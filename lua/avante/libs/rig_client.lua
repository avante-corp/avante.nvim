---@mod avante-rig-client Rust LLM interface
---
---@brief [[
---
---Avante runs LLM inference through the native Rust module `avante_llm`, backed
---by Rig. This Lua client is the interface between `avante.llm` and that module.
---See https://github.com/0xPlaygrounds/rig.
---
---Rust and Rig handle provider selection, request encoding, HTTP transport,
---and response decoding. This client passes provider configuration, credentials,
---prompts, and tools to Rust, polls normalized stream events on Neovim's main
---loop, and forwards message updates and completion callbacks to Avante. It also
---handles request cancellation and cleanup.
---
---The Lua agent loop builds context, executes tools, and manages UI and history.
---When the model requests tools, Lua records their results and starts the next
---inference request through this client.
---@brief ]]
---@see avante-config

local api = vim.api
local uv = vim.uv or vim.loop

local Utils = require("avante.utils")
local Providers = require("avante.providers")
local StreamAdapter = require("avante.libs.llm_stream_adapter")

local M = {}
-- Bump this whenever a breaking native bridge change is introduced.
local NATIVE_API_VERSION = 2

---@class avante.llm.NativeProviderInput
---@field name string Avante provider identity
---@field dialect? string Rig OpenAI-compatible provider dialect
---@field protocol AvanteNativeLLMProtocol Protocol interpreted by Rust
---@field model string
---@field deployment? string Azure deployment identifier
---@field baseUrl? string
---@field apiKey? string
---@field auth? "bearer"
---@field route? "chat" | "responses"
---@field apiVersion? string
---@field promptCaching boolean
---@field headers table<string, string>
---@field replaceHeaders? boolean
---@field proxy? string
---@field allowInsecure boolean
---@field bedrock? table
---@field vertex? table

---@class avante.llm.NativePromptInput
---@field turnId string
---@field systemPrompt string
---@field messages table[]
---@field imagePaths? string[]
---@field tools table[]
---@field additionalParams table

---@class avante.llm.NativeRequestInput
---@field provider avante.llm.NativeProviderInput
---@field prompt avante.llm.NativePromptInput

local function load_native()
  local ok, native = pcall(require, "avante_llm")
  if not ok then return nil, "Failed to load avante_llm native module: " .. tostring(native) end
  if native.api_version ~= NATIVE_API_VERSION then
    return nil,
      string.format(
        "Incompatible avante_llm native module (expected API %d, got %s); rebuild or reinstall Avante's native libraries",
        NATIVE_API_VERSION,
        tostring(native.api_version or "missing")
      )
  end
  return native
end

local function tool_definitions(tools)
  local definitions = {}
  for _, tool in ipairs(tools or {}) do
    local properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
    definitions[#definitions + 1] = {
      name = tool.name,
      description = tool.get_description and tool.get_description() or tool.description or "",
      parameters = {
        type = "object",
        properties = properties,
        required = required,
        additionalProperties = false,
      },
    }
  end
  return definitions
end

local function bedrock_config(provider, provider_conf)
  local region = provider_conf.aws_region
  if not region or region == "" then
    region = Utils.environment.parse("AWS_REGION") or Utils.environment.parse("AWS_DEFAULT_REGION")
  end

  local access_key_id, secret_access_key, session_token, bearer_token
  local credential = provider.parse_api_key() or Utils.environment.parse("AWS_BEARER_TOKEN_BEDROCK")
  if credential and credential:find(",", 1, true) then
    local parts = vim.split(credential, ",", { plain = true })
    access_key_id, secret_access_key, region, session_token = parts[1], parts[2], parts[3], parts[4]
  elseif credential then
    bearer_token = credential
  end
  return {
    region = region,
    profile = provider_conf.aws_profile,
    endpoint = provider_conf.endpoint,
    accessKeyId = access_key_id,
    secretAccessKey = secret_access_key,
    sessionToken = session_token,
    bearerToken = bearer_token,
  }
end

local function provider_credential(provider, provider_conf, protocol)
  if protocol == "bedrock" or protocol == "vertex" then return nil end
  if protocol == "copilot" then
    local token = provider.get_session_token()
    if token then return token.token, token.endpoints and token.endpoints.api end
    error("Copilot session token is unavailable")
  end
  if not Providers.env.require_api_key(provider_conf) then return nil end
  local credential = provider.parse_api_key()
  if not credential then error("API key is not set for provider: " .. tostring(provider._name)) end
  return credential
end

local function has_pending_tool_result(messages)
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    if message.role == "assistant" then return false end
    local content = message.content
    if type(content) == "table" then
      local items = vim.islist(content) and content or { content }
      for _, item in ipairs(items) do
        if type(item) == "table" and item.type == "tool_result" then return true end
      end
    end
  end
  return false
end

---@param provider AvanteProviderFunctor
---@param prompt_opts AvantePromptOptions
---@param session_ctx? table
---@return avante.llm.NativeRequestInput
function M._build_request(provider, prompt_opts, session_ctx)
  local protocol = provider._protocol or provider._name
  local provider_conf, additional_params = Providers.parse_config(provider)
  local name = provider._name or protocol
  local credential, session_endpoint = provider_credential(provider, provider_conf, protocol)
  local route = nil
  if protocol == "openai" or protocol == "azure" or protocol == "copilot" then
    route = session_ctx and session_ctx.resolved_api_route or nil
    if route == nil then route = Providers.resolve_api_route(provider_conf, prompt_opts, protocol) end
  end
  if
    route == "responses"
    and provider_conf.support_previous_response_id == true
    and session_ctx
    and session_ctx.previous_response_id
    and has_pending_tool_result(prompt_opts.messages)
  then
    additional_params = vim.deepcopy(additional_params)
    additional_params.previous_response_id = session_ctx.previous_response_id
  end
  if protocol == "ollama" then
    local options = additional_params.options
    local keep_alive = additional_params.keep_alive
      or rawget(provider_conf, "keep_alive")
      or (type(options) == "table" and options.keep_alive or nil)
    if keep_alive ~= nil then
      additional_params = vim.deepcopy(additional_params)
      if type(additional_params.options) == "table" then
        additional_params.options.keep_alive = nil
        if vim.tbl_isempty(additional_params.options) then additional_params.options = nil end
      end
      additional_params.keep_alive = keep_alive
    end
  end

  ---@type table<string, string>
  local headers = type(provider.extra_headers) == "function" and {} or Utils.tbl_override({}, provider.extra_headers)
  if vim.tbl_isempty(headers) then headers = vim.empty_dict() end
  local auth = nil
  if protocol == "azure" and provider_conf.entra then auth = "bearer" end

  local tools = {}
  if not provider_conf.disable_tools then tools = tool_definitions(prompt_opts.tools) end
  local deployment = nil
  if protocol == "azure" then
    deployment = provider_conf.deployment
    if not deployment or deployment:match("^%s*$") then error("Azure deployment is not set", 0) end
  end

  local input = {
    provider = {
      name = name,
      dialect = rawget(provider_conf, "dialect"),
      protocol = protocol,
      model = provider_conf.model or deployment,
      deployment = deployment,
      baseUrl = session_endpoint or provider_conf.endpoint,
      apiKey = credential,
      auth = auth,
      route = route,
      apiVersion = rawget(provider_conf, "api_version"),
      promptCaching = provider.support_prompt_caching == true,
      headers = headers,
      proxy = provider_conf.proxy,
      allowInsecure = provider_conf.allow_insecure == true,
      bedrock = protocol == "bedrock" and bedrock_config(provider, provider_conf) or nil,
      vertex = protocol == "vertex" and vim.tbl_extend("force", vim.empty_dict(), {
        projectId = rawget(provider_conf, "project_id") or vim.env.GOOGLE_CLOUD_PROJECT,
        location = rawget(provider_conf, "location") or vim.env.GOOGLE_CLOUD_LOCATION,
      }) or nil,
    },
    prompt = {
      turnId = Utils.uuid(),
      systemPrompt = prompt_opts.system_prompt,
      messages = prompt_opts.messages,
      imagePaths = prompt_opts.image_paths,
      tools = tools,
      additionalParams = vim.tbl_isempty(additional_params) and vim.empty_dict() or additional_params,
    },
  }
  if type(provider.extra_headers) == "function" then
    local native, err = load_native()
    if not native then error(err, 0) end
    input.provider.headers = Utils.tbl_override(native.request_headers(input), provider.extra_headers)
    if vim.tbl_isempty(input.provider.headers) then input.provider.headers = vim.empty_dict() end
    input.provider.replaceHeaders = true
  end
  return input
end

---@param provider AvanteProviderFunctor
---@param prompt_opts AvantePromptOptions
---@param handler_opts AvanteHandlerOptions
---@param on_response_headers? fun(headers: table)
---@param session_ctx? table
---@return table|nil
local function start_request(provider, prompt_opts, handler_opts, on_response_headers, session_ctx)
  local request_ok, request_config = pcall(M._build_request, provider, prompt_opts, session_ctx)
  if not request_ok then
    handler_opts.on_stop({ reason = "error", error = tostring(request_config) })
    return
  end
  local native, native_error = load_native()
  if not native then
    handler_opts.on_stop({ reason = "error", error = native_error })
    return
  end
  local ok, request = pcall(native.start, request_config)
  if not ok then
    handler_opts.on_stop({ reason = "error", error = tostring(request) })
    return
  end

  local ctx = { turn_id = request_config.prompt.turnId, parts = {}, part_map = {} }
  local provider_conf = Providers.parse_config(provider)
  local supports_previous_response_id = request_config.provider.route == "responses"
    and provider_conf.support_previous_response_id == true
  local timer = uv.new_timer()
  if not timer then
    request:cancel()
    handler_opts.on_stop({ reason = "error", error = "Failed to create LLM event timer" })
    return nil
  end
  local terminal = false
  local stop_notified = false
  local autocmd

  local function notify_stop(result)
    if stop_notified then return end
    stop_notified = true
    local ok, err = pcall(handler_opts.on_stop, result)
    if not ok then Utils.error("LLM stop callback failed: " .. tostring(err)) end
  end

  local function cleanup()
    if terminal then return end
    terminal = true
    timer:stop()
    if not timer:is_closing() then timer:close() end
    if autocmd then pcall(api.nvim_del_autocmd, autocmd) end
  end

  local function cancel()
    if terminal then return end
    cleanup()
    pcall(request.cancel, request)
    notify_stop({ reason = "cancelled" })
  end

  local function close_reasoning()
    if not ctx.thinking then return end
    ctx.thinking = false
    if handler_opts.on_chunk then
      local prefix = ctx.last_think_content and ctx.last_think_content:sub(-1) ~= "\n" and "\n" or ""
      handler_opts.on_chunk(prefix .. "</think>\n")
    end
  end

  local function fail_contract(message)
    pcall(request.cancel, request)
    cleanup()
    notify_stop({ reason = "error", error = message })
  end

  local function finish(event)
    local reason = event.reason == "length" and "max_tokens" or event.reason
    cleanup()
    close_reasoning()
    StreamAdapter.finish_pending_messages(ctx.parts, handler_opts, reason == "tool_use", event.origin)
    if supports_previous_response_id and session_ctx then
      session_ctx.previous_response_id = reason == "tool_use" and event.responseId or nil
    end
    notify_stop({
      reason = reason,
      usage = event.usage,
    })
  end

  local function handle(event)
    if terminal then return end
    if event.type == "content_start" then
      close_reasoning()
      local content
      if event.kind == "text" then
        content = ""
      elseif event.kind == "reasoning" then
        content = { type = "thinking", thinking = "", signature = "" }
      else
        content = { type = "tool_use", name = event.name, id = "", input = vim.empty_dict() }
      end
      local key = tostring(event.index)
      if ctx.part_map[key] then return fail_contract("Duplicate content start from avante_llm native module") end
      local part = { content = content, turn_id = ctx.turn_id }
      ctx.part_map[key] = part
      ctx.parts[#ctx.parts + 1] = part
      StreamAdapter.add_message(part, "generating", handler_opts)
    elseif event.type == "content_delta" then
      local part = ctx.part_map[tostring(event.index)]
      if not part then return fail_contract("Content delta without a start from avante_llm native module") end
      if event.kind == "reasoning" then
        if not ctx.thinking then
          ctx.thinking = true
          if handler_opts.on_chunk then handler_opts.on_chunk("<think>\n") end
        end
        ctx.last_think_content = event.text
        part.content = vim.tbl_extend("force", part.content, { thinking = part.content.thinking .. event.text })
      else
        close_reasoning()
        part.content = part.content .. event.text
      end
      StreamAdapter.add_message(part, "generating", handler_opts)
      if handler_opts.on_chunk then handler_opts.on_chunk(event.text) end
    elseif event.type == "tool_call_delta" then
      local part = ctx.part_map[tostring(event.index)]
      if not part then return fail_contract("Tool call delta without a start from avante_llm native module") end
      part.content = vim.tbl_extend("force", part.content, { input = event.arguments })
      StreamAdapter.add_message(part, "generating", handler_opts)
      handler_opts.on_stop({ reason = "tool_use", streaming_tool_use = true })
    elseif event.type == "content_end" then
      local part = ctx.part_map[tostring(event.index)]
      if not part then return fail_contract("Content end without a start from avante_llm native module") end
      close_reasoning()
      part.content = event.content
      part.native = event.native
      part.order = event.order
      StreamAdapter.add_message(part, "generating", handler_opts)
    elseif event.type == "response_headers" then
      if on_response_headers then on_response_headers(event.headers) end
    elseif event.type == "done" then
      finish(event)
    elseif event.type == "cancelled" then
      cleanup()
      notify_stop({ reason = "cancelled" })
    elseif event.type == "error" then
      cleanup()
      if event.status == 429 then
        notify_stop({ reason = "rate_limit", retry_after = event.retryAfter or 10 })
      else
        notify_stop({ reason = "error", error = event.message })
      end
    else
      fail_contract("Unsupported avante_llm event type: " .. event.type)
    end
  end

  timer:start(
    0,
    10,
    vim.schedule_wrap(function()
      if terminal then return end
      local polled, events = pcall(request.poll, request)
      if not polled then return fail_contract(tostring(events)) end
      for _, event in ipairs(events) do
        local handled, err = pcall(handle, event)
        if not handled then return fail_contract(tostring(err)) end
      end
    end)
  )

  autocmd = api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("avante_llm", { clear = false }),
    pattern = "AvanteLLMEscape",
    once = true,
    callback = cancel,
  })
  return { cancel = cancel }
end

---@param provider AvanteProviderFunctor
---@param prompt_opts AvantePromptOptions
---@param handler_opts AvanteHandlerOptions
---@param on_response_headers? fun(headers: table)
---@param session_ctx? table
---@return table|nil
function M.start(provider, prompt_opts, handler_opts, on_response_headers, session_ctx)
  if (provider._protocol or provider._name) ~= "copilot" then
    return start_request(provider, prompt_opts, handler_opts, on_response_headers, session_ctx)
  end

  local request, autocmd
  local waiting = true
  local function finish_waiting()
    if not waiting then return false end
    waiting = false
    pcall(api.nvim_del_autocmd, autocmd)
    return true
  end
  local function cancel()
    if request then
      request:cancel()
    elseif finish_waiting() then
      handler_opts.on_stop({ reason = "cancelled" })
    end
  end
  autocmd = api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("avante_llm", { clear = false }),
    pattern = "AvanteLLMEscape",
    once = true,
    callback = cancel,
  })
  local function authenticated(err)
    if not finish_waiting() then return end
    if err then
      handler_opts.on_stop({ reason = "error", error = tostring(err) })
      return
    end
    request = start_request(provider, prompt_opts, handler_opts, on_response_headers, session_ctx)
  end
  local ok, err = pcall(provider.get_session_token, authenticated)
  if not ok then authenticated(err) end
  return request or { cancel = cancel }
end

return M
