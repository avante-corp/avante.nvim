local api = vim.api
local fn = vim.fn
local uv = vim.uv

local curl = require("plenary.curl")
local ACPClient = require("avante.libs.acp_client")

local Utils = require("avante.utils")
local Prompts = require("avante.utils.prompts")
local Config = require("avante.config")
local Path = require("avante.path")
local Providers = require("avante.providers")
local LLMToolHelpers = require("avante.llm_tools.helpers")
local LLMTools = require("avante.llm_tools")
local History = require("avante.history")
local HistoryRender = require("avante.history.render")
local ACPConfirmAdapter = require("avante.ui.acp_confirm_adapter")
local log = require("avante.utils.log")

---@class avante.LLM
local M = {}

M.CANCEL_PATTERN = "AvanteLLMEscape"

------------------------------Prompt and type------------------------------

local group = api.nvim_create_augroup("avante_llm", { clear = true })

---@param prev_memory string | nil
---@param history_messages avante.HistoryMessage[]
---@param cb fun(memory: avante.ChatMemory | nil): nil
function M.summarize_memory(prev_memory, history_messages, cb)
  local system_prompt =
    [[You are an expert coding assistant. Your goal is to generate a concise, structured summary of the conversation below that captures all essential information needed to continue development after context replacement. Include tasks performed, code areas modified or reviewed, key decisions or assumptions, test results or errors, and outstanding tasks or next steps.]]
  if #history_messages == 0 then
    cb(nil)
    return
  end
  local latest_timestamp = nil
  local latest_message_uuid = nil
  for idx = #history_messages, 1, -1 do
    local message = history_messages[idx]
    if not message.is_dummy then
      latest_timestamp = message.timestamp
      latest_message_uuid = message.uuid
      break
    end
  end
  if not latest_timestamp or not latest_message_uuid then
    cb(nil)
    return
  end
  local conversation_items = vim
    .iter(history_messages)
    :map(function(msg) return msg.message.role .. ": " .. HistoryRender.message_to_text(msg, history_messages) end)
    :totable()
  local conversation_text = table.concat(conversation_items, "\n")
  local user_prompt = "Here is the conversation so far:\n"
    .. conversation_text
    .. "\n\nPlease summarize this conversation, covering:\n1. Tasks performed and outcomes\n2. Code files, modules, or functions modified or examined\n3. Important decisions or assumptions made\n4. Errors encountered and test or build results\n5. Remaining tasks, open questions, or next steps\nProvide the summary in a clear, concise format."
  if prev_memory then user_prompt = user_prompt .. "\n\nThe previous summary is:\n\n" .. prev_memory end
  local messages = {
    {
      role = "user",
      content = user_prompt,
    },
  }
  local response_content = ""
  local provider = Providers.get_memory_summary_provider()
  M.curl({
    provider = provider,
    prompt_opts = {
      system_prompt = system_prompt,
      messages = messages,
    },
    handler_opts = {
      on_start = function(_) end,
      on_chunk = function(chunk)
        if not chunk then return end
        response_content = response_content .. chunk
      end,
      on_stop = function(stop_opts)
        if stop_opts.error ~= nil then
          Utils.error(string.format("summarize memory failed: %s", vim.inspect(stop_opts.error)))
          return
        end
        if stop_opts.reason == "complete" then
          response_content = Utils.trim_think_content(response_content)
          local memory = {
            content = response_content,
            last_summarized_timestamp = latest_timestamp,
            last_message_uuid = latest_message_uuid,
          }
          cb(memory)
        else
          cb(nil)
        end
      end,
    },
  })
end

---@param user_input string
---@param cb fun(error: string | nil): nil
function M.generate_todos(user_input, cb)
  local system_prompt =
    [[You are an expert coding assistant. Please generate a todo list to complete the task based on the user input and pass the todo list to the write_todos tool.]]
  local messages = {
    { role = "user", content = user_input },
  }

  local provider = Providers[Config.provider]
  local tools = {
    require("avante.llm_tools.write_todos"),
  }

  local history_messages = {}
  cb = Utils.call_once(cb)

  M.curl({
    provider = provider,
    prompt_opts = {
      system_prompt = system_prompt,
      messages = messages,
      tools = tools,
    },
    handler_opts = {
      on_start = function() end,
      on_chunk = function() end,
      on_messages_add = function(msgs)
        msgs = vim.islist(msgs) and msgs or { msgs }
        for _, msg in ipairs(msgs) do
          if not msg.uuid then msg.uuid = Utils.uuid() end
          local idx = nil
          for i, m in ipairs(history_messages) do
            if m.uuid == msg.uuid then
              idx = i
              break
            end
          end
          if idx ~= nil then
            history_messages[idx] = msg
          else
            table.insert(history_messages, msg)
          end
        end
      end,
      on_stop = function(stop_opts)
        if stop_opts.error ~= nil then
          Utils.error(string.format("generate todos failed: %s", vim.inspect(stop_opts.error)))
          return
        end
        if stop_opts.reason == "tool_use" then
          local pending_tools = History.get_pending_tools(history_messages)
          for _, pending_tool in ipairs(pending_tools) do
            if pending_tool.state == "generated" and pending_tool.name == "write_todos" then
              local result = LLMTools.process_tool_use(tools, pending_tool, {
                session_ctx = {},
                on_complete = function() cb() end,
                tool_use_id = pending_tool.id,
              })
              if result ~= nil then cb() end
            end
          end
        else
          cb()
        end
      end,
    },
  })
end

---@class avante.AgentLoopOptions
---@field system_prompt string
---@field user_input string
---@field tools AvanteLLMTool[]
---@field on_complete fun(error: string | nil): nil
---@field session_ctx? table
---@field on_tool_log? fun(tool_id: string, tool_name: string, log: string, state: AvanteLLMToolUseState): nil
---@field on_start? fun(): nil
---@field on_chunk? fun(chunk: string): nil
---@field on_messages_add? fun(messages: avante.HistoryMessage[]): nil

---@param opts avante.AgentLoopOptions
function M.agent_loop(opts)
  local messages = {}
  table.insert(messages, { role = "user", content = "<task>" .. opts.user_input .. "</task>" })

  local memory_content = nil
  local history_messages = {}
  local function no_op() end
  local session_ctx = opts.session_ctx or {}

  local stream_options = {
    ask = true,
    memory = memory_content,
    code_lang = "unknown",
    provider = Providers[Config.provider],
    get_history_messages = function() return history_messages end,
    on_tool_log = opts.on_tool_log or no_op,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        local idx = nil
        for i, m in ipairs(history_messages) do
          if m.uuid == msg.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = msg
        else
          table.insert(history_messages, msg)
        end
      end
      if opts.on_messages_add then opts.on_messages_add(msgs) end
    end,
    session_ctx = session_ctx,
    prompt_opts = {
      system_prompt = opts.system_prompt,
      tools = opts.tools,
      messages = messages,
    },
    on_start = opts.on_start or no_op,
    on_chunk = opts.on_chunk or no_op,
    on_stop = function(stop_opts)
      if stop_opts.error ~= nil then
        local err = string.format("dispatch_agent failed: %s", vim.inspect(stop_opts.error))
        opts.on_complete(err)
        return
      end
      opts.on_complete(nil)
    end,
  }

  local function on_memory_summarize(pending_compaction_history_messages)
    local compaction_history_message_uuids = {}
    for _, msg in ipairs(pending_compaction_history_messages or {}) do
      compaction_history_message_uuids[msg.uuid] = true
    end
    M.summarize_memory(memory_content, pending_compaction_history_messages or {}, function(memory)
      if memory then stream_options.memory = memory.content end
      local new_history_messages = {}
      for _, msg in ipairs(history_messages) do
        if not compaction_history_message_uuids[msg.uuid] then table.insert(new_history_messages, msg) end
      end
      history_messages = new_history_messages
      M._stream(stream_options)
    end)
  end

  stream_options.on_memory_summarize = on_memory_summarize

  M._stream(stream_options)
end

