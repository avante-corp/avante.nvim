---NOTE: user will be merged with defaults and
---we add a default var_accessor for this table to config values.

---@alias WebSearchEngineProviderResponseBodyFormatter fun(body: table): (string, string?)
---@alias avante.InputProvider "native" | "dressing" | "snacks" | fun(input: avante.ui.Input): nil

local Utils = require("avante.utils")

local function copilot_use_response_api(opts)
  local model = opts and opts.model
  return type(model) == "string" and model:match("gpt%-5%-codex") ~= nil
end

---@class avante.file_selector.IParams
---@field public title      string
---@field public filepaths  string[]
---@field public handler    fun(filepaths: string[]|nil): nil

---@class avante.file_selector.opts.IGetFilepathsParams
---@field public cwd                string
---@field public selected_filepaths string[]

---@class avante.CoreConfig: avante.Config
local M = {}

--- Default configuration for project-specific instruction file
M.instructions_file = "avante.md"
---@class avante.Config
M._defaults = {
  debug = false,
  ---@alias avante.Mode "agentic" | "legacy"
  ---@type avante.Mode
  mode = "agentic",
  --- ACP backend implementation to use.
  --- "lua" uses the built-in Lua JSON-RPC client.
  --- "python" uses the Python bridge in `python/`, which implements the full
  --- ACP surface (terminals, resume, MCP forwarding) via the official SDK.
  --- Falls back to "lua" automatically when no Python environment is found,
  --- so this is safe to leave on.
  ---@alias avante.AcpBackend "lua" | "python"
  ---@type avante.AcpBackend
  acp_backend = "python",
  --- Python interpreter for the ACP bridge. When nil, avante looks for
  --- `python/.venv`, then `uv`.
  ---@type string|nil
  acp_python = nil,
  --- Default deadline in milliseconds for ACP bridge requests. Prompts and
  --- authentication are exempt: they are bounded by user or agent action.
  ---@type number
  acp_timeout = 30000,
  --- Enable ACP's unstable protocol surface, which currently gates
  --- `elicitation/create`. claude-agent-acp disables its built-in
  --- AskUserQuestion tool unless the client advertises `elicitation.form`, so
  --- turning this off means the agent cannot ask you questions mid-turn.
  ---@type boolean
  acp_unstable = true,
  --- How an agent asks you a question mid-turn. Most agents have no way to:
  --- cursor decides its own AskQuestion tool is unavailable and asks in prose
  --- instead. "auto" hands those agents an `ask_user_question` MCP tool that
  --- avante hosts, so they get the same picker claude does. claude is left
  --- alone, since its `elicitation/create` path already works.
  ---@alias avante.AcpAskTool "auto" | "always" | "never"
  ---@type avante.AcpAskTool
  acp_ask_tool = "auto",
  --- Record every JSON-RPC frame exchanged with an agent, so a bug in a real
  --- session can be replayed instead of reproduced by guesswork.
  ---@type boolean
  acp_log_transcript = true,
  --- Where transcripts go: <dir>/<YYYY-MM-DD>/<provider>-<sessionId>.log
  ---@type string
  acp_log_dir = "~/.avante/logs",
  --- Where plans delivered over the protocol are saved, so /open-plan can
  --- reach them: <dir>/<YYYY-MM-DD>/<session>-<name>.md
  ---@type string
  acp_plan_dir = "~/.avante/plans",
  ---@alias avante.ProviderName "claude" | "openai" | "azure" | "gemini" | "vertex" | "cohere" | "copilot" | "bedrock" | "ollama" | "watsonx_code_assistant" | string
  ---@type avante.ProviderName
  provider = "claude",
  -- WARNING: Since auto-suggestions are a high-frequency operation and therefore expensive,
  -- currently designating it as `copilot` provider is dangerous because: https://github.com/yetone/avante.nvim/issues/1048
  -- Of course, you can reduce the request frequency by increasing `suggestion.debounce`.
  auto_suggestions_provider = nil,
  memory_summary_provider = nil,
  ---@alias Tokenizer "tiktoken" | "hf"
  ---@type Tokenizer
  -- Used for counting tokens and encoding text.
  -- By default, we will use tiktoken.
  -- For most providers that we support we will determine this automatically.
  -- If you wish to use a given implementation, then you can override it here.
  tokenizer = "tiktoken",
  ---@type string | fun(): string | nil
  system_prompt = nil,
  ---@type string | fun(): string | nil
  override_prompt_dir = nil,
  rules = {
    project_dir = nil, ---@type string | nil (could be relative dirpath)
    global_dir = nil, ---@type string | nil (absolute dirpath)
  },
  rag_service = { -- RAG service configuration
    enabled = false, -- Enables the RAG service
    host_mount = os.getenv("HOME"), -- Host mount path for the RAG service (Docker will mount this path)
    runner = "docker", -- The runner for the RAG service (can use docker or nix)
    llm = { -- Configuration for the Language Model (LLM) used by the RAG service
      provider = "openai", -- The LLM provider
      endpoint = "https://api.openai.com/v1", -- The LLM API endpoint
      api_key = "OPENAI_API_KEY", -- The environment variable name for the LLM API key
      model = "gpt-4o-mini", -- The LLM model name
      extra = nil, -- Extra configuration options for the LLM
    },
    embed = { -- Configuration for the Embedding model used by the RAG service
      provider = "openai", -- The embedding provider
      endpoint = "https://api.openai.com/v1", -- The embedding API endpoint
      api_key = "OPENAI_API_KEY", -- The environment variable name for the embedding API key
      model = "text-embedding-3-large", -- The embedding model name
      extra = nil, -- Extra configuration options for the embedding model
    },
    docker_extra_args = "", -- Extra arguments to pass to the docker command
  },
  web_search_engine = {
    provider = "tavily",
    proxy = nil,
    providers = {
      tavily = {
        api_key_name = "TAVILY_API_KEY",
        extra_request_body = {
          include_answer = "basic",
        },
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body) return body.answer, nil end,
      },
      serpapi = {
        api_key_name = "SERPAPI_API_KEY",
        extra_request_body = {
          engine = "google",
          google_domain = "google.com",
        },
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body)
          if body.answer_box ~= nil and body.answer_box.result ~= nil then return body.answer_box.result, nil end
          if body.organic_results ~= nil then
            local jsn = vim
              .iter(body.organic_results)
              :map(
                function(result)
                  return {
                    title = result.title,
                    link = result.link,
                    snippet = result.snippet,
                    date = result.date,
                  }
                end
              )
              :take(10)
              :totable()
            return vim.json.encode(jsn), nil
          end
          return "", nil
        end,
      },
      searchapi = {
        api_key_name = "SEARCHAPI_API_KEY",
        extra_request_body = {
          engine = "google",
        },
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body)
          if body.answer_box ~= nil then return body.answer_box.result, nil end
          if body.organic_results ~= nil then
            local jsn = vim
              .iter(body.organic_results)
              :map(
                function(result)
                  return {
                    title = result.title,
                    link = result.link,
                    snippet = result.snippet,
                    date = result.date,
                  }
                end
              )
              :take(10)
              :totable()
            return vim.json.encode(jsn), nil
          end
          return "", nil
        end,
      },
      google = {
        api_key_name = "GOOGLE_SEARCH_API_KEY",
        engine_id_name = "GOOGLE_SEARCH_ENGINE_ID",
        extra_request_body = {},
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body)
          if body.items ~= nil then
            local jsn = vim
              .iter(body.items)
              :map(
                function(result)
                  return {
                    title = result.title,
                    link = result.link,
                    snippet = result.snippet,
                  }
                end
              )
              :take(10)
              :totable()
            return vim.json.encode(jsn), nil
          end
          return "", nil
        end,
      },
      kagi = {
        api_key_name = "KAGI_API_KEY",
        extra_request_body = {
          limit = "10",
        },
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body)
          if body.data ~= nil then
            local jsn = vim
              .iter(body.data)
              -- search results only
              :filter(function(result) return result.t == 0 end)
              :map(
                function(result)
                  return {
                    title = result.title,
                    url = result.url,
                    snippet = result.snippet,
                  }
                end
              )
              :take(10)
              :totable()
            return vim.json.encode(jsn), nil
          end
          return "", nil
        end,
      },
      brave = {
        api_key_name = "BRAVE_API_KEY",
        extra_request_body = {
          count = "10",
          result_filter = "web",
        },
        format_response_body = function(body)
          if body.web == nil then return "", nil end

          local jsn = vim.iter(body.web.results):map(
            function(result)
              return {
                title = result.title,
                url = result.url,
                snippet = result.description,
              }
            end
          )

          return vim.json.encode(jsn), nil
        end,
      },
      searxng = {
        api_url_name = "SEARXNG_API_URL",
        extra_request_body = {
          format = "json",
        },
        ---@type WebSearchEngineProviderResponseBodyFormatter
        format_response_body = function(body)
          if body.results == nil then return "", nil end

          local jsn = vim.iter(body.results):map(
            function(result)
              return {
                title = result.title,
                url = result.url,
                snippet = result.content,
              }
            end
          )

          return vim.json.encode(jsn), nil
        end,
      },
    },
  },
  acp_providers = {
    ["gemini-cli"] = {
      command = "gemini",
      args = { "--experimental-acp" },
      env = {
        NODE_NO_WARNINGS = "1",
        GEMINI_API_KEY = os.getenv("GEMINI_API_KEY"),
      },
      auth_method = "gemini-api-key",
      envOverrides = {},
    },
    ["claude-code"] = {
      -- The maintained successor to @zed-industries/claude-code-acp. The old
      -- scripts/acp-wrapper.mjs shim has been deleted: it only ever patched
      -- v0.12.6 while installing unpinned, so it was already broken.
      command = "npx",
      args = { "-y", "@agentclientprotocol/claude-agent-acp" },
      env = {
        NODE_NO_WARNINGS = "1",
        ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
        ANTHROPIC_BASE_URL = os.getenv("ANTHROPIC_BASE_URL"),
        CLAUDE_CODE_EXECUTABLE = vim.fn.exepath("claude"),
      },
      envOverrides = {},
    },
    ["cursor"] = {
      -- Cursor's docs render this as `agent acp`, but the binary its CLI
      -- installs is `cursor-agent`. Requires `cursor-agent login`, or
      -- CURSOR_API_KEY / CURSOR_AUTH_TOKEN in the environment.
      command = "cursor-agent",
      args = { "acp" },
      auth_method = "cursor_login",
      env = {
        CURSOR_API_KEY = os.getenv("CURSOR_API_KEY"),
        CURSOR_AUTH_TOKEN = os.getenv("CURSOR_AUTH_TOKEN"),
      },
      envOverrides = {},
    },
    ["goose"] = {
      command = "goose",
      args = { "acp" },
      envOverrides = {},
    },
    ["codex"] = {
      command = "codex-acp",
      env = {
        NODE_NO_WARNINGS = "1",
        HOME = os.getenv("HOME"),
        PATH = os.getenv("PATH"),
        OPENAI_API_KEY = os.getenv("OPENAI_API_KEY"),
      },
      envOverrides = {},
    },
    ["opencode"] = {
      command = "opencode",
      args = { "acp" },
      envOverrides = {},
    },
    ["kimi-cli"] = {
      command = "kimi",
      args = { "--acp" },
      envOverrides = {},
    },
  },
  ---To add support for custom provider, follow the format below
  ---See https://github.com/yetone/avante.nvim/wiki#custom-providers for more details
  ---@type {[string]: AvanteProvider}
  providers = {
    ---@type AvanteSupportedProvider
    openai = {
      endpoint = "https://api.openai.com/v1",
      model = "gpt-4o",
      timeout = 30000, -- Timeout in milliseconds, increase this for reasoning models
      context_window = 128000, -- Number of tokens to send to the model for context
      use_response_api = copilot_use_response_api, -- Automatically switch to Response API for GPT-5 Codex models
      support_previous_response_id = true, -- OpenAI Response API supports previous_response_id for stateful conversations
      -- NOTE: Response API automatically manages conversation state using previous_response_id for tool calling
      extra_request_body = {
        temperature = 0.75,
        max_completion_tokens = 16384, -- Increase this to include reasoning tokens (for reasoning models). For Response API, will be converted to max_output_tokens
        reasoning_effort = "medium", -- low|medium|high, only used for reasoning models. For Response API, this will be converted to reasoning.effort
        -- background = false, -- Response API only: set to true to start a background task
        -- NOTE: previous_response_id is automatically managed by the provider for tool calling - don't set manually
      },
    },
    ---@type AvanteSupportedProvider
    copilot = {
      endpoint = "https://api.githubcopilot.com",
      model = "gpt-4o-2024-11-20",
      proxy = nil, -- [protocol://]host[:port] Use this proxy
      allow_insecure = false, -- Allow insecure server connections
      timeout = 30000, -- Timeout in milliseconds
      context_window = 64000, -- Number of tokens to send to the model for context
      use_response_api = copilot_use_response_api, -- Automatically switch to Response API for GPT-5 Codex models
      support_previous_response_id = false, -- Copilot doesn't support previous_response_id, must send full history
      -- NOTE: Copilot doesn't support previous_response_id, always sends full conversation history including tool_calls
      -- NOTE: Response API doesn't support some parameters like top_p, frequency_penalty, presence_penalty
      extra_request_body = {
        -- temperature is not supported by Response API for reasoning models
        max_tokens = 20480,
      },
    },
    ---@type AvanteAzureProvider
    azure = {
      endpoint = "", -- example: "https://<your-resource-name>.openai.azure.com"
      deployment = "", -- Azure deployment name (e.g., "gpt-4o", "my-gpt-4o-deployment")
      api_version = "2024-12-01-preview",
      timeout = 30000, -- Timeout in milliseconds, increase this for reasoning models
      extra_request_body = {
        temperature = 0.75,
        max_completion_tokens = 16384, -- Increase this toinclude reasoning tokens (for reasoning models); but too large default value will not fit for some models (e.g. gpt-5-chat supports at most 16384 completion tokens)
        reasoning_effort = "medium", -- low|medium|high, only used for reasoning models
      },
    },
    ---@type AvanteSupportedProvider
    claude = {
      endpoint = "https://api.anthropic.com",
      model = "claude-sonnet-4-5-20250929",
      timeout = 30000, -- Timeout in milliseconds
      context_window = 200000,
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 64000,
      },
    },
    ---@type AvanteSupportedProvider
    bedrock = {
      model = "us.anthropic.claude-3-7-sonnet-20250219-v1:0",
      model_names = {
        "anthropic.claude-3-5-sonnet-20241022-v2:0",
        "us.anthropic.claude-3-7-sonnet-20250219-v1:0",
        "us.anthropic.claude-opus-4-20250514-v1:0",
        "us.anthropic.claude-opus-4-1-20250805-v1:0",
        "us.anthropic.claude-sonnet-4-20250514-v1:0",
      },
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 20480,
      },
      aws_region = "", -- AWS region to use for authentication and bedrock API
      aws_profile = "", -- AWS profile to use for authentication, if unspecified uses default credentials chain
    },
    ---@type AvanteSupportedProvider
    gemini = {
      endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
      model = "gemini-2.0-flash",
      timeout = 30000, -- Timeout in milliseconds
      context_window = 1048576,
      use_ReAct_prompt = true,
      extra_request_body = {
        generationConfig = {
          temperature = 0.75,
        },
      },
    },
    ---@type AvanteSupportedProvider
    vertex = {
      endpoint = "https://aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/LOCATION/publishers/google/models",
      model = "gemini-1.5-flash-002",
      timeout = 30000, -- Timeout in milliseconds
      context_window = 1048576,
      use_ReAct_prompt = true,
      extra_request_body = {
        generationConfig = {
          temperature = 0.75,
        },
      },
    },
    ---@type AvanteSupportedProvider
    cohere = {
      endpoint = "https://api.cohere.com/v2",
      model = "command-r-plus-08-2024",
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 20480,
      },
    },
    ---@type AvanteSupportedProvider
    ollama = {
      endpoint = "http://127.0.0.1:11434",
      timeout = 30000, -- Timeout in milliseconds
      use_ReAct_prompt = true,
      extra_request_body = {
        options = {
          temperature = 0.75,
          num_ctx = 20480,
          keep_alive = "5m",
        },
      },
    },
    ---@type AvanteSupportedProvider
    watsonx_code_assistant = {
      endpoint = "https://api.dataplatform.cloud.ibm.com/v2/wca/core/chat/text/generation",
      model = "granite-8b-code-instruct",
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        -- Additional watsonx-specific parameters can be added here
      },
    },

    ---@type AvanteSupportedProvider
    vertex_claude = {
      endpoint = "https://LOCATION-aiplatform.googleapis.com/v1/projects/PROJECT_ID/locations/LOCATION/publishers/anthropic/models",
      model = "claude-3-5-sonnet-v2@20241022",
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 20480,
      },
    },
    ---@type AvanteSupportedProvider
    ["claude-haiku"] = {
      __inherited_from = "claude",
      model = "claude-3-5-haiku-20241022",
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 8192,
      },
    },
    ---@type AvanteSupportedProvider
    ["claude-opus"] = {
      __inherited_from = "claude",
      model = "claude-3-opus-20240229",
      timeout = 30000, -- Timeout in milliseconds
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 20480,
      },
    },
    ["openai-gpt-4o-mini"] = {
      __inherited_from = "openai",
      model = "gpt-4o-mini",
    },
    aihubmix = {
      __inherited_from = "openai",
      endpoint = "https://aihubmix.com/v1",
      model = "gpt-4o-2024-11-20",
      api_key_name = "AIHUBMIX_API_KEY",
    },
    ["aihubmix-claude"] = {
      __inherited_from = "claude",
      endpoint = "https://aihubmix.com",
      model = "claude-3-7-sonnet-20250219",
      api_key_name = "AIHUBMIX_API_KEY",
    },
    morph = {
      __inherited_from = "openai",
      endpoint = "https://api.morphllm.com/v1",
      model = "auto",
      api_key_name = "MORPH_API_KEY",
    },
    moonshot = {
      __inherited_from = "openai",
      endpoint = "https://api.moonshot.ai/v1",
      model = "kimi-k2-0711-preview",
      api_key_name = "MOONSHOT_API_KEY",
    },
    xai = {
      __inherited_from = "openai",
      endpoint = "https://api.x.ai/v1",
      model = "grok-code-fast-1",
      api_key_name = "XAI_API_KEY",
    },
    glm = {
      __inherited_from = "openai",
      endpoint = "https://open.bigmodel.cn/api/coding/paas/v4",
      model = "GLM-4.6",
      api_key_name = "GLM_API_KEY",
    },
    qwen = {
      __inherited_from = "openai",
      endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1",
      model = "qwen3-coder-plus",
      api_key_name = "DASHSCOPE_API_KEY",
    },
  },
  ---Specify the special dual_boost mode
  ---1. enabled: Whether to enable dual_boost mode. Default to false.
  ---2. first_provider: The first provider to generate response. Default to "openai".
  ---3. second_provider: The second provider to generate response. Default to "claude".
  ---4. prompt: The prompt to generate response based on the two reference outputs.
  ---5. timeout: Timeout in milliseconds. Default to 60000.
  ---How it works:
  --- When dual_boost is enabled, avante will generate two responses from the first_provider and second_provider respectively. Then use the response from the first_provider as provider1_output and the response from the second_provider as provider2_output. Finally, avante will generate a response based on the prompt and the two reference outputs, with the default Provider as normal.
  ---Note: This is an experimental feature and may not work as expected.
  dual_boost = {
    enabled = false,
    first_provider = "openai",
    second_provider = "claude",
    prompt = "Based on the two reference outputs below, generate a response that incorporates elements from both but reflects your own judgment and unique perspective. Do not provide any explanation, just give the response directly. Reference Output 1: [{{provider1_output}}], Reference Output 2: [{{provider2_output}}]",
    timeout = 60000, -- Timeout in milliseconds
  },
  ---Specify the behaviour of avante.nvim
  ---1. auto_focus_sidebar              : Whether to automatically focus the sidebar when opening avante.nvim. Default to true.
  ---2. auto_suggestions = false, -- Whether to enable auto suggestions. Default to false.
  ---3. auto_apply_diff_after_generation: Whether to automatically apply diff after LLM response.
  ---                                     This would simulate similar behaviour to cursor. Default to false.
  ---4. auto_set_keymaps                : Whether to automatically set the keymap for the current line. Default to true.
  ---                                     Note that avante will safely set these keymap. See https://github.com/yetone/avante.nvim/wiki#keymaps-and-api-i-guess for more details.
  ---5. auto_set_highlight_group        : Whether to automatically set the highlight group for the current line. Default to true.
  ---6. jump_result_buffer_on_finish = false, -- Whether to automatically jump to the result buffer after generation
  ---7. support_paste_from_clipboard    : Whether to support pasting image from clipboard. This will be determined automatically based whether img-clip is available or not.
  ---8. minimize_diff                   : Whether to remove unchanged lines when applying a code block
  ---9. enable_token_counting           : Whether to enable token counting. Default to true.
  ---10. auto_add_current_file          : Whether to automatically add the current file when opening a new chat. Default to true.
  behaviour = {
    auto_focus_sidebar = true,
    auto_suggestions = false, -- Experimental stage
    auto_suggestions_respect_ignore = false,
    auto_set_highlight_group = true,
    auto_set_keymaps = true,
    auto_apply_diff_after_generation = false,
    jump_result_buffer_on_finish = false,
    support_paste_from_clipboard = false,
    minimize_diff = true,
    enable_token_counting = true,
    use_cwd_as_project_root = false,
    auto_focus_on_diff_view = false,
    ---@type boolean | string[] -- true: auto-approve all tools, false: normal prompts, string[]: auto-approve specific tools by name
    --- Defaults to prompting. Under the Python backend agents can execute
    --- arbitrary commands via terminal/*, so auto-approving means shell access
    --- with nothing asking first. Set to true to restore the old behaviour.
    auto_approve_tool_permissions = false,
    auto_check_diagnostics = true,
    enable_fastapply = false,
    include_generated_by_commit_line = false, -- Controls if 'Generated-by: <provider/model>' line is added to git commit message
    auto_add_current_file = true, -- Whether to automatically add the current file when opening a new chat
    --- popup is the original yes,all,no in a floating window
    --- inline_buttons is the new inline buttons in the sidebar
    ---@type "popup" | "inline_buttons"
    confirmation_ui_style = "inline_buttons",
    --- Whether to automatically open files and navigate to lines when ACP agent makes edits
    ---@type boolean
    acp_follow_agent_locations = true,
    --- Default mode to set when creating a new ACP session (e.g., "plan" for plan mode)
    --- Set to nil to use whatever mode the ACP server defaults to
    ---@type string|nil
    acp_default_mode = nil,
    --- Whether to prompt before exiting when there are active ACP sessions
    ---@type boolean
    prompt_on_exit_with_active_session = false,
    --- Base directory for git worktrees created by :AvanteChatNewWorktree
    --- Set to a path like "~/worktrees" or nil to use the parent of the git root
    ---@type string|nil
    worktrees_root = nil,
    --- Additional directories to show in the :AvanteChatNew picker.
    --- Each entry is a path (~ is expanded) that appears as a directory option.
    ---@type string[]
    favorite_root_dirs = {},
    --- Status line configuration for input container
    ---@type table
    status_line = {
      enabled = true,
      position = "winbar", -- "winbar" | "floating" | "statusline" | "top" | "bottom"
      show_plan_mode = true, -- Show plan mode indicator (🗺️ PLAN or ⚡ EXEC)
      show_following_status = true, -- Show following status indicator (👁️  FOLLOW or 🔕 MANUAL)
      show_tokens = true, -- Show token count
      show_submit_key = true, -- Show submit keybinding
      show_session_info = true, -- Show session mode and ID
      show_working_directory = true, -- Show the chat's working directory
      format = nil, -- Custom format string: "{plan_mode} | {following_status} | {tokens} | {submit_key}"
    },
  },
  notifications = { -- Desktop notifications for agent completion
    enabled = true, -- Master toggle for all notifications
    notify_on_complete = true, -- Notify when agent completes successfully
    notify_on_error = true, -- Notify when agent encounters an error
    notify_on_cancel = false, -- Notify when agent is cancelled (opt-in)
    include_duration = true, -- Show task duration in notification
    include_summary = true, -- Show brief task description
    max_summary_length = 50, -- Character limit for task summary
    sound = true, -- Enable notification sound (platform-dependent)
  },
  prompt_logger = { -- logs prompts to disk with rich metadata (per-project, searchable via telescope)
    enabled = true, -- toggle logging entirely
    storage_path = Utils.join_paths(vim.fn.stdpath("state"), "avante"), -- base path for per-project prompt storage
    max_entries = 100, -- max prompts per project (0 = unlimited)
    use_index = true, -- enable index.json for fast Ctrl+N/P navigation
    auto_rebuild_index = false, -- rebuild index on init (slower but ensures accuracy)
    
    -- Usage tracking options
    track_usage = true, -- track how many times each prompt is reused
    sort_by_usage = true, -- sort prompts by usage count first, then recency
    show_usage_count = true, -- display usage count in selector
    
    -- Search options
    search_full_prompt = true, -- search full prompt content (not just preview) in Telescope
    max_keywords = 10, -- max keywords to extract for search optimization
    
    next_prompt = {
      normal = "<C-n>", -- load the next (newer) prompt log in normal mode
      insert = "<C-n>",
    },
    prev_prompt = {
      normal = "<C-p>", -- load the previous (older) prompt log in normal mode
      insert = "<C-p>",
    },

    -- Arrow-key recall of previous prompts into the input box (never submits)
    recall = {
      enabled = true,
      ---@alias AvantePromptRecallSource "thread" | "project" | "thread_then_project"
      ---@type AvantePromptRecallSource
      source = "thread_then_project", -- this thread's prompts newest-first, then the project-wide log
      edge_only = true, -- only recall when the cursor cannot move further up/down
      prev = {
        normal = "<Up>", -- load the previous (older) prompt
        insert = "<Up>",
      },
      next = {
        normal = "<Down>", -- load the next (newer) prompt
        insert = "<Down>",
      },
      -- Recall from anywhere in the buffer, ignoring edge_only. Requires a
      -- terminal that sends shift+arrow; rebind to <C-Up>/<C-Down> if not.
      force_prev = {
        normal = "<S-Up>",
        insert = "<S-Up>",
      },
      force_next = {
        normal = "<S-Down>",
        insert = "<S-Down>",
      },
    },
  },
  history = {
    max_tokens = 4096,
    carried_entry_count = nil,
    storage_path = Utils.join_paths(vim.fn.stdpath("state"), "avante"),
    paste = {
      extension = "png",
      filename = "pasted-%Y-%m-%d-%H-%M-%S",
    },
    --- Template for ACP session titles. Use {{message}} for the first user message.
    --- Example: "{{message}} (managed by avante)"
    ---@type string|nil
    session_title_template = "{{message}} (managed by avante)",
  },
  highlights = {
    diff = {
      current = nil,
      incoming = nil,
    },
  },
  img_paste = {
    url_encode_path = true,
    template = "\nimage: $FILE_PATH\n",
  },
  mappings = {
    ---@class AvanteConflictMappings
    diff = {
      ours = "co",
      theirs = "ct",
      all_theirs = "ca",
      both = "cb",
      cursor = "cc",
      next = "]x",
      prev = "[x",
    },
    suggestion = {
      accept = "<M-l>",
      next = "<M-]>",
      prev = "<M-[>",
      dismiss = "<C-]>",
    },
    jump = {
      next = "]]",
      prev = "[[",
    },
    submit = {
      normal = "<CR>",
      insert = "<C-s>",
    },
    cancel = {
      normal = { "<C-c>", "<Esc>", "q" },
      insert = { "<C-c>" },
    },
    -- NOTE: The following will be safely set by avante.nvim
    ask = "<leader>aa",
    new_ask = "<leader>an",
    zen_mode = "<leader>az",
    edit = "<leader>ae",
    refresh = "<leader>ar",
    focus = "<leader>af",
    stop = "<leader>aS",
    toggle = {
      default = "<leader>at",
      debug = "<leader>ad",
      selection = "<leader>aC",
      suggestion = "<leader>as",
      repomap = "<leader>aR",
    },
    sidebar = {
      cycle_mode = "<S-Tab>",
      expand_tool_use = "<C-e>",
      -- Fold-style, mirroring vim's za/zM/zR. `expand_tool_use` stays bound to
      -- the tool call under the cursor; these act on whole messages.
      toggle_message_collapse = "za",
      collapse_all_messages = "zM",
      expand_all_messages = "zR",
      next_prompt = "]p",
      prev_prompt = "[p",
      apply_all = "A",
      apply_cursor = "a",
      retry_user_request = "r",
      edit_user_request = "e",
      switch_windows = "<Tab>",
      reverse_switch_windows = "<C-S-Tab>",
      toggle_code_window = "x",
      toggle_plan = "<D-t>",
      toggle_fullscreen_edit = "<S-f>",
      toggle_input_fullscreen = "<C-f>",
      remove_file = "d",
      add_file = "@",
      close = { "q" },
      ---@alias AvanteCloseFromInput { normal: string | nil, insert: string | nil }
      ---@type AvanteCloseFromInput | nil
      close_from_input = nil, -- e.g., { normal = "<Esc>", insert = "<C-d>" }
      ---@alias AvanteToggleCodeWindowFromInput { normal: string | nil, insert: string | nil }
      ---@type AvanteToggleCodeWindowFromInput | nil
      toggle_code_window_from_input = nil, -- e.g., { normal = "x", insert = "<C-;>" }
    },
    files = {
      add_current = "<leader>ac", -- Add current buffer to selected files
      add_all_buffers = "<leader>aB", -- Add all buffer files to selected files
    },
    select_model = "<leader>a?", -- Select model command
    select_history = "<leader>ah", -- Select history command
    select_prompt = "<leader>ap", -- Select and reuse prompt command
    confirm = {
      focus_window = "<C-w>f",
      code = "c",
      resp = "r",
      input = "i",
    },
  },
  windows = {
    ---@alias AvantePosition "right" | "left" | "top" | "bottom" | "smart"
    ---@type AvantePosition
    position = "right",
    fillchars = "eob: ",
    wrap = true, -- similar to vim.o.wrap
    width = 30, -- default % based on available width in vertical layout
    height = 30, -- default % based on available height in horizontal layout
    sidebar_header = {
      enabled = true, -- true, false to enable/disable the header
      align = "center", -- left, center, right for title
      rounded = true,
    },
    spinner = {
      editing = {
        "⡀",
        "⠄",
        "⠂",
        "⠁",
        "⠈",
        "⠐",
        "⠠",
        "⢀",
        "⣀",
        "⢄",
        "⢂",
        "⢁",
        "⢈",
        "⢐",
        "⢠",
        "⣠",
        "⢤",
        "⢢",
        "⢡",
        "⢨",
        "⢰",
        "⣰",
        "⢴",
        "⢲",
        "⢱",
        "⢸",
        "⣸",
        "⢼",
        "⢺",
        "⢹",
        "⣹",
        "⢽",
        "⢻",
        "⣻",
        "⢿",
        "⣿",
      },
      generating = { "·", "✢", "✳", "∗", "✻", "✽" },
      thinking = { "🤯", "🙄" },
    },
    input = {
      prefix = "> ",
      height = 8, -- Height of the input window in vertical layout
      textwidth = 0, -- 0 = never hard-wrap what you type. Set a number to restore auto-wrapping.
      formatoptions = "jql", -- omits 't' (auto-wrap) and 'a' (paragraph reflow) so typing is never reformatted
    },
    selected_files = {
      height = 6, -- Maximum height of the selected files window
    },
    edit = {
      border = { " ", " ", " ", " ", " ", " ", " ", " " },
      start_insert = true, -- Start insert mode when opening the edit window
    },
    ask = {
      floating = false, -- Open the 'AvanteAsk' prompt in a floating window
      border = { " ", " ", " ", " ", " ", " ", " ", " " },
      start_insert = true, -- Start insert mode when opening the ask window
      ---@alias AvanteInitialDiff "ours" | "theirs"
      ---@type AvanteInitialDiff
      focus_on_apply = "ours", -- which diff to focus after applying
    },
  },
  --- @class AvanteConflictConfig
  diff = {
    autojump = true,
    --- Override the 'timeoutlen' setting while hovering over a diff (see :help timeoutlen).
    --- Helps to avoid entering operator-pending mode with diff mappings starting with `c`.
    --- Disable by setting to -1.
    override_timeoutlen = 500,
  },
  --- Allows selecting code or other data in a buffer and ask LLM questions about it or
  --- to perform edits/transformations.
  --- @class AvanteSelectionConfig
  --- @field enabled boolean
  --- @field hint_display "delayed" | "immediate" | "none" When to show key map hints.
  selection = {
    enabled = true,
    hint_display = "delayed",
  },
  --- @class AvanteRepoMapConfig
  repo_map = {
    ignore_patterns = { "%.git", "%.worktree", "__pycache__", "node_modules" }, -- ignore files matching these
    negate_patterns = {}, -- negate ignore files matching these.
  },
  --- @class AvanteFileSelectorConfig
  file_selector = {
    provider = nil,
    -- Options override for custom providers
    provider_opts = {},
    --- When adding a directory, should it recursively add all files or just add the directory path?
    --- "recursive": Add all files in the directory (default, original behavior)
    --- "directory": Add only the directory path itself
    ---@type "recursive" | "directory"
    directory_mode = "directory",
  },
  selector = {
    ---@alias avante.SelectorProvider "native" | "fzf_lua" | "mini_pick" | "snacks" | "telescope" | fun(selector: avante.ui.Selector): nil
    ---@type avante.SelectorProvider
    provider = "telescope",
    provider_opts = {},
    exclude_auto_select = {}, -- List of items to exclude from auto selection
  },
  input = {
    provider = "native",
    provider_opts = {},
  },
  suggestion = {
    debounce = 600,
    throttle = 600,
  },
  disabled_tools = {}, ---@type string[]
  ---@type AvanteLLMToolPublic[] | fun(): AvanteLLMToolPublic[]
  custom_tools = {},
  --- Templates for a new chat. Each may pin an ACP provider and a starter
  --- prompt, so picking one both configures the agent and opens with a first
  --- message already sent.
  ---@class AvanteMode
  ---@field name string
  ---@field description string
  ---@field prompt string|nil extra system prompt; nil uses the built-in plan prompt
  ---@field additional_files string[]|nil
  ---@field acp_provider string|nil key into `acp_providers`, overrides `provider` for this chat
  ---@field starter_prompt string|nil sent automatically once the session is ready
  ---@type AvanteMode[]
  avante_modes = {
    {
      name = "plan",
      description = "Build a detailed plan before executing",
      prompt = nil, -- nil = uses built-in get_plan_mode_prompt()
      additional_files = {},
    },
    {
      name = "one-shot",
      description = "Quick fix or single task, minimal overhead",
      prompt = "Focus on completing the requested task directly and efficiently. Do not over-plan or over-explain. Make the change and be done.",
      additional_files = {},
    },
    {
      name = "review",
      description = "Review changes and provide feedback",
      prompt = "You are in code review mode. Analyze the provided code carefully. Provide specific, actionable feedback on code quality, potential bugs, and improvements. Do not make changes unless asked.",
      additional_files = {},
    },
  },
  ---@type string|nil Default avante mode for new chats (nil = show picker)
  default_avante_mode = nil,
  --- Offer an ACP provider picker when starting a chat. A template's
  --- `acp_provider` wins over the picker; the picker is skipped when fewer
  --- than two ACP providers are configured.
  ---@type boolean
  ask_acp_provider_on_new_chat = true,
  --- Collapse older messages when opening an existing thread, leaving only the
  --- most recent expanded.
  ---@type boolean
  collapse_threads_on_open = true,
  ---@type AvanteSlashCommand[]
  slash_commands = {},
  ---@type boolean Enable passthrough of unknown slash commands to ACP agent
  enable_acp_command_passthrough = true,
  ---@type string[] Commands that should only be handled locally (never sent to ACP)
  local_only_commands = { "clear", "new", "help", "init", "compact", "avante-modes" },
  ---@type boolean Auto-clear input buffer after slash command is submitted
  auto_clear_slash_commands = true,
  ---@type string | nil Path to directory containing .mdx shortcut files
  shortcuts_directory = nil,
  ---@type AvanteShortcut[]
  shortcuts = {},
  ---@type AskOptions
  ask_opts = {},
}

---@type avante.Config
---@diagnostic disable-next-line: missing-fields
M._options = {}

local function get_config_dir_path() return Utils.join_paths(vim.fn.expand("~"), ".config", "avante.nvim") end
local function get_config_file_path() return Utils.join_paths(get_config_dir_path(), "config.json") end

--- Function to save the last used model
---@param model_name string
function M.save_last_model(model_name, provider_name)
  local config_dir = get_config_dir_path()
  local storage_path = get_config_file_path()

  if not Utils.path_exists(config_dir) then vim.fn.mkdir(config_dir, "p") end

  local Providers = require("avante.providers")
  local provider = Providers[provider_name]
  local provider_model = provider and provider.model

  local file = io.open(storage_path, "w")
  if file then
    file:write(
      vim.json.encode({ last_model = model_name, last_provider = provider_name, provider_model = provider_model })
    )
    file:close()
  end
end

--- Retrieves names of the last used model and provider. May remove saved config if it is deemed invalid
---@param known_providers table<string, AvanteSupportedProvider>
---@return string|nil Model name
---@return string|nil Provider name
function M.get_last_used_model(known_providers)
  local storage_path = get_config_file_path()
  local file = io.open(storage_path, "r")
  if file then
    local content = file:read("*a")
    file:close()

    if not content or content == "" then
      Utils.warn("Last used model file is empty: " .. storage_path)
      -- Remove to not have repeated warnings
      os.remove(storage_path)
    end

    local success, data = pcall(vim.json.decode, content)
    if not success or not data or not data.last_model or data.last_model == "" or data.last_provider == "" then
      Utils.warn("Invalid or corrupt JSON in last used model file: " .. storage_path)
      -- Rename instead of deleting so user can examine contents
      os.rename(storage_path, storage_path .. ".bad")
      return
    end

    if data.last_provider then
      local provider = known_providers[data.last_provider]
      if not provider then
        Utils.warn(
          "Provider " .. data.last_provider .. " is no longer a valid provider, falling back to default configuration"
        )
        os.remove(storage_path)
        return
      end
      if data.provider_model and provider.model and provider.model ~= data.provider_model then
        return provider.model, data.last_provider
      end
    end

    return data.last_model, data.last_provider
  end
end

---Applies given model and provider to the config
---@param config avante.Config
---@param model_name string
---@param provider_name? string
local function apply_model_selection(config, model_name, provider_name)
  local provider_list = config.providers or {}
  local current_provider_name = config.provider
  if config.acp_providers[current_provider_name] then return end

  local target_provider_name = provider_name or current_provider_name
  local target_provider = provider_list[target_provider_name]

  if not target_provider then return end

  local current_provider_data = provider_list[current_provider_name]
  local current_model_name = current_provider_data and current_provider_data.model

  if target_provider_name ~= current_provider_name or model_name ~= current_model_name then
    config.provider = target_provider_name
    target_provider.model = model_name
    if not target_provider.model_names then target_provider.model_names = {} end
    for _, model_name_ in ipairs({ model_name, current_model_name }) do
      if not vim.tbl_contains(target_provider.model_names, model_name_) then
        table.insert(target_provider.model_names, model_name_)
      end
    end
    Utils.info(string.format("Using previously selected model: %s/%s", target_provider_name, model_name))
  end
end

---Normalize submit configuration to support both simple strings and double-tap mode
---@param submit_config string | { key: string, mode: "single" | "double_tap", timeout: number }
---@return { key: string, mode: "single" | "double_tap", timeout: number }
local function normalize_submit_config(submit_config)
  if type(submit_config) == "string" then
    return { key = submit_config, mode = "single", timeout = 300 }
  elseif type(submit_config) == "table" then
    local normalized = vim.tbl_extend("force", {
      mode = "single",
      timeout = 300,
    }, submit_config)
    
    -- Backward compatibility: if no 'key' field, it might be the old format
    if not normalized.key then
      error("Invalid submit config: must specify 'key' field when using table format")
    end
    
    return normalized
  else
    error("Invalid submit config: must be a string or table")
  end
end

---@param opts table<string, any>|nil -- Optional table parameter for configuration settings
function M.setup(opts)
  opts = opts or {} -- Ensure `opts` is defined with a default table
  if vim.fn.has("nvim-0.11") == 1 then
    vim.validate("opts", opts, "table", true)
  else
    vim.validate({ opts = { opts, "table", true } })
  end

  opts = opts or {}

  local migration_url = "https://github.com/yetone/avante.nvim/wiki/Provider-configuration-migration-guide"

  if opts.providers ~= nil then
    for k, v in pairs(opts.providers) do
      local extra_request_body
      if type(v) == "table" then
        if M._defaults.providers[k] ~= nil then
          extra_request_body = M._defaults.providers[k].extra_request_body
        elseif v.__inherited_from ~= nil then
          if M._defaults.providers[v.__inherited_from] ~= nil then
            extra_request_body = M._defaults.providers[v.__inherited_from].extra_request_body
          end
        end
      end
      if extra_request_body ~= nil then
        for k_, v_ in pairs(v) do
          if extra_request_body[k_] ~= nil then
            opts.providers[k].extra_request_body = opts.providers[k].extra_request_body or {}
            opts.providers[k].extra_request_body[k_] = v_
            Utils.warn(
              string.format(
                "[DEPRECATED] The configuration of `providers.%s.%s` should be placed in `providers.%s.extra_request_body.%s`; for detailed migration instructions, please visit: %s",
                k,
                k_,
                k,
                k_,
                migration_url
              ),
              { title = "Avante" }
            )
          end
        end
      end
    end
  end

  for k, v in pairs(opts) do
    if M._defaults.providers[k] ~= nil then
      opts.providers = opts.providers or {}
      opts.providers[k] = v
      Utils.warn(
        string.format(
          "[DEPRECATED] The configuration of `%s` should be placed in `providers.%s`. For detailed migration instructions, please visit: %s",
          k,
          k,
          migration_url
        ),
        { title = "Avante" }
      )
      local extra_request_body = M._defaults.providers[k].extra_request_body
      if type(v) == "table" and extra_request_body ~= nil then
        for k_, v_ in pairs(v) do
          if extra_request_body[k_] ~= nil then
            opts.providers[k].extra_request_body = opts.providers[k].extra_request_body or {}
            opts.providers[k].extra_request_body[k_] = v_
            Utils.warn(
              string.format(
                "[DEPRECATED] The configuration of `%s.%s` should be placed in `providers.%s.extra_request_body.%s`; for detailed migration instructions, please visit: %s",
                k,
                k_,
                k,
                k_,
                migration_url
              ),
              { title = "Avante" }
            )
          end
        end
      end
    end
    if k == "vendors" and v ~= nil then
      for k2, v2 in pairs(v) do
        opts.providers = opts.providers or {}
        opts.providers[k2] = v2
        Utils.warn(
          string.format(
            "[DEPRECATED] The configuration of `vendors.%s` should be placed in `providers.%s`. For detailed migration instructions, please visit: %s",
            k2,
            k2,
            migration_url
          ),
          { title = "Avante" }
        )
        if
          type(v2) == "table"
          and v2.__inherited_from ~= nil
          and M._defaults.providers[v2.__inherited_from] ~= nil
        then
          local extra_request_body = M._defaults.providers[v2.__inherited_from].extra_request_body
          if extra_request_body ~= nil then
            for k2_, v2_ in pairs(v2) do
              if extra_request_body[k2_] ~= nil then
                opts.providers[k2].extra_request_body = opts.providers[k2].extra_request_body or {}
                opts.providers[k2].extra_request_body[k2_] = v2_
                Utils.warn(
                  string.format(
                    "[DEPRECATED] The configuration of `vendors.%s.%s` should be placed in `providers.%s.extra_request_body.%s`; for detailed migration instructions, please visit: %s",
                    k2,
                    k2_,
                    k2,
                    k2_,
                    migration_url
                  ),
                  { title = "Avante" }
                )
              end
            end
          end
        end
      end
    end
  end

  local merged = vim.tbl_deep_extend(
    "force",
    M._defaults,
    opts,
    ---@type avante.Config
    {
      behaviour = {
        support_paste_from_clipboard = M.support_paste_image(),
      },
    }
  )

  local last_model, last_provider = M.get_last_used_model(merged.providers or {})
  if last_model then apply_model_selection(merged, last_model, last_provider) end

  -- Normalize submit configuration for backward compatibility and double-tap support
  if merged.mappings and merged.mappings.submit then
    merged.mappings.submit.normal = normalize_submit_config(merged.mappings.submit.normal)
    merged.mappings.submit.insert = normalize_submit_config(merged.mappings.submit.insert)
  end

  M._options = merged

  -- Remember which ACP providers the user actually declared. `acp_providers` is
  -- a deep merge with the built-in table, so the merged result always lists
  -- every agent avante knows about -- including ones not installed. The picker
  -- offers only what the config file names.
  M._user_acp_provider_names = vim.tbl_keys(opts.acp_providers or {})
  table.sort(M._user_acp_provider_names)

  ---@diagnostic disable-next-line: undefined-field
  if M._options.disable_tools ~= nil then
    Utils.warn(
      "`disable_tools` is provider-scoped, not globally scoped. Therefore, you cannot set `disable_tools` at the top level. It should be set under a provider, for example: `openai.disable_tools = true`",
      { title = "Avante" }
    )
  end

  if type(M._options.disabled_tools) == "boolean" then
    Utils.warn(
      '`disabled_tools` must be a list, not a boolean. Please change it to `disabled_tools = { "tool1", "tool2" }`. Note the difference between `disabled_tools` and `disable_tools`.',
      { title = "Avante" }
    )
  end

  if vim.fn.has("nvim-0.11") == 1 then
    vim.validate("provider", M._options.provider, "string", false)
  else
    vim.validate({ provider = { M._options.provider, "string", false } })
  end

  for k, v in pairs(M._options.providers) do
    M._options.providers[k] = type(v) == "function" and v() or v
  end
end

---@param opts table<string, any>
function M.override(opts)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.validate("opts", opts, "table", true)
  else
    vim.validate({ opts = { opts, "table", true } })
  end

  M._options = vim.tbl_deep_extend("force", M._options, opts or {})

  for k, v in pairs(M._options.providers) do
    M._options.providers[k] = type(v) == "function" and v() or v
  end
end

M = setmetatable(M, {
  __index = function(_, k)
    if M._options[k] then return M._options[k] end
  end,
})

function M.support_paste_image() return Utils.has("img-clip.nvim") or Utils.has("img-clip") end

function M.get_window_width() return math.ceil(vim.o.columns * (M.windows.width / 100)) end

---get supported providers
---@param provider_name avante.ProviderName
function M.get_provider_config(provider_name)
  local found = false
  local config = {}

  if M.providers[provider_name] ~= nil then
    found = true
    config = vim.tbl_deep_extend("force", config, vim.deepcopy(M.providers[provider_name], true))
  end

  if not found then error("Failed to find provider: " .. provider_name, 2) end

  return config
end

return M