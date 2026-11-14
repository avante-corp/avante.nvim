local Config = require("avante.config")
local Path = require("avante.path")
local Storage = require("avante.history.storage")
local stub = require("luassert.stub")

describe("prompt and storage paths", function()
  local root, project, cache, original, available

  before_each(function()
    Config.setup({})
    root = vim.fn.tempname()
    project, cache = root .. "/project", root .. "/cache"
    vim.fn.mkdir(project .. "/rules", "p")
    vim.fn.mkdir(root .. "/global", "p")
    vim.fn.mkdir(cache, "p")
    original = {
      cache = Path.cache_path,
      data = Path.data_path,
      storage = Config.history.storage_path,
      rules = Config.rules,
      override = Config.override_prompt_dir,
      contents = Path.prompts.custom_prompts_contents,
    }
    Path.cache_path, Path.data_path = cache, cache
    Config.history.storage_path = root .. "/history"
    Config.rules = { project_dir = "rules", global_dir = root .. "/global" }
    Config.override_prompt_dir = nil
    Path.prompts.custom_prompts_contents = {}
    available = stub(Path, "available").returns(true)
  end)

  after_each(function()
    available:revert()
    Path.cache_path, Path.data_path = original.cache, original.data
    Config.history.storage_path, Config.rules = original.storage, original.rules
    Config.override_prompt_dir = original.override
    Path.prompts.custom_prompts_contents = original.contents
    vim.fn.delete(root, "rf")
  end)

  it("keeps cached templates under the cache root and preserves rule precedence and bytes", function()
    vim.fn.writefile("project rules\r\n", project .. "/rules/agentic.avanterules")
    vim.fn.writefile("global rules", root .. "/global/agentic.avanterules")
    vim.fn.writefile("root rules", project .. "/agentic.avanterules")
    vim.fn.writefile("global legacy", root .. "/global/legacy.avanterules")
    vim.fn.writefile("hidden", project .. "/rules/.editing.avanterules")
    vim.fn.mkdir(project .. "/rules/nested", "p")
    vim.fn.writefile("nested", project .. "/rules/nested/suggesting.avanterules")

    local dir = Path.prompts.get_templates_dir(project)
    assert.equals(vim.fs.abspath(vim.fs.joinpath(cache, project)), dir)
    assert.equals("project rules\r\n", Path.prompts.custom_prompts_contents.agentic)
    assert.equals("global legacy", Path.prompts.custom_prompts_contents.legacy)
    assert.is_nil(Path.prompts.custom_prompts_contents.editing)
    assert.is_nil(Path.prompts.custom_prompts_contents.suggesting)
    local content = vim.fn.readblob(dir .. "/custom.agentic.avanterules")
    assert.is_truthy(content:find("project rules\r\n", 1, true))
    assert.equals(
      vim.fn.readblob("lua/avante/templates/base.avanterules"),
      vim.fn.readblob(dir .. "/base.avanterules")
    )
  end)

  it("copies override templates and appends the missing blocks without changing existing bytes", function()
    Config.override_prompt_dir = root .. "/override"
    vim.fn.mkdir(Config.override_prompt_dir, "p")
    local base = Config.override_prompt_dir .. "/base.avanterules"
    vim.fn.writefile("custom base\r\n", base)
    vim.fn.writefile("override\0bytes", Config.override_prompt_dir .. "/agentic.avanterules")

    local dir = Path.prompts.get_templates_dir(project)
    assert.equals("override\0bytes", vim.fn.readblob(dir .. "/agentic.avanterules"))
    assert.equals(
      "custom base\r\n{% block extra_prompt %}\n{% endblock %}\n{% block custom_prompt %}\n{% endblock %}",
      vim.fn.readblob(base)
    )
    assert.equals(vim.fn.readblob(base), vim.fn.readblob(dir .. "/base.avanterules"))
  end)

  it("skips directories when loading rules and override templates", function()
    vim.fn.mkdir(project .. "/rules/agentic.avanterules", "p")
    Config.override_prompt_dir = root .. "/override"
    vim.fn.mkdir(Config.override_prompt_dir .. "/partials", "p")
    vim.fn.writefile("override", Config.override_prompt_dir .. "/legacy.avanterules")

    local dir = Path.prompts.get_templates_dir(project)
    assert.is_nil(Path.prompts.custom_prompts_contents.agentic)
    assert.equals("override", vim.fn.readblob(dir .. "/legacy.avanterules"))
    assert.is_nil(vim.uv.fs_stat(dir .. "/partials"))
  end)

  it("reads existing histories from the same project directory and lists them", function()
    local dirname = project:gsub("/", "__"):gsub("[^A-Za-z0-9._]", "_")
    local dir = vim.fs.joinpath(Config.history.storage_path, "projects", dirname, "history")
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.json.encode({ project_root = project, latest_filename = "0.json" }), dir .. "/metadata.json")
    vim.fn.writefile(
      vim.json.encode({ title = "existing", messages = {}, entries = {}, todos = {} }),
      dir .. "/0.json"
    )

    assert.equals(dir, Storage.get_history_dir(0, project))
    assert.equals("existing", Storage.load(0, nil, project).title)
    local projects = Path.list_projects()
    assert.equals(1, #projects)
    assert.equals(project, projects[1].root)
    assert.equals(1, projects[1].history_count)
    assert.equals(dirname, projects[1].name)
  end)
end)
