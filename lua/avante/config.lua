---@mod vim.g.avante Configuration via variable
---
---@brief [[
---The recommended way to configure avante.nvim is to use the global variable
---vim.g.avante . The setup() function still needs to be called.
--->lua
--- vim.g.avante = {
---   log_level =  vim.log.levels.ERROR,
---   -- Example: Using snacks.nvim as input provider
---   input = {
---     provider = "snacks", -- "native" | "snacks"
---     provider_opts = {
---       -- Snacks input configuration
---       title = "Avante Input",
---       icon = " ",
---       placeholder = "Enter your API key...",
---     },
---   },
---   -- Your other config here!
--- })
---<
---@brief ]]
---@see avante.Config
---
---@mod avante-config Configuration
---
---@brief [[
---
---Recommended Neovim option:
---
--->lua
---   vim.opt.laststatus = 3
---<
---
---Call `require("avante").setup()` from your Neovim configuration.
---
---Common options:
---
--->lua
---   require("avante").setup({
---     provider = "claude",
---     mode = "agentic",
---     instructions_file = "avante.md",
---     providers = {
---       claude = {
---         endpoint = "https://api.anthropic.com",
---         model = "claude-sonnet-4-20250514",
---         timeout = 30000,
---         extra_request_body = {
---           temperature = 0.75,
---           max_tokens = 20480,
---         },
---       },
---     },
---     behaviour = {
---       auto_suggestions = false,
---       auto_set_highlight_group = true,
---       auto_set_keymaps = true,
---       auto_apply_diff_after_generation = false,
---       support_paste_from_clipboard = false,
---       minimize_diff = true,
---       enable_token_counting = true,
---       auto_add_current_file = true,
---       auto_approve_tool_permissions = true,
---       confirmation_ui_style = "inline_buttons",
---       acp_follow_agent_locations = true,
---     },
---     windows = {
---       position = "right",
---       wrap = true,
---       width = 30,
---     },
---   })
---<
---
---For the full default configuration, see `lua/avante/config.lua`.
---
---Input providers
---
---Avante supports different interfaces that act as *vim.ui.input()*. See *avante.AvanteInput* for the supported options, here is :
--->
---   require("avante").setup({
---     input = {
---       provider = "snacks",
---       provider_opts = {
---         title = "Avante Input",
---         icon = " ",
---       },
---     },
---   })
---<
---
---Selector providers
---
---Avante supports `native`, `fzf_lua`, `mini_pick`, `snacks`, `telescope`, or
---a custom function:
--->
---   require("avante").setup({
---     selector = {
---       provider = "fzf_lua",
---       provider_opts = {},
---     },
---   })
---<
---
---
---Fast Apply
---
---Fast Apply uses a specialized apply model for faster code edits. Enable it
---and configure Morph:
--->
---   require("avante").setup({
---     behaviour = {
---       enable_fastapply = true,
---     },
---     providers = {
---       morph = {
---         model = "morph-v3-large",
---       },
---     },
---   })
---<
---
---Set:
--->
---   export MORPH_API_KEY="your-api-key"
---<
---
---Configure ACP providers with `acp_providers`:
---
--->lua
---   require("avante").setup({
---     acp_providers = {
---       ["gemini-cli"] = {
---         command = "gemini",
---         args = { "--experimental-acp" },
---         env = {
---           NODE_NO_WARNINGS = "1",
---           GEMINI_API_KEY = os.getenv("GEMINI_API_KEY"),
---         },
---       },
---       ["codex"] = {
---         command = "codex-acp",
---         args = {},
---         env = {
---           NODE_NO_WARNINGS = "1",
---           OPENAI_API_KEY = os.getenv("OPENAI_API_KEY"),
---         },
---       },
---     },
---   })
---<
---
---Select an ACP-backed provider with |:AvanteSwitchProvider|.
---
---You can also set avante options via `vim.g.avante`.
---
---@brief ]]

---NOTE: user will be merged with defaults and
---we add a default var_accessor for this table to config values.

