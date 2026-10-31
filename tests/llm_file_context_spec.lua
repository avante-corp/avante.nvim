local stub = require("luassert.stub")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Path = require("avante.path")
local Llm = require("avante.llm")
local View = require("avante.llm_tools.view")
local Templates = require("avante_templates")

describe("selected file context", function()
  local root, filepath, stubs, buffer
  local templates_dir = vim.fn.getcwd() .. "/lua/avante/templates"
  local disk_content = "int disk_only_content = 42;"

  before_each(function()
    Config.setup({})
    Config.provider = "openai"
    Config.mode = "agentic"
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    filepath = root .. "/main.cpp"
    vim.fn.writefile({ disk_content }, filepath)
    stubs = {
      stub(Utils.root, "get", function() return root end),
      stub(Path.prompts, "get_templates_dir", function() return templates_dir end),
      stub(Path.prompts, "initialize", Templates.initialize),
      stub(Path.prompts, "render_file", Templates.render),
    }
  end)

  after_each(function()
    if buffer then vim.api.nvim_buf_delete(buffer, { force = true }) end
    buffer = nil
    for _, item in ipairs(stubs) do
      item:revert()
    end
    vim.fn.delete(root, "rf")
  end)

  local function generate(extra)
    return Llm.generate_prompts(vim.tbl_extend("force", {
      ask = true,
      code_lang = "cpp",
      selected_filepaths = { "main.cpp" },
      tools = { View },
      prompt_opts = { system_prompt = "Test instructions" },
    }, extra or {}))
  end

  local function context(prompt)
    return assert(vim.iter(prompt.messages):find(function(message) return message.is_context end)).content
  end

  it("sends paths without reading file contents in agentic mode", function()
    local read = stub(Utils, "read_file_from_buf_or_disk", function() error("unexpected file read") end)
    stubs[#stubs + 1] = read
    local prompt = generate()
    local text = context(prompt)

    assert.matches("main.cpp", text, nil, true)
    assert.matches("view", text, nil, true)
    assert.is_nil(text:find(disk_content, 1, true))
    assert.stub(read).was_not_called()
    vim.fn.writefile({ "int changed_content = 99;" }, filepath)
    assert.same(prompt.messages, generate().messages)
  end)

  it("keeps selected paths available after a previous view call", function()
    local prompt = generate({
      history_messages = {
        {
          message = {
            role = "assistant",
            content = { { type = "tool_use", id = "view-1", name = "view", input = { path = "main.cpp" } } },
          },
        },
      },
    })
    assert.matches("main.cpp", context(prompt), nil, true)
    assert.is_nil(context(prompt):find(disk_content, 1, true))
  end)

  it("includes explicitly selected snippets alongside file paths", function()
    local prompt = generate({
      selected_code = { path = filepath, file_type = "cpp", content = "selected_snippet" },
    })
    assert.matches("selected_snippet", context(prompt), nil, true)
    assert.is_nil(context(prompt):find(disk_content, 1, true))
  end)

  it(
    "keeps full file contents in legacy mode",
    function() assert.matches(disk_content, context(generate({ mode = "legacy" })), nil, true) end
  )

  it(
    "keeps full file contents when the view tool is unavailable",
    function() assert.matches(disk_content, context(generate({ tools = {} })), nil, true) end
  )

  it("keeps full file contents when the provider disables tools", function()
    local prompt = generate({
      provider = { _protocol = "openai", model = "gpt-mock", disable_tools = true },
    })
    assert.matches(disk_content, context(prompt), nil, true)
  end)

  it("preserves file contents supplied directly by callers", function()
    local prompt = generate({
      selected_filepaths = {},
      selected_files = { { path = filepath, file_type = "cpp", content = "explicit_context" } },
    })
    assert.matches("explicit_context", context(prompt), nil, true)
  end)

  it("keeps selected file reads in the session project after focus changes", function()
    Utils.root.get:revert()
    stubs[#stubs + 1] = stub(Utils.root, "get").returns(root .. "/another-project")

    local prompt = generate({ mode = "legacy", session_ctx = { project_root = root } })

    assert.matches(disk_content, context(prompt), nil, true)
  end)

  it("reads unsaved buffer contents when the model calls view", function()
    local Helpers = require("avante.llm_tools.helpers")
    stubs[#stubs + 1] = stub(Helpers, "has_permission_to_access", function() return true end)
    buffer = vim.fn.bufadd(filepath)
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "int unsaved_buffer_content = 7;" })

    local result, err = View.func({ path = filepath }, {})

    assert.is_nil(err)
    assert.same("int unsaved_buffer_content = 7;", vim.json.decode(result).content)
    assert.same({ disk_content }, vim.fn.readfile(filepath))
  end)

  it("lets view read a new buffer before the file is saved to disk", function()
    local Helpers = require("avante.llm_tools.helpers")
    stubs[#stubs + 1] = stub(Helpers, "has_permission_to_access", function() return true end)
    local new_path = root .. "/new.cpp"
    buffer = vim.fn.bufadd(new_path)
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "int new_buffer_content = 1;" })

    local result, err = View.func({ path = new_path }, {})

    assert.is_nil(err)
    assert.same("int new_buffer_content = 1;", vim.json.decode(result).content)
    assert.is_nil(vim.uv.fs_stat(new_path))
  end)
end)