--- Loads prompt from various locations (avante.md, )
---@param opts AvanteGeneratePromptsOptions
---@return AvantePromptOptions
function M.generate_prompts(opts)
  local project_instruction_file = Config.instructions_file or "avante.md"
  local project_root = tostring(Utils.root.get())
  local instruction_file_path = vim.fs.joinpath(project_root, project_instruction_file)

  if vim.uv.fs_stat(instruction_file_path) and not opts._instructions_loaded then
    log.info("Loading instructions from " .. instruction_file_path)
    local lines = Utils.read_file_from_buf_or_disk(vim.fs.abspath(instruction_file_path))
    local instruction_content = lines and table.concat(lines, "\n") or ""

    opts.instructions = (opts.instructions or "") .. "\n" .. instruction_content
    opts._instructions_loaded = true
  end

  local mode = opts.mode or Config.mode

  -- Check if the instructions contains an image path
  local image_paths = {}
  if opts.prompt_opts and opts.prompt_opts.image_paths then
    image_paths = vim.list_extend(image_paths, opts.prompt_opts.image_paths)
  end

  Path.prompts.initialize(Path.prompts.get_templates_dir(project_root), project_root)

  local system_info = Utils.get_system_info()

  local selected_files = opts.selected_files or {}
  if opts.selected_filepaths then
    for _, filepath in ipairs(opts.selected_filepaths) do
      local lines, error = Utils.read_file_from_buf_or_disk(filepath)
      if error ~= nil then
        Utils.error("error reading file: " .. error)
      else
        local content = table.concat(lines or {}, "\n")
        local filetype = Utils.get_filetype(filepath)
        table.insert(selected_files, { path = filepath, content = content, file_type = filetype })
      end
    end
  end

  local viewed_files = {}
  if opts.history_messages then
    for _, message in ipairs(opts.history_messages) do
      local use = History.Helpers.get_tool_use_data(message)
      if use and use.name == "view" and use.input.path then
        local uniform_path = Utils.uniform_path(use.input.path)
        viewed_files[uniform_path] = use.id
      end
    end
  end

  selected_files = vim.iter(selected_files):filter(function(file) return viewed_files[file.path] == nil end):totable()

  local is_acp_provider = false
  if not opts.provider then is_acp_provider = Config.acp_providers[Config.provider] ~= nil end
  local model_name = "unknown"
  local context_window = nil
  local use_react_prompt = false
  if not is_acp_provider then
    local provider = opts.provider or Providers[Config.provider]
    model_name = provider.model or "unknown"
    local provider_conf = Providers.parse_config(provider)
    use_react_prompt = provider_conf.use_ReAct_prompt
    context_window = provider.context_window
  end

  local template_opts = {
    ask = opts.ask, -- TODO: add mode without ask instruction
    code_lang = opts.code_lang,
    selected_files = selected_files,
    selected_code = opts.selected_code,
    recently_viewed_files = opts.recently_viewed_files,
    project_context = opts.project_context,
    diagnostics = opts.diagnostics,
    system_info = system_info,
    model_name = model_name,
    memory = opts.memory,
    enable_fastapply = Config.behaviour.enable_fastapply,
    use_react_prompt = use_react_prompt,
  }

  -- Removed the original todos processing logic, now handled in context_messages

  local system_prompt
  if opts.prompt_opts and opts.prompt_opts.system_prompt then
    system_prompt = opts.prompt_opts.system_prompt
  else
    system_prompt = Path.prompts.render_mode(mode, template_opts)
  end

  if Config.system_prompt ~= nil then
    local custom_system_prompt
    if type(Config.system_prompt) == "function" then custom_system_prompt = Config.system_prompt() end
    if type(Config.system_prompt) == "string" then custom_system_prompt = Config.system_prompt end
    if custom_system_prompt ~= nil and custom_system_prompt ~= "" and custom_system_prompt ~= "null" then
      system_prompt = system_prompt .. "\n\n" .. custom_system_prompt
    end
  end

  ---@type AvanteLLMMessage[]
  local context_messages = {}
  if opts.prompt_opts and opts.prompt_opts.messages then
    context_messages = vim.list_extend(context_messages, opts.prompt_opts.messages)
  end

  if opts.project_context ~= nil and opts.project_context ~= "" and opts.project_context ~= "null" then
    local project_context = Path.prompts.render_file("_project.avanterules", template_opts)
    if project_context ~= "" then
      table.insert(context_messages, { role = "user", content = project_context, visible = false, is_context = true })
    end
  end

  if opts.diagnostics ~= nil and opts.diagnostics ~= "" and opts.diagnostics ~= "null" then
    local diagnostics = Path.prompts.render_file("_diagnostics.avanterules", template_opts)
    if diagnostics ~= "" then
      table.insert(context_messages, { role = "user", content = diagnostics, visible = false, is_context = true })
    end
  end

  if #selected_files > 0 or opts.selected_code ~= nil then
    local code_context = Path.prompts.render_file("_context.avanterules", template_opts)
    if code_context ~= "" then
      table.insert(context_messages, { role = "user", content = code_context, visible = false, is_context = true })
    end
  end

  if opts.memory ~= nil and opts.memory ~= "" and opts.memory ~= "null" then
    local memory = Path.prompts.render_file("_memory.avanterules", template_opts)
    if memory ~= "" then
      table.insert(context_messages, { role = "user", content = memory, visible = false, is_context = true })
    end
  end

  local pending_compaction_history_messages = {}
  if opts.prompt_opts and opts.prompt_opts.pending_compaction_history_messages then
    pending_compaction_history_messages =
      vim.list_extend(pending_compaction_history_messages, opts.prompt_opts.pending_compaction_history_messages)
  end

  if context_window and context_window > 0 then
    Utils.debug("Context window", context_window)
    if opts.get_tokens_usage then
      local tokens_usage = opts.get_tokens_usage()
      if tokens_usage and tokens_usage.prompt_tokens ~= nil and tokens_usage.completion_tokens ~= nil then
        local target_tokens = context_window * 0.9
        local tokens_count = tokens_usage.prompt_tokens + tokens_usage.completion_tokens
        Utils.debug("Tokens count", tokens_count)
        if tokens_count > target_tokens then pending_compaction_history_messages = opts.history_messages end
      end
    end
  end

  ---@type AvanteLLMMessage[]
  local messages = vim.deepcopy(context_messages)
  for _, msg in ipairs(opts.history_messages or {}) do
    local message = msg.message
    if msg.is_user_submission then
      message = vim.deepcopy(message)
      local content = message.content
      if Config.mode == "agentic" then
        if type(content) == "string" then
          message.content = "<task>" .. content .. "</task>"
        elseif type(content) == "table" then
          for idx, item in ipairs(content) do
            if type(item) == "string" then
              item = "<task>" .. item .. "</task>"
              content[idx] = item
            elseif type(item) == "table" and item.type == "text" then
              item.content = "<task>" .. item.content .. "</task>"
              content[idx] = item
            end
          end
        end
      end
    end
    table.insert(messages, message)
  end

  messages = vim
    .iter(messages)
    :filter(function(msg) return type(msg.content) ~= "string" or msg.content ~= "" end)
    :totable()

  if opts.instructions ~= nil and opts.instructions ~= "" then
    messages = vim.list_extend(messages, { { role = "user", content = opts.instructions } })
  end

  opts.session_ctx = opts.session_ctx or {}
  opts.session_ctx.system_prompt = system_prompt
  opts.session_ctx.messages = messages

  local tools = {}
  if opts.tools then tools = vim.list_extend(tools, opts.tools) end
  if opts.prompt_opts and opts.prompt_opts.tools then tools = vim.list_extend(tools, opts.prompt_opts.tools) end

  -- Set tools to nil if empty to avoid sending empty arrays to APIs that require
  -- tools to be either non-existent or have at least one item
  if #tools == 0 then tools = nil end

  local agents_rules = Prompts.get_agents_rules_prompt()
  if agents_rules then system_prompt = system_prompt .. "\n\n" .. agents_rules end
  local cursor_rules = Prompts.get_cursor_rules_prompt(selected_files)
  if cursor_rules then system_prompt = system_prompt .. "\n\n" .. cursor_rules end

  ---@type AvantePromptOptions
  return {
    system_prompt = system_prompt,
    messages = messages,
    image_paths = image_paths,
    tools = tools,
    pending_compaction_history_messages = pending_compaction_history_messages,
  }
end

---@param opts AvanteGeneratePromptsOptions
---@return integer
function M.calculate_tokens(opts)
  if Config.acp_providers[Config.provider] then return 0 end
  local prompt_opts = M.generate_prompts(opts)
  local tokens = Utils.tokens.calculate_tokens(prompt_opts.system_prompt)
  for _, message in ipairs(prompt_opts.messages) do
    tokens = tokens + Utils.tokens.calculate_tokens(message.content)
  end
  return tokens
end

local parse_headers = function(headers_file)
  local headers = {}
  local file = io.open(headers_file, "r")
  if file then
    for line in file:lines() do
      local linep = line:gsub("\r$", "")
      local key, value = linep:match("^%s*(.-)%s*:%s*(.*)$")
      if key and value then headers[key] = value end
    end
    if Config.debug then
      -- Original header file was deleted by plenary.nvim
      -- see https://github.com/nvim-lua/plenary.nvim/blob/b9fd5226c2f76c951fc8ed5923d85e4de065e509/lua/plenary/curl.lua#L268
      local debug_headers_file = headers_file .. ".log"
      Utils.debug("curl response headers file:", debug_headers_file)
      local debug_file = io.open(debug_headers_file, "a")
      if debug_file then
        file:seek("set")
        debug_file:write(file:read("*all"))
        debug_file:close()
      end
    end
    file:close()
  end
  return headers
end

