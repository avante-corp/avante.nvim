local Config = require("avante.config")
local Llm = require("avante.llm")
local LLMTools = require("avante.llm_tools")
local Path = require("avante.path")
local Providers = require("avante.providers")
local RigClient = require("avante.libs.rig_client")
local Sidebar = require("avante.sidebar")
local Utils = require("avante.utils")

describe("Sidebar API route", function()
  local bufnr
  local calls
  local saved
  local stubs
  local provider_name = "route_test"

  before_each(function()
    if not Config.providers then Config.setup() end
    calls = 0
    saved = {
      provider = Config.provider,
      provider_config = Config.providers[provider_name],
      acp_providers = Config.acp_providers,
      enable_token_counting = Config.behaviour.enable_token_counting,
      instructions_file = Config.instructions_file,
    }

    Config.provider = provider_name
    Config.providers[provider_name] = {
      __inherited_from = "openai",
      api_key_name = "",
      dialect = "openai",
      endpoint = "https://api.openai.com/v1",
      model = "gpt-test",
      context_window = 1000,
      use_response_api = function()
        calls = calls + 1
        return true
      end,
    }
    Config.acp_providers = {}
    Config.behaviour.enable_token_counting = true
    Config.instructions_file = "avante-route-test-missing.md"
    rawset(Providers, provider_name, nil)

    stubs = {
      stub(LLMTools, "get_tools").returns({}),
      stub(Utils, "get_recent_filepaths").returns({}),
      stub(Utils.root, "get").returns("/tmp/avante-route-test-missing"),
      stub(Path.prompts, "get_templates_dir").returns("/tmp"),
      stub(Path.prompts, "initialize"),
      stub(Path.prompts, "render_mode").returns("system"),
      stub(Path.prompts, "render_file").returns(""),
    }
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    for _, value in ipairs(stubs or {}) do
      value:revert()
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end

    rawset(Providers, provider_name, nil)
    if saved then
      Config.provider = saved.provider
      Config.providers[provider_name] = saved.provider_config
      Config.acp_providers = saved.acp_providers
      Config.behaviour.enable_token_counting = saved.enable_token_counting
      Config.instructions_file = saved.instructions_file
    end
  end)

  it("uses one dynamic route decision for history, token counting, prompt generation, and transport", function()
    local sidebar = setmetatable({
      code = { bufnr = bufnr },
      chat_history = { messages = {} },
      file_selector = { selected_filepaths = {} },
    }, { __index = Sidebar })
    local opts

    sidebar:get_generate_prompts_options("hello", function(value) opts = value end)
    local provider = Providers[provider_name]
    local prompt = Llm.generate_prompts(opts)
    local request = RigClient._build_request(provider, prompt, opts.session_ctx)

    assert.same("responses", request.provider.route)
    assert.same(1, calls)
  end)
end)
