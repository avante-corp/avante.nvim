---@mod avante-path Prompt generation and history
---@brief Prompt related utilities
local fn = vim.fn
local Utils = require("avante.utils")
local Config = require("avante.config")

---@class avante.Path
---@field history_path string
---@field cache_path string
---@field data_path string
local P = {}

---@return { name: string, root: string, history_count: integer, directory: string }[]
function P.list_projects()
  local projects_dir = vim.fs.joinpath(Config.history.storage_path, "projects")
  if not Utils.filesystem.exists(projects_dir) then return {} end

  ---@type {name: string, root: string, history_count: integer, directory: string}[]
  local projects = {}
  for name, kind in vim.fs.dir(projects_dir) do
    if kind ~= "directory" or name:sub(1, 1) == "." then goto continue end
    local project_dir = vim.fs.joinpath(projects_dir, name)
    local history_dir = vim.fs.joinpath(project_dir, "history")

    local metadata_file = vim.fs.joinpath(history_dir, "metadata.json")
    ---@type string
    local project_root = ""
    if Utils.filesystem.exists(metadata_file) then
      local content = fn.readblob(metadata_file)
      if content then
        ---@type {project_root?: string}
        local metadata = vim.json.decode(content)
        if metadata and metadata.project_root then project_root = metadata.project_root end
      end
    end

    -- Skip if project_root is empty
    if project_root == "" then goto continue end

    -- Count history files
    local history_count = 0
    if Utils.filesystem.exists(history_dir) then
      ---@type string[]
      local history_files = fn.glob(vim.fs.joinpath(history_dir, "*.json"), true, true)
      for _, file in ipairs(history_files) do
        if not file:match("metadata.json") then history_count = history_count + 1 end
      end
    end

    table.insert(projects, {
      name = name,
      root = project_root,
      history_count = history_count,
      directory = project_dir,
    })

    ::continue::
  end

  -- Sort by history count (most active projects first)
  table.sort(projects, function(a, b) return a.history_count > b.history_count end)

  return projects
end

-- Prompt path
local Prompt = {}

-- Given a mode, return the file name for the custom prompt.
---@param mode AvanteLlmMode
---@return string
function Prompt.get_custom_prompts_filepath(mode) return string.format("custom.%s.avanterules", mode) end

---Appends ".avanterules" to the path
function Prompt.get_builtin_prompts_filepath(mode) return string.format("%s.avanterules", mode) end

---@class AvanteTemplates
---@brief Interface to the rust library that renders jinja prompts
---@field initialize fun(cache_directory: string, project_directory: string): nil
---@field render fun(template: string, context: AvanteTemplateOptions): string
local _templates_lib = nil

---tell which rules to load
Prompt.custom_modes = {
  agentic = true,
  legacy = true,
  editing = true,
  suggesting = true,
}

---Saved prompts for custom_modes
---@type table<AvanteLlmMode, string>
Prompt.custom_prompts_contents = {}

---Search and load avanterules in this order:
--- - Config.rules.project_dir
--- - Config.rules.global_dir
--- - project_root directory
---
--- then looks at Config.override_prompt_dir, fixing files if necessary
---@see avante-prompts
---@param project_root string
---@return string templates_dir
function Prompt.get_templates_dir(project_root)
  if not P.available() then error("Make sure to build avante (missing avante_templates)", 2) end

  -- get root directory of given bufnr
  local directory = project_root
  if Utils.get_os_name() == "windows" then
    local win_path = vim.fs.abspath(directory):gsub("^%a:", ""):gsub("^[/\\]+", "")
    directory = vim.fs.normalize(win_path)
  end
  local cache_prompt_dir = vim.fs.joinpath(P.cache_path, directory)
  if fn.isdirectory(cache_prompt_dir) == 0 then fn.mkdir(cache_prompt_dir, "p") end

  ---Loop over files searching for [MODE].avanterules
  local function find_rules(dir)
    if not dir then return end
    if not Utils.filesystem.is_directory(dir) then return end

    for piece in vim.fs.dir(dir) do
      local entry = vim.fs.joinpath(dir, piece)
      if piece:sub(1, 1) ~= "." and Utils.filesystem.is_regular_file(entry) then
        local mode = piece:match("([^.]+)%.avanterules$")
        if not mode or not Prompt.custom_modes[mode] then goto continue end
        if Prompt.custom_prompts_contents[mode] == nil then
          Utils.info(string.format("Using %s as %s system prompt", entry, mode))
          Prompt.custom_prompts_contents[mode] = fn.readblob(entry)
        end
      end
      ::continue::
    end
  end

  if Config.rules.project_dir then
    ---@type string
    local project_rules_path = Config.rules.project_dir
    if fn.isabsolutepath(project_rules_path) == 0 then
      project_rules_path = vim.fs.joinpath(project_root, project_rules_path)
    end
    find_rules(project_rules_path)
  end
  find_rules(Config.rules.global_dir)
  find_rules(project_root)

  local source_dir = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "templates")
  -- Copy built-in templates to cache directory (only if not overridden by user templates)
  assert(Utils.filesystem.copy_dir(source_dir, cache_prompt_dir))

  -- Check for override prompt
  local override_prompt_dir = Config.override_prompt_dir
  if override_prompt_dir then
    Utils.debug("override_prompt_dir set")

    -- Handle the case where override_prompt_dir is a function
    if type(override_prompt_dir) == "function" then
      local ok, result = pcall(override_prompt_dir)
      if ok and result then
        override_prompt_dir = result --[[@as string]]
      end
    end

    if type(override_prompt_dir) == "string" then
      if Utils.filesystem.is_directory(override_prompt_dir) then
        for piece in vim.fs.dir(override_prompt_dir) do
          local file = vim.fs.joinpath(override_prompt_dir, piece)
          if piece:sub(1, 1) ~= "." and Utils.filesystem.is_regular_file(file) then
            if piece == "base.avanterules" then
              local content = fn.readblob(file)

              if not content:match("{%% block extra_prompt %%}[%s,\\n]*{%% endblock %%}") then
                Utils.warn("Appending missing extra_prompt block")
                assert(fn.writefile("{% block extra_prompt %}\n{% endblock %}\n", file, "a") == 0)
              end

              if not content:match("{%% block custom_prompt %%}[%s,\\n]*{%% endblock %%}") then
                Utils.warn("Appending missing custom_prompt block")
                assert(fn.writefile("{% block custom_prompt %}\n{% endblock %}", file, "a") == 0)
              end
            end
            assert(vim.uv.fs_copyfile(file, vim.fs.joinpath(cache_prompt_dir, piece)))
          end
        end
      end
    end
  end

  for k, v in pairs(Prompt.custom_prompts_contents) do
    local orig_file = vim.fs.joinpath(cache_prompt_dir, Prompt.get_builtin_prompts_filepath(k))
    local orig_content = fn.readblob(orig_file)
    local f = vim.fs.joinpath(cache_prompt_dir, Prompt.get_custom_prompts_filepath(k))
    assert(fn.writefile(orig_content .. "{% block custom_prompt -%}\n" .. v .. "\n{%- endblock %}", f) == 0)
  end

  local dir = vim.fs.abspath(cache_prompt_dir)
  return dir