---@param opts avante.CurlOpts
function M.curl(opts)
  local provider = opts.provider
  local prompt_opts = opts.prompt_opts
  local handler_opts = opts.handler_opts

  local orig_on_stop = handler_opts.on_stop
  local stopped = false
  ---@param stop_opts AvanteLLMStopCallbackOptions
  handler_opts.on_stop = function(stop_opts)
    if stop_opts and not stop_opts.streaming_tool_use then
      if stopped then return end
      stopped = true
    end
    if orig_on_stop then return orig_on_stop(stop_opts) end
  end

  local spec = provider:parse_curl_args(prompt_opts)
  if not spec then
    handler_opts.on_stop({ reason = "error", error = "Provider configuration error" })
    return
  end

  ---@type string?
  local current_event_state = nil
  local turn_ctx = {}
  turn_ctx.turn_id = Utils.uuid()

  local response_body = ""
  ---@param line string
  local function parse_stream_data(line)
    local event = line:match("^event:%s*(.+)$")
    if event then
      current_event_state = event
      return
    end
    local data_match = line:match("^data:%s*(.+)$")
    if data_match then
      response_body = ""
      provider:parse_response(turn_ctx, data_match, current_event_state, handler_opts)
    else
      response_body = response_body .. line
      local ok, jsn = pcall(vim.json.decode, response_body)
      if ok then
        if jsn.error then
          handler_opts.on_stop({ reason = "error", error = jsn.error })
        else
          provider:parse_response(turn_ctx, response_body, current_event_state, handler_opts)
        end
        response_body = ""
      end
    end
  end

  local function parse_response_without_stream(data)
    provider:parse_response_without_stream(data, current_event_state, handler_opts)
  end

  local completed = false

  local active_job ---@type Job|nil

  local temp_file = fn.tempname()
  local curl_body_file = temp_file .. "-request-body.json"
  local resp_body_file = temp_file .. "-response-body.txt"
  local headers_file = temp_file .. "-response-headers.txt"

  -- Check if this is a multipart form request (specifically for watsonx)
  local is_multipart_form = spec.headers and spec.headers["Content-Type"] == "multipart/form-data"
  local curl_options

  if is_multipart_form then
    -- For multipart form data, use the form parameter
    -- spec.body should be a table with form field data
    curl_options = {
      headers = spec.headers,
      proxy = spec.proxy,
      insecure = spec.insecure,
      form = spec.body,
      raw = spec.rawArgs,
    }
  else
    -- For regular JSON requests, encode as JSON and write to file
    local json_content = vim.json.encode(spec.body)
    fn.writefile(vim.split(json_content, "\n"), curl_body_file)
    curl_options = {
      headers = spec.headers,
      proxy = spec.proxy,
      insecure = spec.insecure,
      body = curl_body_file,
      raw = spec.rawArgs,
    }
  end

  Utils.debug("curl request body file:", curl_body_file)
  Utils.debug("curl response body file:", resp_body_file)

  local function cleanup()
    if Config.debug then return end
    vim.schedule(function()
      fn.delete(curl_body_file)
      pcall(fn.delete, resp_body_file)
    end)
  end

  local headers_reported = false

  local started_job, new_active_job = pcall(
    curl.post,
    spec.url,
    vim.tbl_extend("force", curl_options, {
      dump = { "-D", headers_file },
      stream = function(err, data, _)
        if not headers_reported and opts.on_response_headers then
          headers_reported = true
          opts.on_response_headers(parse_headers(headers_file))
        end
        if err then
          completed = true
          handler_opts.on_stop({ reason = "error", error = err })
          return
        end
        if not data then return end
        if Config.debug then
          if type(data) == "string" then
            local file = io.open(resp_body_file, "a")
            if file then
              file:write(data .. "\n")
              file:close()
            end
          end
        end
        vim.schedule(function()
          if provider.parse_stream_data ~= nil then
            provider:parse_stream_data(turn_ctx, data, handler_opts)
          else
            parse_stream_data(data)
          end
        end)
      end,
      on_error = function(err)
        if err.exit == 23 then
          local xdg_runtime_dir = os.getenv("XDG_RUNTIME_DIR")
          if not xdg_runtime_dir or fn.isdirectory(xdg_runtime_dir) == 0 then
            Utils.error(
              "$XDG_RUNTIME_DIR="
                .. xdg_runtime_dir
                .. " is set but does not exist. curl could not write output. Please make sure it exists, or unset.",
              { title = "Avante" }
            )
          elseif not uv.fs_access(xdg_runtime_dir, "w") then
            Utils.error(
              "$XDG_RUNTIME_DIR="
                .. xdg_runtime_dir
                .. " exists but is not writable. curl could not write output. Please make sure it is writable, or unset.",
              { title = "Avante" }
            )
          end
        end

        active_job = nil
        if not completed then
          completed = true
          cleanup()
          handler_opts.on_stop({ reason = "error", error = err })
        end
      end,
      callback = function(result)
        active_job = nil
        cleanup()
        local headers_map = vim.iter(result.headers):fold({}, function(acc, value)
          local pieces = vim.split(value, ":")
          local key = pieces[1]
          local remain = vim.list_slice(pieces, 2)
          if not remain then return acc end
          local val = Utils.trim_spaces(table.concat(remain, ":"))
          acc[key] = val
          return acc
        end)
        if result.status >= 400 then
          if provider.on_error then
            provider.on_error(result)
          else
            Utils.error("API request failed with status " .. result.status, { once = true, title = "Avante" })
          end
          local retry_after = 10
          if headers_map["retry-after"] then retry_after = tonumber(headers_map["retry-after"]) or 10 end
          if result.status == 429 then
            handler_opts.on_stop({ reason = "rate_limit", retry_after = retry_after })
            return
          end
          vim.schedule(function()
            if not completed then
              completed = true
              local error_msg = "API request failed with status " .. result.status
              if result.status == 404 then error_msg = error_msg .. " (" .. spec.url .. ")" end
              handler_opts.on_stop({
                reason = "error",
                error = error_msg .. ". Body:\n" .. vim.inspect(result.body),
              })
            end
          end)
        end

        -- If stream is not enabled, then handle the response here
        if provider:is_disable_stream() and result.status == 200 then
          vim.schedule(function()
            completed = true
            parse_response_without_stream(result.body)
          end)
        end

        if result.status == 200 and spec.url:match("https://openrouter.ai") then
          local content_type = headers_map["content-type"]
          if content_type and content_type:match("text/html") then
            handler_opts.on_stop({
              reason = "error",
              error = "Your openrouter endpoint setting is incorrect, please set it to https://openrouter.ai/api/v1",
            })
          end
        end
      end,
    })
  )

  if not started_job then
    local error_msg = vim.inspect(new_active_job)
    Utils.error("Failed to make LLM request: " .. error_msg)
    handler_opts.on_stop({ reason = "error", error = error_msg })
    return
  end
  active_job = new_active_job

  api.nvim_create_autocmd("User", {
    group = group,
    pattern = M.CANCEL_PATTERN,
    once = true,
    callback = function()
      -- Error: cannot resume dead coroutine
      if active_job then
        -- Mark as completed first to prevent error handler from running
        completed = true

        -- 检查 active_job 的状态
        local job_is_alive = pcall(function() return active_job:is_closing() == false end)

        -- 只有当 job 仍然活跃时才尝试关闭它
        if job_is_alive then
          -- Attempt to shutdown the active job, but ignore any errors
          xpcall(function() active_job:shutdown() end, function(err)
            Utils.debug("Ignored error during job shutdown: " .. vim.inspect(err))
            return err
          end)
        else
          Utils.debug("Job already closed, skipping shutdown")
        end

        Utils.debug("LLM request cancelled")
        active_job = nil

        -- Clean up and notify of cancellation
        cleanup()
        vim.schedule(function() handler_opts.on_stop({ reason = "cancelled" }) end)
      end
    end,
  })

  return active_job
end

local retry_timer = nil
local abort_retry_timer = false
local function stop_retry_timer()
  if retry_timer then
    retry_timer:stop()
    pcall(function() retry_timer:close() end)
    retry_timer = nil
  end
end