---@class avante.Config.WebSearchEngine
---Avante tools can use web search engines.
---@field proxy? string Proxy URL used for web search requests.

---@alias avante.InputProvider
---| '"native"'
---| '"dressing"'
---| '"snacks"'
---| `fun(input: avante.ui.Input): nil`

local Utils = require("avante.utils")

local function copilot_use_response_api(opts)
  local model = opts and opts.model
  return type(model) == "string" and model:match("gpt%-%d+%.?%d*%-codex") ~= nil
end

---@alias avante.ProviderName "claude" | "openai" | "azure" | "gemini" | "vertex" | "cohere" | "copilot" | "bedrock" | "ollama" | "watsonx_code_assistant" | "mistral" | string

---@class avante.file_selector.IParams
---@field public title      string
---@field public filepaths  string[]
---@field public handler    fun(filepaths: string[]|nil): nil

---@class avante.file_selector.opts.IGetFilepathsParams
---@field public cwd                string
---@field public selected_filepaths string[]

---@class avante.Config.Behaviour
---@field auto_focus_sidebar? boolean Automatically focus the sidebar when opening Avante.
---@field auto_suggestions? boolean Enable automatic suggestions (defaults to false because experimental)
---@field auto_suggestions_respect_ignore? boolean Respect ignore rules for automatic suggestions.
---@field auto_set_highlight_group? boolean Automatically set Avante highlight groups.
---@field auto_set_keymaps? boolean Automatically install default keymaps when they do not conflict.
---@field auto_apply_diff_after_generation? boolean Automatically apply diffs after an LLM response.
---@field jump_result_buffer_on_finish? boolean Jump to the result buffer after generation finishes.
---@field support_paste_from_clipboard? boolean Enable image paste support from clipboard when img-clip.nvim is available.
---@field minimize_diff? boolean Remove unchanged lines when applying a code block.
---@field enable_token_counting? boolean Enable token counting.
---Some APIs return the number of tokens consumed.
---@field use_cwd_as_project_root? boolean Use the current working directory as project root.
---@field auto_focus_on_diff_view? boolean Focus the diff view automatically.
---@field auto_approve_tool_permissions? boolean|string[] Auto-approve all tools, no tools, or only specific tool names.
---@field auto_check_diagnostics? boolean Automatically check diagnostics.
---@field allow_access_to_git_ignored_files? boolean Allow tools to access git-ignored files.
---@field enable_fastapply boolean Enable the fast-apply model flow.
---@field include_generated_by_commit_line? boolean Controls if 'Generated-by: <provider/model>' line is added to git commit message
---@field auto_add_current_file? boolean Automatically add the current file when opening a new chat.
---@field confirmation_ui_style? "popup"|"inline_buttons" Tool permission confirmation UI style.
--- popup is the original yes,all,no in a floating window
--- inline_buttons is the new inline buttons in the sidebar
---@field acp_follow_agent_locations? boolean Open files and navigate to lines when ACP agents make edits.

---@class avante.Config.PromptLoggerKeymap
---@field normal? string Normal-mode mapping.
---@field insert? string Insert-mode mapping.

---@class avante.Config.PromptLogger
---@field enabled? boolean Enable prompt logging.
---@field log_dir string Directory where prompt logs are saved.
---@field max_entries? integer Maximum number of prompt log entries to keep.
---@field next_prompt? avante.Config.PromptLoggerKeymap Mapping used to load the next newer prompt log.
---@field prev_prompt? avante.Config.PromptLoggerKeymap Mapping used to load the previous older prompt log.

