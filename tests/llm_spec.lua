local utils = require("avante.utils")

local llm = require("avante.llm")

describe("generate_prompts", function()
  local project_root = "/tmp/project_root"

  before_each(function()
    local mock_dir = vim.fs.joinpath("tests", project_root)
    vim.fn.mkdir(mock_dir, "p")

    local mock_file = vim.fs.joinpath("tests", project_root, "avante.md")
    local file = assert(io.open(mock_file, "w"))
    file:write("# Mock Instructions\nThis is a mock instruction file.")
    file:close()

    -- Mock the project root
    utils.root = {}
    utils.root.get = function() return mock_dir end

    -- Mock Config.providers
    local Config = require("avante.config")
    Config.setup() -- TODO remove we should be able to do without
    Config.instructions_file = "avante.md"
    Config.provider = "openai"
    Config.acp_providers = {}
    Config.providers = {
      openai = {
        endpoint = "https://api.mock.com/v1",
        model = "gpt-mock",
        timeout = 10000,
        context_window = 1000,
        extra_request_body = {
          temperature = 0.5,
          max_tokens = 1000,
        },
      },
    }
    -- Mock Config.history to prevent nil access error in Path.setup()
    Config.history = {
      max_tokens = 4096,
      carried_entry_count = nil,
      storage_path = "/tmp/test_avante_history",
      paste = {
        extension = "png",
        filename = "pasted-%Y-%m-%d-%H-%M-%S",
      },
    }

    -- Mock Config.behaviour
    Config.behaviour = {
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
      auto_approve_tool_permissions = false, -- Default: show permission prompts for all tools
      auto_check_diagnostics = true,
      enable_fastapply = false,
    }

    -- Mock Config.rules to prevent nil access error in get_templates_dir()
    Config.rules = {
      project_dir = nil,
      global_dir = nil,
    }

    -- Mock P.available to always return true
    local Path = require("avante.path")
    ---@diagnostic disable-next-line: duplicate-set-field
    Path.available = function() return true end

    -- Mock the Prompt functions directly since _templates_lib is a local variable
    -- that we can't easily access from outside the module
    Path.prompts.initialize = function(_cache_directory, _project_directory)
      -- Mock initialization - no-op for tests
    end

    Path.prompts.render_file = function(_path, _opts)
      -- Mock render - return empty string for tests
      return ""
    end

    Path.prompts.render_mode = function(_mode, _opts)
      -- Mock render_mode - return empty string for tests
      return ""
    end

    Path.setup() -- Initialize necessary paths like cache_path
  end)

  after_each(function()
    -- Clean up created test files and directories
    local mock_dir = vim.fs.joinpath("tests", project_root)
    if vim.uv.fs_stat(mock_dir) then vim.fs.rm(mock_dir, { recursive = true }) end
  end)

  it("should include instruction file content when the file exists", function()
    local opts = {}
    llm.generate_prompts(opts)
    assert.are.same("\n# Mock Instructions\nThis is a mock instruction file.", opts.instructions)
  end)

  it("should not modify instructions if the file does not exist", function()
    local mock_file = vim.fs.joinpath("tests", project_root, "avante.md")
    if vim.uv.fs_stat(mock_file) then vim.fs.rm(mock_file) end

    local opts = {}
    llm.generate_prompts(opts)
    assert.are.same(opts.instructions, nil)
  end)

  it("should set tools to nil when no tools are provided", function()
    local opts = {}
    local result = llm.generate_prompts(opts)
    assert.are.same(result.tools, nil)
  end)

  it("should set tools to nil when empty tools array is provided", function()
    local opts = {
      tools = {},
    }
    local result = llm.generate_prompts(opts)
    assert.are.same(result.tools, nil)
  end)

  it("should set tools to nil when empty prompt_opts.tools array is provided", function()
    local opts = {
      prompt_opts = {
        tools = {},
      },
    }
    local result = llm.generate_prompts(opts)
    assert.are.same(result.tools, nil)
  end)

  it("should include tools when non-empty tools are provided", function()
    local mock_tool = {
      name = "test_tool",
      description = "A test tool",
      func = function() end,
    }
    local opts = {
      tools = { mock_tool },
    }
    local result = llm.generate_prompts(opts)
    assert.are.same(#result.tools, 1)
    assert.are.same(result.tools[1].name, "test_tool")
  end)

  it("should not duplicate instruction file content when called multiple times with same opts", function()
    local opts = {}
    llm.generate_prompts(opts)
    local first_instructions = opts.instructions

    -- Call again with the same opts object
    llm.generate_prompts(opts)
    local second_instructions = opts.instructions

    -- Instructions should be the same, not duplicated
    assert.are.same(first_instructions, second_instructions)
    -- Verify that mock content is present (more flexible than hardcoded exact match)
    assert.truthy(string.find(opts.instructions, "Mock Instructions"))
  end)

  it("should not duplicate instructions in messages when called multiple times with same opts", function()
    local opts = {
      instructions = "Test instructions",
    }

    -- First call
    local result1 = llm.generate_prompts(opts)
    local instruction_message_count1 = 0
    for _, msg in ipairs(result1.messages) do
      if
        msg.role == "user"
        and type(msg.content) == "string"
        and string.find(msg.content, "Test instructions", 1, true)
      then
        instruction_message_count1 = instruction_message_count1 + 1
      end
    end

    -- Second call with same opts
    local result2 = llm.generate_prompts(opts)
    local instruction_message_count2 = 0
    for _, msg in ipairs(result2.messages) do
      if
        msg.role == "user"
        and type(msg.content) == "string"
        and string.find(msg.content, "Test instructions", 1, true)
      then
        instruction_message_count2 = instruction_message_count2 + 1
      end
    end

    -- Should have instructions message only once in both calls
    assert.are.same(1, instruction_message_count1)
    assert.are.same(1, instruction_message_count2)
  end)
end)
