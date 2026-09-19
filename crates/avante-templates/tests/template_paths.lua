-- Run from the repository root after `cargo build -p avante-templates`:
-- nvim --headless -u NONE -l crates/avante-templates/tests/template_paths.lua target/debug/libavante_templates.so
local templates =
  assert(package.loadlib(assert(arg[1], "provide the built library path"), "luaopen_avante_templates"))()
local root = vim.fn.tempname()
local cache = root .. "/cache"
local project = root .. "/project"
local outside = root .. "/project-outside"
local context = { ask = true, code_lang = "lua" }

local function write(path, text)
  local file = assert(io.open(path, "w"))
  assert(file:write(text))
  assert(file:close())
end

local function render(name) return templates.render(name, context) end

local function rejected(name)
  local ok, err = pcall(render, name)
  assert(not ok, "unexpectedly rendered " .. name)
  assert(not tostring(err):find("OUTSIDE_MARKER", 1, true), "external content leaked in error")
  -- Errors must reach Lua without panicking or poisoning the environment mutex.
  assert(render("good") == "project")
end

local function test()
  vim.fn.mkdir(cache, "p")
  vim.fn.mkdir(project .. "/nested", "p")
  vim.fn.mkdir(outside, "p")
  write(outside .. "/secret", "OUTSIDE_MARKER")
  write(cache .. "/shared", "cache")
  write(project .. "/shared", "project")
  write(project .. "/good", "project")
  write(project .. "/nested/fragment", "nested")
  write(project .. "/include", '{% include "shared" %}:{% include "nested/fragment" %}')
  write(project .. "/base", "{% block body %}base{% endblock %}")
  write(project .. "/child", '{% extends "base" %}{% block body %}child{% endblock %}')
  write(project .. "/macros", "{% macro value() %}macro{% endmacro %}")
  write(project .. "/import", '{% import "macros" as m %}{{ m.value() }}')
  write(project .. "/missing", '{% include "does-not-exist" %}')
  write(project .. "/optional", '{% include "does-not-exist" ignore missing %}ok')
  write(project .. "/invalid", "{% invalid %}")
  write(project .. "/render-error", "{{ missing_function() }}")
  templates.initialize(cache, project)
  assert(render("include") == "cache:nested")
  assert(render("child") == "child")
  assert(render("import") == "macro")
  assert(render("optional") == "ok")

  for _, name in ipairs({ "missing", "invalid", "render-error", "does-not-exist" }) do
    rejected(name)
  end

  for i, name in ipairs({
    "../project-outside/secret",
    "nested/../../project-outside/secret",
    outside .. "/secret",
    "..\\project-outside\\secret",
    "C:/outside/secret",
    "C:secret",
    "//server/share/secret",
  }) do
    rejected(name)
    for j, directive in ipairs({ "include", "extends", "import" }) do
      local template = "escape-" .. i .. "-" .. j
      local suffix = directive == "import" and " as m" or ""
      write(project .. "/" .. template, "{% " .. directive .. " " .. vim.json.encode(name) .. suffix .. " %}")
      rejected(template)
    end
  end

  if vim.fn.has("unix") == 1 then
    for _, directory in ipairs({ cache, project }) do
      assert(vim.uv.fs_symlink(outside .. "/secret", directory .. "/external-file"))
      assert(vim.uv.fs_symlink(outside, directory .. "/external-dir"))
      write(directory .. "/symlink-include", '{% include "external-file" %}')
      templates.initialize(cache, project)
      rejected("external-file")
      rejected("external-dir/secret")
      rejected("symlink-include")
    end
    assert(vim.uv.fs_symlink(project .. "/good", project .. "/internal-file"))
    assert(vim.uv.fs_symlink(project .. "/nested", project .. "/internal-dir"))
    assert(render("internal-file") == "project")
    assert(render("internal-dir/fragment") == "nested")
    assert(vim.uv.fs_symlink(project, root .. "/project-link"))
    templates.initialize(cache, root .. "/project-link")
    assert(render("include") == "cache:nested")
    rejected("external-file")
  end

  assert(not pcall(templates.initialize, cache, root .. "/missing-project"))
  local ok, err = pcall(render, "good")
  assert(not ok and tostring(err):find("Environment not initialized", 1, true))
  templates.initialize(cache, project)
  assert(render("good") == "project")
end

local ok, err = xpcall(test, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("Template path regression tests passed")
