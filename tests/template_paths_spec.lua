local templates = require("avante_templates")

describe("template include containment", function()
  local fixture_dir, cache_dir, project_dir, previous_cwd
  local context = { ask = true, code_lang = "lua" }

  local function write_file(path, content)
    local file = assert(io.open(path, "w"))
    assert(file:write(content))
    assert(file:close())
  end

  before_each(function()
    --Create various folders to store different templates
    fixture_dir = vim.fn.tempname()
    cache_dir = fixture_dir .. "/cache"
    project_dir = fixture_dir .. "/project"
    vim.fn.mkdir(cache_dir, "p")
    vim.fn.mkdir(project_dir .. "/nested", "p")
    write_file(fixture_dir .. "/outside.txt", "OUTSIDE_TEMPLATE_ROOT")
    write_file(project_dir .. "/nested/inside.txt", "Inside the project")
    previous_cwd = vim.fn.getcwd()
    vim.fn.chdir(project_dir)
  end)

  after_each(function()
    vim.fn.chdir(previous_cwd)
    vim.fn.delete(fixture_dir, "rf")
  end)

  -- Exercise both loader roots: built-in prompts live in the cache, while
  -- custom templates and includes can also be loaded from the project.
  for _, source in ipairs({ "cache", "project" }) do
    describe("prompt loaded from " .. source, function()
      local function prepare_include(path)
        local root = source == "cache" and cache_dir or project_dir
        write_file(root .. "/prompt.jinja", "{% include " .. vim.json.encode(path) .. " %}")
        templates.initialize(cache_dir, project_dir)
      end

      it("allows includes inside the current project", function()
        prepare_include("nested/inside.txt")
        assert.are.equal("Inside the project", templates.render("prompt.jinja", context))
      end)

      it("rejects includes that traverse to the parent directory", function()
        prepare_include("../outside.txt")
        assert.has_error(function() templates.render("prompt.jinja", context) end)
      end)

      it("rejects absolute includes outside the current project", function()
        prepare_include(fixture_dir .. "/outside.txt")
        assert.has_error(function() templates.render("prompt.jinja", context) end)
      end)

      it("rejects includes through a symlink outside the current project", function()
        local root = source == "cache" and cache_dir or project_dir
        assert(vim.uv.fs_symlink(fixture_dir .. "/outside.txt", root .. "/outside-link.txt"))
        prepare_include("outside-link.txt")
        assert.has_error(function() templates.render("prompt.jinja", context) end)
      end)
    end)
  end
end)