-- Intelligently truncate chat history for session recovery to avoid token limits
---@param history_messages table[]
---@return table[]
local function truncate_history_for_recovery(history_messages)
  if not history_messages or #history_messages == 0 then return {} end

  -- Get configuration parameters with validation and sensible defaults
  local recovery_config = Config.session_recovery or {}
  local MAX_RECOVERY_MESSAGES = math.max(1, math.min(recovery_config.max_history_messages or 20, 50)) -- Increased from 10 to 20
  local MAX_MESSAGE_LENGTH = math.max(100, math.min(recovery_config.max_message_length or 1000, 10000))

  -- Keep recent messages starting from the newest
  local truncated = {}
  local count = 0

  -- CRITICAL: For session recovery, prioritize keeping conversation pairs (user+assistant)
  -- This preserves the full context of recent interactions
  local conversation_pairs = {}
  local last_user_message = nil

  for i = #history_messages, 1, -1 do
    local message = history_messages[i]
    if message and message.message and message.message.content then
      local role = message.message.role

      -- Build conversation pairs for better context preservation
      if role == "user" then
        last_user_message = message
      elseif role == "assistant" and last_user_message then
        -- Found a complete conversation pair
        table.insert(conversation_pairs, 1, { user = last_user_message, assistant = message })
        last_user_message = nil
      end
    end
  end

  -- Add complete conversation pairs first (better context preservation)
  for _, pair in ipairs(conversation_pairs) do
    if count >= MAX_RECOVERY_MESSAGES then break end

    -- Add user message
    table.insert(truncated, 1, pair.user)
    count = count + 1

    if count < MAX_RECOVERY_MESSAGES then
      -- Add assistant response
      table.insert(truncated, 1, pair.assistant)
      count = count + 1
    end
  end

  -- Add remaining individual messages if space allows
  for i = #history_messages, 1, -1 do
    if count >= MAX_RECOVERY_MESSAGES then break end

    local message = history_messages[i]
    if message and message.message and message.message.content then
      -- Skip if already added as part of conversation pair
      local already_added = false
      for _, added_msg in ipairs(truncated) do
        if added_msg.uuid == message.uuid then
          already_added = true
          break
        end
      end

      if not already_added then
        -- Prioritize user messages and important assistant replies, skip verbose tool call results
        local content = message.message.content
        local role = message.message.role

        -- Skip overly verbose tool call results with multiple code blocks
        if
          role == "assistant"
          and type(content) == "string"
          and content:match("```.*```.*```")
          and #content > MAX_MESSAGE_LENGTH * 2
        then
          goto continue
        end

        -- Handle string content
        if type(content) == "string" then
          if #content > MAX_MESSAGE_LENGTH then
            -- Truncate overly long messages
            local truncated_message = vim.deepcopy(message)
            truncated_message.message.content = content:sub(1, MAX_MESSAGE_LENGTH) .. "...[truncated]"
            table.insert(truncated, 1, truncated_message)
          else
            table.insert(truncated, 1, message)
          end
        -- Handle table content (multimodal messages)
        elseif type(content) == "table" then
          local truncated_message = vim.deepcopy(message)
          -- Safely handle table content
          if truncated_message.message.content and type(truncated_message.message.content) == "table" then
            for j, item in ipairs(truncated_message.message.content) do
              -- Handle various content item types
              if type(item) == "string" and #item > MAX_MESSAGE_LENGTH then
                truncated_message.message.content[j] = item:sub(1, MAX_MESSAGE_LENGTH) .. "...[truncated]"
              elseif
                type(item) == "table"
                and item.text
                and type(item.text) == "string"
                and #item.text > MAX_MESSAGE_LENGTH
              then
                -- Handle {type="text", text="..."} format
                item.text = item.text:sub(1, MAX_MESSAGE_LENGTH) .. "...[truncated]"
              end
            end
          end
          table.insert(truncated, 1, truncated_message)
        else
          table.insert(truncated, 1, message)
        end

        count = count + 1
      end
    end

    ::continue::
  end

  return truncated