end

---@param mode AvanteLlmMode
---@return string
function Prompt.get_filepath(mode)
  if Prompt.custom_prompts_contents[mode] ~= nil then return Prompt.get_custom_prompts_filepath(mode) end
  return Prompt.get_builtin_prompts_filepath(mode)
end

---Wrapper around rust library 'render'
---Render jinja template
---@param path string
---@param opts AvanteTemplateOptions
---@return string
function Prompt.render_file(path, opts)
  Utils.debug("Rendering prompt for " .. path)
  return _templates_lib.render(path, opts)
end

---@param mode AvanteLlmMode
---@param opts AvanteTemplateOptions
---@return string
function Prompt.render_mode(mode, opts)
  local filepath = Prompt.get_filepath(mode)
  local res = _templates_lib.render(filepath, opts)
  if res ~= "" then Utils.debug("Rendered prompt from " .. filepath) end
  return res
end

---@Initialize the rust library avante_templates
function Prompt.initialize(cache_directory, project_directory)
  _templates_lib.initialize(cache_directory, project_directory)
end

P.prompts = Prompt

local RepoMap = {}

-- Get the path where to expect the repo map
---@param project_root string
---@param ext string
---@return string name of the repo map (suffixed with .repo_map.json)
function RepoMap.filename(project_root, ext)
  -- Replace path separators with double underscores
  local path_with_separators = fn.substitute(project_root, "/", "__", "g")
  -- Replace other non-alphanumeric characters with single underscores
  return fn.substitute(path_with_separators, "[^A-Za-z0-9._]", "_", "g") .. "." .. ext .. ".repo_map.json"
end

function RepoMap.get(project_root, ext) return vim.fs.joinpath(P.data_path, RepoMap.filename(project_root, ext)) end

function RepoMap.save(project_root, ext, data)
  local file = RepoMap.get(project_root, ext)
  assert(fn.writefile(vim.json.encode(data), file) == 0)
end

function RepoMap.load(project_root, ext)
  local file = RepoMap.get(project_root, ext)
  if Utils.filesystem.exists(file) then
    local content = fn.readblob(file)
    return content ~= nil and vim.json.decode(content) or {}
  end
  return nil
end

P.repo_map = RepoMap

---Load avante-templates rust library
---@return AvanteTemplates|nil
function P._init_templates_lib()
  if _templates_lib ~= nil then return _templates_lib end

  local ok, module = pcall(require, "avante_templates")
  ---@cast module AvanteTemplates
  ---@cast ok boolean
  if not ok then return nil end
  _templates_lib = module

  return _templates_lib
end

--- Create storage_path , cache / data folders
function P.setup()
  local history_path = Config.history.storage_path
  if not Utils.filesystem.exists(history_path) then vim.fn.mkdir(history_path, "p") end
  P.history_path = history_path

  local cache_path = vim.fs.joinpath(vim.fn.stdpath("cache"), "avante")
  if not Utils.filesystem.exists(cache_path) then vim.fn.mkdir(cache_path, "p") end
  P.cache_path = cache_path

  local data_path = vim.fs.joinpath(vim.fn.stdpath("data"), "avante")
  if not Utils.filesystem.exists(data_path) then vim.fn.mkdir(data_path, "p") end
  P.data_path = data_path

  vim.defer_fn(P._init_templates_lib, 1000)
end

---Check if rust templating library was loaded
---@return boolean
function P.available() return P._init_templates_lib() ~= nil end

---Delete folders containing history
function P.clear()
  vim.fs.rm(P.cache_path, { recursive = true })
  vim.fs.rm(P.history_path, { recursive = true })

  if not Utils.filesystem.exists(P.cache_path) then vim.fn.mkdir(P.cache_path, "p") end
  if not Utils.filesystem.exists(P.history_path) then vim.fn.mkdir(P.history_path, "p") end
end

return P