---@class avante.Config.RagServiceModel
---@field provider string Model provider. One available in py/rag-service/src/providers ie., "ollama", "openai", "dashscope", "openrouter"
---@field endpoint string Model API endpoint (e.g., http://localhost)
---@field api_key string Environment variable name for the model API key.
---@field model string Model name
---@field extra? table Additional model provider options.

---@class avante.Config.RagService
---@field enabled boolean Enable the RAG service.
---@field host_mount string? Host path mounted read-only for the RAG service.
---@field runner "docker"|"nix"|string Runner used to launch the RAG service.
---@field image? string Docker image used when runner is `docker`.
---@field llm avante.Config.RagServiceModel Language model configuration.
---@field embed avante.Config.RagServiceModel Embedding model configuration.
---@field docker_extra_args string Extra arguments passed to `docker run`.

---@class avante.CoreConfig: avante.Config
local M = {}

--- Default configuration for project-specific instruction file
M.instructions_file = "avante.md"

---@class avante.Config
---@field debug boolean
--- will keep requests and responses on the filesystem. Check the logs to find their paths
---@field log_level vim.log.levels
---@field public session_recovery any
--- Avante.nvim provides two interaction modes:
--- - *agentic* (default): Uses AI tools to automatically generate and apply code changes
--- - *legacy*: Uses the traditional planning method without automatic tool execution
---
--- **When should you use legacy mode?**
--- - If you prefer more control over what actions the AI takes
--- - If you're concerned about security with automatic tool execution
--- - If you want to manually review each step before applying changes
--- - If you're working in a sensitive environment where automatic code changes aren't desired
---@field mode avante.Mode
--- WARNING: Since auto-suggestions are a high-frequency operation and therefore expensive,
--- currently designating it as `copilot` provider is dangerous because: https://github.com/yetone/avante.nvim/issues/1048
--- Of course, you can reduce the request frequency by increasing `suggestion.debounce`.
---@field auto_suggestions_provider? boolean
---To add support for custom provider, follow the format below
---See https://github.com/yetone/avante.nvim/wiki#custom-providers for more details
---@field providers {string: AvanteProvider}
---Agent Client Protocol providers.  |avante-acp|
---@field acp_providers {string: AvanteACPProvider}
---
---Default provider on startup. If undefined, avante loads the last provider used.
---@field provider? avante.ProviderName
---
---System prompt
---@field system_prompt? string | nil | fun(): string
--- override_prompt_dir allows you to specify a directory containing your own custom prompt templates, which will override the built-in templates. This is useful if you want to maintain a set of custom prompts outside of your Neovim configuration.
---<lua
--- -- Example: Override with prompts from a specific directory
--- require("avante").setup({
---   override_prompt_dir = vim.fn.expand("~/.config/nvim/avante_prompts"),
--- })
---
--- -- Example: Override with prompts from a function (dynamic directory)
--- require("avante").setup({
---   override_prompt_dir = function()
---     -- Your logic to determine the prompt directory
---     return vim.fn.expand("~/.config/nvim/my_dynamic_prompts")
---   end,
--- })
---<
---@field override_prompt_dir string | nil | fun(): string
---@field rules table
---
---@field rag_service avante.Config.RagService RAG service configuration.
---@field web_search_engine avante.Config.WebSearchEngine Web search configuration.
---@field behaviour avante.Config.Behaviour Behaviour and automation options.
---@field prompt_logger avante.Config.PromptLogger Prompt logging options.
---@field windows table
---@field disabled_tools string[] You can choose to disable tools by their names in case you want to avoid its usage (like Claude 3.7 overusing the python tool). For example: `{ "python" }`
---@field custom_tools AvanteSlashCommand[] see |*avante-custom-tools*|
---@field slash_commands AvanteSlashCommand[] see |*avante-slashcommands*|
---@field shortcuts AvanteShortcut[]  see |*avante-shortcuts*|
---@field ask_opts AskOptions

M._defaults = {
  debug = false,
  log_level = vim.log.levels.WARN,
  ---@alias avante.Mode "agentic" | "legacy"
  --- Avante.nvim provides two interaction modes:
  --- - *agentic* (default): Uses AI tools to automatically generate and apply code changes
  --- - *legacy*: Uses the traditional planning method without automatic tool execution
  ---@type avante.Mode
  mode = "agentic",
  ---@type avante.ProviderName
  provider = "claude",
  auto_suggestions_provider = nil,
  memory_summary_provider = nil,
  ---@alias Tokenizer "tiktoken" | "hf"
  ---@type Tokenizer
  -- Used for counting tokens and encoding text.
  -- By default, we will use tiktoken.
  -- For most providers that we support we will determine this automatically.
  -- If you wish to use a given implementation, then you can override it here.
  tokenizer = "tiktoken",
  system_prompt = nil,
  override_prompt_dir = nil,
  rules = {
    project_dir = nil, ---@type string | nil (could be relative dirpath)
    global_dir = nil, ---@type string | nil (absolute dirpath)
  },
  ---@type avante.Config.RagService
  rag_service = { -- RAG service configuration
    enabled = false, -- Enables the RAG service
    host_mount = os.getenv("HOME"), -- Host mount path for the RAG service (Docker will mount this path)
    runner = "docker", -- The runner for the RAG service (can use docker or nix)
    -- The image to use to run the rag service if runner is docker
    image = "quay.io/yetoneful/avante-rag-service:0.0.11",
    llm = { -- Configuration for the Language Model (LLM) used by the RAG service
      provider = "openai", -- The LLM provider
      endpoint = "https://api.openai.com/v1", -- The LLM API endpoint
      api_key = "OPENAI_API_KEY",
      model = "gpt-4o-mini",
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
  ---@type avante.Config.WebSearchEngine
  web_search_engine = {
    proxy = nil,
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
    },
    ["claude-code"] = {
      command = "claude-agent-acp",
      args = {},
      env = {
        NODE_NO_WARNINGS = "1",
        ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
        ANTHROPIC_BASE_URL = os.getenv("ANTHROPIC_BASE_URL"),
        ACP_PATH_TO_CLAUDE_CODE_EXECUTABLE = vim.fn.exepath("claude"),
        ACP_PERMISSION_MODE = "bypassPermissions",
      },
    },
    ["goose"] = {
      command = "goose",
      args = { "acp" },
    },
    ["codex"] = {
      command = "codex-acp",
      args = {},
      env = {
        NODE_NO_WARNINGS = "1",
        HOME = os.getenv("HOME"),
        PATH = os.getenv("PATH"),
        OPENAI_API_KEY = os.getenv("OPENAI_API_KEY"),
      },
    },
    ["opencode"] = {
      command = "opencode",
      args = { "acp" },
    },
    ["kimi-cli"] = {
      command = "kimi",
      args = { "acp" },
    },
  },
  providers = {
    ---@type AvanteSupportedProvider
    openai = {
      endpoint = "https://api.openai.com/v1",
      model = "gpt-4o",
      timeout = 30000,
      context_window = 128000, -- Number of tokens to send to the model for context
      use_response_api = copilot_use_response_api, -- Automatically switch to Response API for GPT-5 Codex models
      support_previous_response_id = true, -- OpenAI Response API supports previous_response_id for stateful conversations
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
    ---@type AvanteAnthropicProvider
    claude = {
      endpoint = "https://api.anthropic.com",
      auth_type = "api",
      model = "claude-sonnet-4-5-20250929",
      timeout = 30000, -- Timeout in milliseconds
      context_window = 200000,
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 64000,
      },
    },
    ---@type AvanteSupportedProvider
    ---@diagnostic disable-next-line: missing-fields
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
      model = "gemini-3.6-flash",
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
      endpoint = "https://api.anthropic.com",
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
      endpoint = "https://api.anthropic.com",
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
      model = "GLM-4.7",
      api_key_name = "GLM_API_KEY",
    },
    qwen = {
      __inherited_from = "openai",
      endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1",
      model = "qwen3-coder-plus",
      api_key_name = "DASHSCOPE_API_KEY",
    },
    mistral = {
      __inherited_from = "openai",
      endpoint = "https://api.mistral.ai/v1",
      model = "mistral-large-latest",
      api_key_name = "MISTRAL_API_KEY",
      extra_request_body = {
        max_tokens = 4096, -- to avoid using the unsupported max_completion_tokens
      },
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
    auto_approve_tool_permissions = true, -- Default: auto-approve all tools (no prompts)
    auto_check_diagnostics = true,
    allow_access_to_git_ignored_files = false,
    enable_fastapply = false,
    include_generated_by_commit_line = false,
    auto_add_current_file = true,
    confirmation_ui_style = "inline_buttons",
    acp_follow_agent_locations = true,
  },
  ---@type avante.Config.PromptLogger
  prompt_logger = { -- logs prompts to disk (timestamped, for replay/debugging)
    enabled = true, -- toggle logging entirely
    log_dir = vim.fn.stdpath("cache"), -- directory where logs are saved
    max_entries = 100, -- the uplimit of entries that can be sotred
    next_prompt = {
      normal = "<C-n>", -- load the next (newer) prompt log in normal mode
      insert = "<C-n>",
    },
    prev_prompt = {
      normal = "<C-p>", -- load the previous (older) prompt log in normal mode
      insert = "<C-p>",
    },
  },
  history = {
    max_tokens = 4096,
    carried_entry_count = nil,
    storage_path = vim.fs.joinpath(vim.fn.stdpath("state"), "avante"),
    paste = {
      extension = "png",
      filename = "pasted-%Y-%m-%d-%H-%M-%S",
    },
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
      expand_tool_use = "<S-Tab>",
      next_prompt = "]p",
      prev_prompt = "[p",
      apply_all = "A",
      apply_cursor = "a",
      retry_user_request = "r",
      edit_user_request = "e",
      switch_windows = "<Tab>",
      reverse_switch_windows = "<S-Tab>",
      toggle_code_window = "x",
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
    select_acp_model = "<leader>aM", -- Select ACP agent model
    select_acp_mode = "<leader>am", -- Select ACP agent mode
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
      include_model = false,
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
  },
  selector = {
    ---@alias avante.SelectorProvider "native" | "fzf_lua" | "mini_pick" | "snacks" | "telescope" | fun(selector: avante.ui.Selector): nil
    ---@type avante.SelectorProvider
    provider = "native",
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
  disabled_tools = {},

  ---@type AvanteLLMToolPublic[] | fun(): AvanteLLMToolPublic[]
  custom_tools = {},
  slash_commands = {},
  shortcuts = {},
  ask_opts = {},
}

---@type avante.Config
---@diagnostic disable-next-line: missing-fields
M._options = {}

---@diagnostic disable-next-line: param-type-mismatch
local function get_config_dir_path() return vim.fs.joinpath(vim.fn.stdpath("state"), "avante") end
local function get_config_file_path() return vim.fs.joinpath(get_config_dir_path(), "config.json") end

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
    if not config.windows.sidebar_header.include_model then
      Utils.info(string.format("Using previously selected model: %s/%s", target_provider_name, model_name))
    end
  end
end

---@param opts table<string, any>|nil -- Optional table parameter for configuration settings
function M.setup(opts)
  opts = opts or {} -- Ensure `opts` is defined with a default table
  vim.validate("opts", opts, "table", true)

  local global_opts = {}
  if vim.g.avante ~= nil then
    vim.validate("vim.g.avante", vim.g.avante, "table", true)
    global_opts = vim.deepcopy(vim.g.avante, true)
  end

  opts = vim.tbl_deep_extend("force", global_opts, opts or {})
  local provider_configured = opts.provider ~= nil

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
  if last_model then
    if provider_configured then
      if last_provider == nil or last_provider == merged.provider then apply_model_selection(merged, last_model) end
    else
      apply_model_selection(merged, last_model, last_provider)
    end
  end

  M._options = merged

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

  vim.validate("provider", M._options.provider, "string", false)

  for k, v in pairs(M._options.providers) do
    M._options.providers[k] = type(v) == "function" and v() or v
  end

  vim.g.avante = vim.tbl_deep_extend("force", vim.g.avante or {}, {
    log_level = merged.log_level,
  })
end

---@param opts table<string, any>
function M.override(opts)
  vim.validate("opts", opts, "table", true)
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

---Get supported providers
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