end
---@param opts AvanteLLMStreamOptions
function M._stream_acp(opts)
  Utils.debug("use ACP", Config.provider)
  ---@type table<string, avante.HistoryMessage>
  local tool_call_messages = {}
  ---@type avante.HistoryMessage?
  local last_tool_call_message = nil
  local acp_provider = Config.acp_providers[Config.provider]
  local prev_text_message_content = ""
  local history_messages = {}
  local get_history_messages = function()
    if opts.get_history_messages then return opts.get_history_messages() end
    return history_messages
  end
  local on_messages_add = function(messages)
    if opts.on_chunk then
      for _, message in ipairs(messages) do
        if message.message.role == "assistant" and type(message.message.content) == "string" then
          local chunk = message.message.content:sub(#prev_text_message_content + 1)
          opts.on_chunk(chunk)
          prev_text_message_content = message.message.content
        end
      end
    end
    if opts.on_messages_add then
      opts.on_messages_add(messages)
    else
      for _, message in ipairs(messages) do
        local idx = nil
        for i, m in ipairs(history_messages) do
          if m.uuid == message.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = message
        else
          table.insert(history_messages, message)
        end
      end
    end
  end
  local function add_tool_call_message(update)
    local message = History.Message:new("assistant", {
      type = "tool_use",
      id = update.toolCallId,
      name = update.kind or update.title,
      input = update.rawInput or {},
    }, {
      uuid = update.toolCallId,
    })
    last_tool_call_message = message
    message.acp_tool_call = update
    if update.status == "pending" or update.status == "in_progress" then message.is_calling = true end
    tool_call_messages[update.toolCallId] = message
    if update.rawInput then
      local description = update.rawInput.description
      if description then
        message.tool_use_logs = message.tool_use_logs or {}
        table.insert(message.tool_use_logs, description)
      end
    end
    on_messages_add({ message })
    return message
  end
  local acp_client = opts.acp_client
  local session_id = opts.acp_session_id
  local acp_client_config = acp_client and acp_client.config
  local is_same_acp_command_invocation = acp_client_config
    and acp_client_config.command == acp_provider.command
    and vim.deep_equal(acp_client_config.args, acp_provider.args)
  if acp_client and not is_same_acp_command_invocation then
    Utils.debug("reset stale ACP client", acp_client_config and acp_client_config.command, acp_provider.command)
    pcall(function() acp_client:stop() end)
    acp_client = nil
    session_id = nil
    opts.acp_client = nil
    opts.acp_session_id = nil
  end
  if not acp_client then
    local acp_config = vim.tbl_deep_extend("force", acp_provider, {
      ---@type ACPHandlers
      handlers = {
        on_session_update = function(update)
          if update.sessionUpdate == "plan" then
            local todos = {}
            for idx, entry in ipairs(update.entries) do
              local status = "todo"
              if entry.status == "in_progress" then status = "doing" end
              if entry.status == "completed" then status = "done" end
              ---@type avante.TODO
              local todo = {
                id = tostring(idx),
                content = entry.content,
                status = status,
                priority = entry.priority,
              }
              table.insert(todos, todo)
            end
            vim.schedule(function()
              if opts.update_todos then opts.update_todos(todos) end
            end)
            return
          end

          if update.sessionUpdate == "agent_message_chunk" then
            if update.content.type == "text" then
              local messages = get_history_messages()
              local last_message = messages[#messages]
              if last_message and last_message.message.role == "assistant" then
                local has_text = false
                local content = last_message.message.content
                if type(content) == "string" then
                  last_message.message.content = last_message.message.content .. update.content.text
                  has_text = true
                elseif type(content) == "table" then
                  for idx, item in ipairs(content) do
                    if type(item) == "string" then
                      content[idx] = item .. update.content.text
                      has_text = true
                    end
                    if type(item) == "table" and item.type == "text" then
                      item.text = item.text .. update.content.text
                      has_text = true
                    end
                  end
                end
                if has_text then
                  on_messages_add({ last_message })
                  return
                end
              end
              local message = History.Message:new("assistant", update.content.text)
              on_messages_add({ message })
            end
          end

          if update.sessionUpdate == "agent_thought_chunk" then
            if update.content.type == "text" then
              local messages = get_history_messages()
              local last_message = messages[#messages]
              if last_message and last_message.message.role == "assistant" then
                local is_thinking = false
                local content = last_message.message.content
                if type(content) == "table" then
                  for idx, item in ipairs(content) do
                    if type(item) == "table" and item.type == "thinking" then
                      is_thinking = true
                      content[idx].thinking = content[idx].thinking .. update.content.text
                    end
                  end
                end
                if is_thinking then
                  on_messages_add({ last_message })
                  return
                end
              end
              local message = History.Message:new("assistant", {
                type = "thinking",
                thinking = update.content.text,
              })
              on_messages_add({ message })
            end
          end

          -- Follow agent edit locations: navigate to the file being edited.
          -- Extracted as a function so it can be called from both tool_call
          -- and tool_call_update (some ACP adapters send locations in the
          -- update rather than the initial tool_call).
          local function try_follow_agent_location(upd)
            if
              not Config.behaviour.acp_follow_agent_locations
              or upd.kind ~= "edit"
              or not upd.locations
              or #upd.locations < 1
            then
              return
            end

            local sidebar = require("avante").get()
            if not sidebar or sidebar.is_in_full_view then return end

            vim.schedule(function()
              if not sidebar:is_open() then return end

              -- Find a valid code window (non-sidebar window)
              local code_winid = nil
              if sidebar.code.winid and sidebar.code.winid ~= 0 and api.nvim_win_is_valid(sidebar.code.winid) then
                code_winid = sidebar.code.winid
              else
                local all_wins = api.nvim_tabpage_list_wins(0)
                for _, winid in ipairs(all_wins) do
                  if api.nvim_win_is_valid(winid) and not sidebar:is_sidebar_winid(winid) then
                    code_winid = winid
                    break
                  end
                end
              end

              if not code_winid then return end

              -- Short debounce to prevent double-fires from the same tool call
              local now = uv.now()
              local last_auto_nav = vim.g.avante_last_auto_nav or 0
              if now - last_auto_nav < 200 then return end

              -- Only follow first location to avoid rapid jumping
              local location = upd.locations[1]
              if not location or not location.path then return end

              local abs_path = Utils.is_absolute_path(location.path) and location.path
                or vim.fs.joinpath(Utils.get_project_root(), location.path)
              local bufnr = vim.fn.bufnr(abs_path, true)

              if not bufnr or bufnr == -1 then return end

              if not api.nvim_buf_is_loaded(bufnr) then pcall(vim.fn.bufload, bufnr) end

              local ok = pcall(api.nvim_win_set_buf, code_winid, bufnr)
              if not ok then return end

              local line = location.line or 1
              local line_count = api.nvim_buf_line_count(bufnr)
              local target_line = math.min(line, line_count)

              pcall(api.nvim_win_set_cursor, code_winid, { target_line, 0 })
              pcall(api.nvim_win_call, code_winid, function() vim.cmd("normal! zz") end)

              vim.g.avante_last_auto_nav = now
            end)
          end

          if update.sessionUpdate == "tool_call" then
            add_tool_call_message(update)
            try_follow_agent_location(update)
          end

          if update.sessionUpdate == "tool_call_update" then
            -- Also try follow here: some ACP adapters (e.g. claude-agent-acp)
            -- send locations in tool_call_update rather than the initial tool_call
            local merged = tool_call_messages[update.toolCallId]
              and tool_call_messages[update.toolCallId].acp_tool_call
            if merged then
              try_follow_agent_location(vim.tbl_deep_extend("force", merged, update))
            else
              try_follow_agent_location(update)
            end
            local tool_call_message = tool_call_messages[update.toolCallId]
            if not tool_call_message then
              tool_call_message = History.Message:new("assistant", {
                type = "tool_use",
                id = update.toolCallId,
                name = "",
              })
              tool_call_messages[update.toolCallId] = tool_call_message
              tool_call_message.acp_tool_call = update
            end
            if tool_call_message.acp_tool_call then
              if update.content and next(update.content) == nil then update.content = nil end
              tool_call_message.acp_tool_call = vim.tbl_deep_extend("force", tool_call_message.acp_tool_call, update)
            end
            tool_call_message.tool_use_logs = tool_call_message.tool_use_logs or {}
            tool_call_message.tool_use_log_lines = tool_call_message.tool_use_log_lines or {}
            local tool_result_message
            if update.status == "pending" or update.status == "in_progress" then
              tool_call_message.is_calling = true
              tool_call_message.state = "generating"
            elseif update.status == "completed" or update.status == "failed" then
              tool_call_message.is_calling = false
              tool_call_message.state = "generated"
              tool_result_message = History.Message:new("assistant", {
                type = "tool_result",
                tool_use_id = update.toolCallId,
                content = nil,
                is_error = update.status == "failed",
                is_user_declined = update.status == "cancelled",
              })
            end
            local messages = { tool_call_message }
            if tool_result_message then table.insert(messages, tool_result_message) end
            on_messages_add(messages)
          end

          if update.sessionUpdate == "available_commands_update" then
            local commands = update.availableCommands
            local has_cmp, cmp = pcall(require, "cmp")
            if has_cmp then
              local slash_commands_id = require("avante").slash_commands_id
              if slash_commands_id ~= nil then cmp.unregister_source(slash_commands_id) end
              for _, command in ipairs(commands) do
                local exists = false
                for _, command_ in ipairs(Config.slash_commands) do
                  if command_.name == command.name then
                    exists = true
                    break
                  end
                end
                if not exists then
                  table.insert(Config.slash_commands, {
                    name = command.name,
                    description = command.description,
                    details = command.description,
                  })
                end
              end
              local avante = require("avante")
              avante.slash_commands_id = cmp.register_source("avante_commands", require("cmp_avante.commands"):new())
            end
          end
        end,

        on_request_permission = function(tool_call, options, callback)
          local sidebar = require("avante").get()
          if not sidebar then
            Utils.error("Avante sidebar not found")
            return
          end

          ---@cast tool_call avante.acp.ToolCall

          local message = tool_call_messages[tool_call.toolCallId]
          if not message then
            message = add_tool_call_message(tool_call)
          else
            if message.acp_tool_call then
              if tool_call.content and next(tool_call.content) == nil then tool_call.content = nil end
              message.acp_tool_call = vim.tbl_deep_extend("force", message.acp_tool_call, tool_call)
            end
          end

          on_messages_add({ message })

          local description = HistoryRender.get_tool_display_name(message)
          LLMToolHelpers.confirm(description, function(ok)
            local acp_mapped_options = ACPConfirmAdapter.map_acp_options(options)

            if ok and opts.session_ctx and opts.session_ctx.always_yes then
              callback(acp_mapped_options.all)
            elseif ok then
              callback(acp_mapped_options.yes)
            else
              callback(acp_mapped_options.no)
            end

            sidebar.scroll = true
            sidebar._history_cache_invalidated = true
            sidebar:update_content("")
          end, {
            focus = true,
            skip_reject_prompt = true,
            permission_options = options,
          }, opts.session_ctx, tool_call.kind)
        end,
        on_read_file = function(path, line, limit, callback, error_callback)
          local abs_path = Utils.to_absolute_path(path)
          local lines, err, errname = Utils.read_file_from_buf_or_disk(abs_path)
          if err then
            if error_callback then
              local code = errname == "ENOENT" and ACPClient.ERROR_CODES.RESOURCE_NOT_FOUND or nil
              error_callback(err, code)
            end
            return
          end
          ---@type string[]
          local file_lines = lines or {}
          if line ~= nil and limit ~= nil then file_lines = vim.list_slice(file_lines, line, line + limit) end
          local content = table.concat(file_lines, "\n")
          if
            last_tool_call_message
            and last_tool_call_message.acp_tool_call
            and last_tool_call_message.acp_tool_call.kind == "read"
          then
            if
              last_tool_call_message.acp_tool_call.content
              and next(last_tool_call_message.acp_tool_call.content) == nil
            then
              last_tool_call_message.acp_tool_call.content = {
                {
                  type = "content",
                  content = {
                    type = "text",
                    text = content,
                  },
                },
              }
            end
          end
          callback(content)
        end,
        on_write_file = function(path, content, callback)
          local abs_path = Utils.to_absolute_path(path)
          local normalized_abs_path = Utils.abspath(abs_path)
          local file = io.open(abs_path, "w")
          if file then
            file:write(content)
            file:close()
            local buffers = vim.tbl_filter(
              function(bufnr)
                return vim.api.nvim_buf_is_valid(bufnr)
                  and Utils.abspath(vim.api.nvim_buf_get_name(bufnr)) == normalized_abs_path
              end,
              vim.api.nvim_list_bufs()
            )
            for _, buf in ipairs(buffers) do
              vim.api.nvim_buf_call(buf, function() vim.cmd("edit") end)
            end
            callback(nil)
            return
          end
          callback("Failed to write file: " .. abs_path)
        end,
      },
    })
    acp_client = ACPClient:new(acp_config)

    acp_client:connect(function(conn_err)
      if conn_err then
        opts.on_stop({ reason = "error", error = conn_err })
        return
      end

      -- Register ACP client for global cleanup on exit (Fix Issue #2749)
      local client_id = "acp_" .. tostring(acp_client) .. "_" .. os.time()
      local ok, Avante = pcall(require, "avante")
      if ok and Avante.register_acp_client then Avante.register_acp_client(client_id, acp_client) end

      -- If we create a new client and it does not support sesion loading,
      -- remove the old session
      if not acp_client.agent_capabilities.loadSession then opts.acp_session_id = nil end
      if opts.on_save_acp_client then opts.on_save_acp_client(acp_client) end

      session_id = opts.acp_session_id
      if not session_id then
        M._create_acp_session_and_continue(opts, acp_client)
      else
        M._load_acp_session_and_continue(opts, acp_client, session_id)
      end
    end)
    return
  elseif not session_id then
    M._create_acp_session_and_continue(opts, acp_client)
    return
  end

  if opts.just_connect_acp_client then return end
  M._continue_stream_acp(opts, acp_client, session_id)
end

---@param opts AvanteLLMStreamOptions
---@param acp_client avante.acp.ACPClient
function M._create_acp_session_and_continue(opts, acp_client)
  local project_root = Utils.root.get()
  local acp_provider = Config.acp_providers[Config.provider] or {}
  local mcp_servers = acp_provider.mcp_servers or {}
  acp_client:create_session(project_root, mcp_servers, function(session_id_, err)
    if err then
      opts.on_stop({ reason = "error", error = err })
      return
    end
    if not session_id_ then
      opts.on_stop({ reason = "error", error = "Failed to create session" })
      return
    end
    opts.acp_session_id = session_id_
    if opts.on_save_acp_session_id then opts.on_save_acp_session_id(session_id_) end

    if opts.just_connect_acp_client then return end
    M._continue_stream_acp(opts, acp_client, session_id_)
  end)
end

---@param opts AvanteLLMStreamOptions
---@param acp_client avante.acp.ACPClient
---@param session_id string
function M._load_acp_session_and_continue(opts, acp_client, session_id)
  local project_root = Utils.root.get()
  acp_client:load_session(session_id, project_root, {}, function(_, err)
    if err then
      -- Failed to load session, create a new one. It happens after switching acp providers
      M._create_acp_session_and_continue(opts, acp_client)
      return
    end

    if opts.just_connect_acp_client then return end
    M._continue_stream_acp(opts, acp_client, session_id)
  end)
end

---@param opts AvanteLLMStreamOptions
---@param acp_client avante.acp.ACPClient
---@param session_id string
function M._continue_stream_acp(opts, acp_client, session_id)
  local prompt = {}
  local donot_use_builtin_system_prompt = opts.history_messages ~= nil and #opts.history_messages > 0
  if donot_use_builtin_system_prompt then
    if opts.selected_filepaths then
      for _, filepath in ipairs(opts.selected_filepaths) do
        local abs_path = Utils.to_absolute_path(filepath)
        local file_name = vim.fn.fnamemodify(abs_path, ":t")
        local prompt_item = acp_client:create_resource_link_content("file://" .. abs_path, file_name)
        table.insert(prompt, prompt_item)
      end
    end
    if opts.selected_code then
      local prompt_item = {
        type = "text",
        text = string.format(
          "<selected_code>\n<path>%s</path>\n<snippet>%s</snippet>\n</selected_code>",
          opts.selected_code.path,
          opts.selected_code.content
        ),
      }
      table.insert(prompt, prompt_item)
    end
  end
  local history_messages = opts.history_messages or {}

  -- DEBUG: Log history message details
  Utils.debug("ACP history messages count: " .. #history_messages)
  for i, msg in ipairs(history_messages) do
    if msg and msg.message then
      Utils.debug(
        "History msg "
          .. i
          .. ": role="
          .. (msg.message.role or "unknown")
          .. ", has_content="
          .. tostring(msg.message.content ~= nil)
      )
      if msg.message.role == "assistant" then
        Utils.debug("Found assistant message " .. i .. ": " .. tostring(msg.message.content):sub(1, 100))
      end
    end
  end

  -- DEBUG: Log session recovery state
  Utils.debug(
    "Session recovery state: _is_session_recovery="
      .. tostring(rawget(opts, "_is_session_recovery"))
      .. ", acp_session_id="
      .. tostring(opts.acp_session_id)
  )

  -- CRITICAL: Enhanced session recovery with full context preservation
  if rawget(opts, "_is_session_recovery") and opts.acp_session_id then
    -- For session recovery, preserve full conversation context
    Utils.info("ACP session recovery: preserving full conversation context")

    -- Add all recent messages (both user and assistant) for better context
    local recent_messages = {}
    local recovery_config = Config.session_recovery or {}
    local include_history_count = recovery_config.include_history_count or 15 -- Default to 15 for better context

    -- Get recent messages from truncated history
    local start_idx = math.max(1, #history_messages - include_history_count + 1)
    Utils.debug("Including history from index " .. start_idx .. " to " .. #history_messages)

    for i = start_idx, #history_messages do
      local message = history_messages[i]
      if message and message.message then
        table.insert(recent_messages, message)
        Utils.debug("Adding message " .. i .. " to recent_messages: role=" .. (message.message.role or "unknown"))
      end
    end

    Utils.info("ACP recovery: including " .. #recent_messages .. " recent messages")

    -- DEBUG: Log what we're about to add to prompt
    for i, msg in ipairs(recent_messages) do
      if msg and msg.message then
        Utils.debug("Adding to prompt: " .. i .. " role=" .. (msg.message.role or "unknown"))
      end
    end

    -- CRITICAL: Add all recent messages to prompt for complete context
    for _, message in ipairs(recent_messages) do
      local role = message.message.role
      local content = message.message.content

      Utils.debug("Processing message: role=" .. (role or "unknown") .. ", content_type=" .. type(content))

      -- Format based on role
      local role_tag = role == "user" and "previous_user_message" or "previous_assistant_message"

      if type(content) == "table" then
        for _, item in ipairs(content) do
          if type(item) == "string" then
            table.insert(prompt, {
              type = "text",
              text = "<" .. role_tag .. ">" .. item .. "</" .. role_tag .. ">",
            })
            Utils.debug("Added assistant table content: " .. item:sub(1, 50) .. "...")
          elseif type(item) == "table" and item.type == "text" then
            table.insert(prompt, {
              type = "text",
              text = "<" .. role_tag .. ">" .. item.text .. "</" .. role_tag .. ">",
            })
            Utils.debug("Added assistant text content: " .. item.text:sub(1, 50) .. "...")
          end
        end
      else
        table.insert(prompt, {
          type = "text",
          text = "<" .. role_tag .. ">" .. content .. "</" .. role_tag .. ">",
        })
        if role == "assistant" then
          Utils.debug("Added assistant content: " .. tostring(content):sub(1, 50) .. "...")
        end
      end
    end

    -- Add context about session recovery with more detail
    if #recent_messages > 0 then
      table.insert(prompt, {
        type = "text",
        text = "<system_context>Continuing from previous ACP session with "
          .. #recent_messages
          .. " recent messages preserved for context</system_context>",
      })
    end
  elseif opts.acp_session_id then
    -- Original logic for non-recovery session continuation
    local recovery_config = Config.session_recovery or {}
    local include_history_count = recovery_config.include_history_count or 5
    local user_messages_added = 0

    for i = #history_messages, 1, -1 do
      local message = history_messages[i]
      if message.message.role == "user" and user_messages_added < include_history_count then
        local content = message.message.content
        if type(content) == "table" then
          for _, item in ipairs(content) do
            if type(item) == "string" then
              table.insert(prompt, {
                type = "text",
                text = "<previous_user_message>" .. item .. "</previous_user_message>",
              })
            elseif type(item) == "table" and item.type == "text" then
              table.insert(prompt, {
                type = "text",
                text = "<previous_user_message>" .. item.text .. "</previous_user_message>",
              })
            end
          end
        elseif type(content) == "string" then
          table.insert(prompt, {
            type = "text",
            text = "<previous_user_message>" .. content .. "</previous_user_message>",
          })
        end
        user_messages_added = user_messages_added + 1
      end
    end

    -- Add context about session recovery
    if user_messages_added > 0 then
      table.insert(prompt, {
        type = "text",
        text = "<system_context>Continuing from previous session with "
          .. user_messages_added
          .. " recent user messages</system_context>",
      })
    end
  else
    if donot_use_builtin_system_prompt then
      -- Include all user messages for better context preservation
      for _, message in ipairs(history_messages) do
        if message.message.role == "user" then
          local content = message.message.content
          if type(content) == "table" then
            for _, item in ipairs(content) do
              if type(item) == "string" then
                table.insert(prompt, {
                  type = "text",
                  text = item,
                })
              elseif type(item) == "table" and item.type == "text" then
                table.insert(prompt, {
                  type = "text",
                  text = item.text,
                })
              end
            end
          else
            table.insert(prompt, {
              type = "text",
              text = content,
            })
          end
        end
      end
    else
      local prompt_opts = M.generate_prompts(opts)
      table.insert(prompt, {
        type = "text",
        text = prompt_opts.system_prompt,
      })
      for _, message in ipairs(prompt_opts.messages) do
        if message.role == "user" then
          table.insert(prompt, {
            type = "text",
            text = message.content,
          })
        end
      end
    end
  end
  local cancelled = false
  local stop_cmd_id = api.nvim_create_autocmd("User", {
    group = group,
    pattern = M.CANCEL_PATTERN,
    once = true,
    callback = function()
      cancelled = true
      local cancelled_text = "\n*[Request cancelled by user.]*\n"
      if opts.on_chunk then opts.on_chunk(cancelled_text) end
      if opts.on_messages_add then
        local message = History.Message:new("assistant", cancelled_text, {
          just_for_display = true,
        })
        opts.on_messages_add({ message })
      end
      acp_client:cancel_session(session_id)
      opts.on_stop({ reason = "cancelled" })
    end,
  })
  acp_client:send_prompt(session_id, prompt, function(_, err_)
    if cancelled then return end
    vim.schedule(function() api.nvim_del_autocmd(stop_cmd_id) end)
    if err_ then
      -- ACP-specific session recovery: Check for session not found error
      -- Check for session recovery conditions
      local recovery_config = Config.session_recovery or {}
      local recovery_enabled = recovery_config.enabled ~= false -- Default enabled unless explicitly disabled

      local is_session_not_found = false
      if err_.code == -32603 and err_.data and err_.data.details then
        local details = err_.data.details
        -- Support both Claude format ("Session not found") and Gemini-CLI format ("Session not found: session-id")
        is_session_not_found = details == "Session not found" or details:match("^Session not found:")
      end

      if recovery_enabled and is_session_not_found and not rawget(opts, "_session_recovery_attempted") then
        -- Mark recovery attempt to prevent infinite loops
        rawset(opts, "_session_recovery_attempted", true)

        -- DEBUG: Log recovery attempt
        Utils.debug("Session recovery attempt detected, setting _session_recovery_attempted flag")

        -- Clear invalid session ID
        if opts.on_save_acp_session_id then
          opts.on_save_acp_session_id("") -- Use empty string instead of nil
        end

        -- Clear invalid session for recovery - let global cleanup handle ACP processes
        vim.schedule(function()
          opts.acp_client = nil
          opts.acp_session_id = nil
        end)

        -- CRITICAL: Preserve full history for better context retention
        -- Only truncate if explicitly configured to do so, otherwise keep full history
        local original_history = opts.history_messages or {}
        local truncated_history

        -- Check if history truncation is explicitly enabled
        local should_truncate = recovery_config.truncate_history ~= false -- Default to true for backward compatibility

        -- DEBUG: Log original history details
        Utils.debug("Original history for recovery: " .. #original_history .. " messages")
        for i, msg in ipairs(original_history) do
          if msg and msg.message then
            Utils.debug("Original history " .. i .. ": role=" .. (msg.message.role or "unknown"))
          end
        end

        if should_truncate and #original_history > 20 then -- Only truncate if history is long enough (20条)
          -- Safely call truncation function
          local ok, result = pcall(truncate_history_for_recovery, original_history)
          if ok then
            truncated_history = result
            Utils.info(
              "History truncated from "
                .. #original_history
                .. " to "
                .. #truncated_history
                .. " messages for recovery"
            )
          else
            Utils.warn("Failed to truncate history for recovery: " .. tostring(result))
            truncated_history = original_history -- Use full history as fallback
          end
        else
          -- Use full history for better context retention
          truncated_history = original_history
          Utils.debug("Using full history for session recovery: " .. #truncated_history .. " messages")
        end

        -- DEBUG: Log truncated history details
        Utils.debug("Truncated history for recovery: " .. #truncated_history .. " messages")
        for i, msg in ipairs(truncated_history) do
          if msg and msg.message then
            Utils.debug("Truncated history " .. i .. ": role=" .. (msg.message.role or "unknown"))
          end
        end

        opts.history_messages = truncated_history

        Utils.info(
          string.format(
            "Session expired, recovering with %d recent messages (from %d total)...",
            #truncated_history,
            #original_history
          )
        )

        -- CRITICAL: Use vim.schedule to move recovery out of fast event context
        -- This prevents E5560 errors by avoiding vim.fn calls in fast event context
        vim.schedule(function()
          Utils.debug("Session recovery: clearing old session ID and retrying...")

          -- Clean up recovery flags for fresh session state management
          rawset(opts, "_session_recovery_attempted", nil)

          -- Mark this as a recovery attempt to preserve history context
          rawset(opts, "_is_session_recovery", true)

          -- Update UI state if available
          if opts.on_state_change then opts.on_state_change("generating") end

          -- CRITICAL: Ensure history messages are preserved in recovery
          Utils.info("Session recovery retry with " .. #(opts.history_messages or {}) .. " history messages")

          -- DEBUG: Log recovery history details
          local recovery_history = opts.history_messages or {}
          Utils.debug("Recovery history messages: " .. #recovery_history)
          for i, msg in ipairs(recovery_history) do
            if msg and msg.message then
              Utils.debug("Recovery msg " .. i .. ": role=" .. (msg.message.role or "unknown"))
              if msg.message.role == "assistant" then
                Utils.debug("Recovery assistant content: " .. tostring(msg.message.content):sub(1, 100))
              end
            end
          end

          -- Retry with truncated history to rebuild context in new session
          M._stream_acp(opts)
        end)

        -- CRITICAL: Return immediately to prevent further processing in fast event context
        return
      end
      opts.on_stop({ reason = "error", error = err_ })
      return
    end
    opts.on_stop({ reason = "complete" })
  end)
end

---@param opts AvanteLLMStreamOptions
function M._stream(opts)
  -- Reset the cancellation flag at the start of a new request
  if LLMToolHelpers then LLMToolHelpers.is_cancelled = false end

  local acp_provider = Config.acp_providers[Config.provider]
  if acp_provider then return M._stream_acp(opts) end

  local provider = opts.provider or Providers[Config.provider]
  opts.session_ctx = opts.session_ctx or {}

  if not opts.session_ctx.on_messages_add then opts.session_ctx.on_messages_add = opts.on_messages_add end
  if not opts.session_ctx.on_state_change then opts.session_ctx.on_state_change = opts.on_state_change end
  if not opts.session_ctx.on_start then opts.session_ctx.on_start = opts.on_start end
  if not opts.session_ctx.on_chunk then opts.session_ctx.on_chunk = opts.on_chunk end
  if not opts.session_ctx.on_stop then opts.session_ctx.on_stop = opts.on_stop end
  if not opts.session_ctx.on_tool_log then opts.session_ctx.on_tool_log = opts.on_tool_log end
  if not opts.session_ctx.get_history_messages then
    opts.session_ctx.get_history_messages = opts.get_history_messages
  end

  ---@cast provider AvanteProviderFunctor

  local prompt_opts = M.generate_prompts(opts)

  if
    prompt_opts.pending_compaction_history_messages
    and #prompt_opts.pending_compaction_history_messages > 0
    and opts.on_memory_summarize
  then
    opts.on_memory_summarize(prompt_opts.pending_compaction_history_messages)
    return
  end

  local resp_headers = {}

  local function dispatch_cancel_message()
    local cancelled_text = "\n*[Request cancelled by user.]*\n"
    if opts.on_chunk then opts.on_chunk(cancelled_text) end
    if opts.on_messages_add then
      local message = History.Message:new("assistant", cancelled_text, {
        just_for_display = true,
      })
      opts.on_messages_add({ message })
    end
    return opts.on_stop({ reason = "cancelled" })
  end

  ---@type AvanteHandlerOptions
  local handler_opts = {
    on_messages_add = opts.on_messages_add,
    on_state_change = opts.on_state_change,
    update_tokens_usage = opts.update_tokens_usage,
    on_start = opts.on_start,
    on_chunk = opts.on_chunk,
    on_stop = function(stop_opts)
      if stop_opts.usage and opts.update_tokens_usage then opts.update_tokens_usage(stop_opts.usage) end

      ---@param tool_uses AvantePartialLLMToolUse[]
      ---@param tool_use_index integer
      ---@param tool_results AvanteLLMToolResult[]
      local function handle_next_tool_use(
        tool_uses,
        tool_use_messages,
        tool_use_index,
        tool_results,
        streaming_tool_use
      )
        if tool_use_index > #tool_uses then
          ---@type avante.HistoryMessage[]
          local messages = {}
          for _, tool_result in ipairs(tool_results) do
            messages[#messages + 1] = History.Message:new("user", {
              type = "tool_result",
              tool_use_id = tool_result.tool_use_id,
              content = tool_result.content,
              is_error = tool_result.is_error,
              is_user_declined = tool_result.is_user_declined,
            })
          end
          if opts.on_messages_add then opts.on_messages_add(messages) end
          local the_last_tool_use = tool_uses[#tool_uses]
          if the_last_tool_use and the_last_tool_use.name == "attempt_completion" then
            opts.on_stop({ reason = "complete" })
            return
          end
          local new_opts = vim.tbl_deep_extend("force", opts, {
            history_messages = opts.get_history_messages and opts.get_history_messages() or {},
          })
          if provider.get_rate_limit_sleep_time then
            local sleep_time = provider:get_rate_limit_sleep_time(resp_headers)
            if sleep_time and sleep_time > 0 then
              Utils.info("Rate limit reached. Sleeping for " .. sleep_time .. " seconds ...")
              vim.defer_fn(function() M._stream(new_opts) end, sleep_time * 1000)
              return
            end
          end
          if not streaming_tool_use then M._stream(new_opts) end
          return
        end
        local partial_tool_use = tool_uses[tool_use_index]
        local partial_tool_use_message = tool_use_messages[tool_use_index]
        ---@param result string | nil
        ---@param error string | nil
        local function handle_tool_result(result, error)
          partial_tool_use_message.is_calling = false
          if opts.on_messages_add then opts.on_messages_add({ partial_tool_use_message }) end
          -- Special handling for cancellation signal from tools
          if error == LLMToolHelpers.CANCEL_TOKEN then
            Utils.debug("Tool execution was cancelled by user")
            local cancelled_text = "\n*[Request cancelled by user during tool execution.]*\n"
            if opts.on_chunk then opts.on_chunk(cancelled_text) end
            if opts.on_messages_add then
              local message = History.Message:new("assistant", cancelled_text, {
                just_for_display = true,
              })
              opts.on_messages_add({ message })
            end
            return opts.on_stop({ reason = "cancelled" })
          end

          local is_user_declined = error and error:match("^User declined")
          local tool_result = {
            tool_use_id = partial_tool_use.id,
            content = error ~= nil and error or result,
            is_error = error ~= nil, -- Keep this as error to prevent processing as success
            is_user_declined = is_user_declined ~= nil,
          }
          table.insert(tool_results, tool_result)
          return handle_next_tool_use(tool_uses, tool_use_messages, tool_use_index + 1, tool_results)
        end
        local is_edit_tool_use = Utils.is_edit_tool_use(partial_tool_use)
        local support_streaming = false
        local llm_tool = vim.iter(prompt_opts.tools):find(function(tool) return tool.name == partial_tool_use.name end)
        if llm_tool then support_streaming = llm_tool.support_streaming == true end
        ---@type AvanteLLMToolFuncOpts
        local tool_use_opts = {
          session_ctx = opts.session_ctx,
          tool_use_id = partial_tool_use.id,
          streaming = partial_tool_use.state == "generating",
          on_complete = function() end,
        }
        if partial_tool_use.state == "generating" then
          if not is_edit_tool_use and not support_streaming then return end
          if type(partial_tool_use.input) == "table" then
            LLMTools.process_tool_use(prompt_opts.tools, partial_tool_use, tool_use_opts)
          end
          return
        end
        if streaming_tool_use then return end
        partial_tool_use_message.is_calling = true
        if opts.on_messages_add then opts.on_messages_add({ partial_tool_use_message }) end
        -- Either on_complete handles the tool result asynchronously or we receive the result and error synchronously when either is not nil
        local result, error = LLMTools.process_tool_use(prompt_opts.tools, partial_tool_use, {
          session_ctx = opts.session_ctx,
          on_log = opts.on_tool_log,
          set_tool_use_store = opts.set_tool_use_store,
          on_complete = handle_tool_result,
          tool_use_id = partial_tool_use.id,
        })
        if result ~= nil or error ~= nil then return handle_tool_result(result, error) end
      end
      if stop_opts.reason == "cancelled" then dispatch_cancel_message() end
      local history_messages = opts.get_history_messages and opts.get_history_messages({ all = true }) or {}
      local pending_tools, pending_tool_use_messages = History.get_pending_tools(history_messages)
      if stop_opts.reason == "complete" and Config.mode == "agentic" then
        local completed_attempt_completion_tool_use = nil
        for idx = #history_messages, 1, -1 do
          local message = history_messages[idx]
          if message.is_user_submission then break end
          local use = History.Helpers.get_tool_use_data(message)
          if use and use.name == "attempt_completion" then
            completed_attempt_completion_tool_use = message
            break
          end
        end
        local unfinished_todos = {}
        if opts.get_todos then
          local todos = opts.get_todos()
          unfinished_todos = vim.tbl_filter(
            function(todo) return todo.status ~= "done" and todo.status ~= "cancelled" end,
            todos
          )
        end
        local user_reminder_count = opts.session_ctx.user_reminder_count or 0
        if
          not completed_attempt_completion_tool_use
          and opts.on_messages_add
          and (user_reminder_count < 3 or #unfinished_todos > 0)
        then
          opts.session_ctx.user_reminder_count = user_reminder_count + 1
          Utils.debug("user reminder count", user_reminder_count)
          local message
          if #unfinished_todos > 0 then
            message = History.Message:new(
              "user",
              "<system-reminder>You should use tool calls to answer the question, for example, use write_todos if the task step is done or cancelled.</system-reminder>",
              {
                visible = false,
              }
            )
          else
            message = History.Message:new(
              "user",
              "<system-reminder>You should use tool calls to answer the question, for example, use attempt_completion if the job is done.</system-reminder>",
              {
                visible = false,
              }
            )
          end
          opts.on_messages_add({ message })
          local new_opts = vim.tbl_deep_extend("force", opts, {
            history_messages = opts.get_history_messages(),
          })
          if provider.get_rate_limit_sleep_time then
            local sleep_time = provider:get_rate_limit_sleep_time(resp_headers)
            if sleep_time and sleep_time > 0 then
              Utils.info("Rate limit reached. Sleeping for " .. sleep_time .. " seconds ...")
              vim.defer_fn(function() M._stream(new_opts) end, sleep_time * 1000)
              return
            end
          end
          M._stream(new_opts)
          return
        end
      end
      if stop_opts.reason == "tool_use" then
        opts.session_ctx.user_reminder_count = 0
        return handle_next_tool_use(pending_tools, pending_tool_use_messages, 1, {}, stop_opts.streaming_tool_use)
      end
      if stop_opts.reason == "rate_limit" then
        local message = opts.on_messages_add
          and History.Message:new(
            "assistant",
            "", -- Actual content will be set below
            {
              just_for_display = true,
            }
          )

        local retry_count = stop_opts.retry_after
        Utils.info("Rate limit reached. Retrying in " .. retry_count .. " seconds", { title = "Avante" })

        local function countdown()
          if abort_retry_timer then
            Utils.info("Retry aborted due to user requested cancellation.")
            stop_retry_timer()
            dispatch_cancel_message()
            return
          end

          local msg_content = "*[Rate limit reached. Retrying in " .. retry_count .. " seconds ...]*"
          if opts.on_chunk then
            -- Use ANSI escape codes to clear line and move cursor up only for subsequent updates
            local prefix = ""
            if retry_count < stop_opts.retry_after then prefix = [[\033[1A\033[K]] end
            opts.on_chunk(prefix .. "\n" .. msg_content .. "\n")
          end
          if opts.on_messages_add and message then
            message:update_content("\n\n" .. msg_content)
            opts.on_messages_add({ message })
          end

          if retry_count <= 0 then
            stop_retry_timer()

            Utils.info("Restarting stream after rate limit pause")
            M._stream(opts)
          else
            retry_count = retry_count - 1
          end
        end

        stop_retry_timer()
        retry_timer = uv.new_timer()
        if retry_timer then retry_timer:start(0, 1000, vim.schedule_wrap(function() countdown() end)) end
        return
      end
      return opts.on_stop(stop_opts)
    end,
  }

  return M.curl({
    provider = provider,
    prompt_opts = prompt_opts,
    handler_opts = handler_opts,
    on_response_headers = function(headers) resp_headers = headers end,
  })
end

local function _merge_response(first_response, second_response, opts)
  local prompt = "\n" .. Config.dual_boost.prompt
  prompt = prompt
    :gsub("{{[%s]*provider1_output[%s]*}}", function() return first_response end)
    :gsub("{{[%s]*provider2_output[%s]*}}", function() return second_response end)

  prompt = prompt .. "\n"

  if opts.instructions == nil then opts.instructions = "" end

  -- append this reference prompt to the prompt_opts messages at last
  opts.instructions = opts.instructions .. prompt

  M._stream(opts)
end

local function _collector_process_responses(collector, opts)
  if not collector[1] or not collector[2] then
    Utils.error("One or both responses failed to complete")
    return
  end
  _merge_response(collector[1], collector[2], opts)
end

local function _collector_add_response(collector, index, response, opts)
  collector[index] = response
  collector.count = collector.count + 1

  if collector.count == 2 then
    collector.timer:stop()
    _collector_process_responses(collector, opts)
  end
end

function M._dual_boost_stream(opts, Provider1, Provider2)
  Utils.debug("Starting Dual Boost Stream")

  local collector = {
    count = 0,
    responses = {},
    timer = uv.new_timer(),
    timeout_ms = Config.dual_boost.timeout,
  }

  -- Setup timeout
  collector.timer:start(
    collector.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if collector.count < 2 then
        Utils.warn("Dual boost stream timeout reached")
        collector.timer:stop()
        -- Process whatever responses we have
        _collector_process_responses(collector, opts)
      end
    end)
  )

  -- Create options for both streams
  local function create_stream_opts(index)
    local response = ""
    return vim.tbl_extend("force", opts, {
      on_chunk = function(chunk)
        if chunk then response = response .. chunk end
      end,
      on_stop = function(stop_opts)
        if stop_opts.error then
          Utils.error(string.format("Stream %d failed: %s", index, stop_opts.error))
          return
        end
        Utils.debug(string.format("Response %d completed", index))
        _collector_add_response(collector, index, response, opts)
      end,
    })
  end

  -- Start both streams
  local success, err = xpcall(function()
    local opts1 = create_stream_opts(1)
    opts1.provider = Provider1
    M._stream(opts1)
    local opts2 = create_stream_opts(2)
    opts2.provider = Provider2
    M._stream(opts2)
  end, function(err) return err end)
  if not success then Utils.error("Failed to start dual_boost streams: " .. tostring(err)) end
end

---@param opts AvanteLLMStreamOptions
function M.stream(opts)
  local is_completed = false
  if opts.on_tool_log ~= nil then
    local original_on_tool_log = opts.on_tool_log
    opts.on_tool_log = vim.schedule_wrap(function(...)
      if not original_on_tool_log then return end
      return original_on_tool_log(...)
    end)
  end
  if opts.set_tool_use_store ~= nil then
    local original_set_tool_use_store = opts.set_tool_use_store
    opts.set_tool_use_store = vim.schedule_wrap(function(...)
      if not original_set_tool_use_store then return end
      return original_set_tool_use_store(...)
    end)
  end
  if opts.on_chunk ~= nil then
    local original_on_chunk = opts.on_chunk
    opts.on_chunk = vim.schedule_wrap(function(chunk)
      if is_completed then return end
      if original_on_chunk then return original_on_chunk(chunk) end
    end)
  end
  if opts.on_stop ~= nil then
    local original_on_stop = opts.on_stop
    opts.on_stop = vim.schedule_wrap(function(stop_opts)
      if is_completed then return end
      if stop_opts.reason == "complete" or stop_opts.reason == "error" or stop_opts.reason == "cancelled" then
        is_completed = true
      end
      return original_on_stop(stop_opts)
    end)
  end

  local valid_dual_boost_modes = {
    legacy = true,
  }

  opts.mode = opts.mode or Config.mode

  abort_retry_timer = false
  if Config.dual_boost.enabled and valid_dual_boost_modes[opts.mode] then
    M._dual_boost_stream(
      opts,
      Providers[Config.dual_boost.first_provider],
      Providers[Config.dual_boost.second_provider]
    )
  else
    M._stream(opts)
  end
end

function M.cancel_inflight_request()
  if LLMToolHelpers.is_cancelled ~= nil then LLMToolHelpers.is_cancelled = true end
  if LLMToolHelpers.confirm_popup ~= nil then
    LLMToolHelpers.confirm_popup:cancel()
    LLMToolHelpers.confirm_popup = nil
  end
  abort_retry_timer = true

  api.nvim_exec_autocmds("User", { pattern = M.CANCEL_PATTERN })
end

return M
