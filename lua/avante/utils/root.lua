-- COPIED and MODIFIED from https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/util/root.lua
local Utils = require("avante.utils")
local Config = require("avante.config")

---@class avante.utils.root
---@overload fun(): string
local M = setmetatable({}, {
  __call = function(m) return m.get() end,
})

---@class AvanteRoot
---@field paths string[]
---@field spec AvanteRootSpec

---@alias AvanteRootFn fun(buf: number): (string|string[])

---@alias AvanteRootSpec string|string[]|AvanteRootFn

---@type AvanteRootSpec[]
M.spec = {
  "lsp",
  {
    -- Version Control
    ".git", -- Git repository folder
    ".svn", -- Subversion repository folder
    ".hg", -- Mercurial repository folder
    ".bzr", -- Bazaar repository folder

    -- Package Management
    "package.json", -- Node.js/JavaScript projects
    "composer.json", -- PHP projects
    "Gemfile", -- Ruby projects
    "requirements.txt", -- Python projects
    "setup.py", -- Python projects
    "pom.xml", -- Maven (Java) projects
    "build.gradle", -- Gradle (Java) projects
    "Cargo.toml", -- Rust projects
    "go.mod", -- Go projects
    "*.csproj", -- .NET projects
    "*.sln", -- .NET solution files

    -- Build Configuration
    "Makefile", -- Make build system
    "CMakeLists.txt", -- CMake build system
    "build.xml", -- Ant build system
    "Rakefile", -- Ruby build tasks
    "gulpfile.js", -- Gulp build system
    "Gruntfile.js", -- Grunt build system
    "webpack.config.js", -- Webpack configuration

    -- Project Configuration
    ".editorconfig", -- Editor configuration
    ".eslintrc", -- ESLint configuration
    ".prettierrc", -- Prettier configuration
    "tsconfig.json", -- TypeScript configuration
    "tox.ini", -- Python testing configuration
    "pyproject.toml", -- Python project configuration
    ".gitlab-ci.yml", -- GitLab CI configuration
    ".github", -- GitHub configuration folder
    ".travis.yml", -- Travis CI configuration
    "Jenkinsfile", -- Jenkins pipeline configuration
    "docker-compose.yml", -- Docker Compose configuration
    "Dockerfile", -- Docker configuration

    -- Framework-specific
    "angular.json", -- Angular projects
    "ionic.config.json", -- Ionic projects
    "config.xml", -- Cordova projects
    "pubspec.yaml", -- Flutter/Dart projects
    "mix.exs", -- Elixir projects
    "project.clj", -- Clojure projects
    "build.sbt", -- Scala projects
    "stack.yaml", -- Haskell projects
  },
  "cwd",
}

M.detectors = {}

function M.detectors.cwd() return { vim.uv.cwd() } end

---@param buf number
function M.detectors.lsp(buf)
  local bufpath = M.bufpath(buf)
  if not bufpath then return {} end
  local roots = {} ---@type string[]
  local lsp_clients = Utils.lsp.get_clients({ bufnr = buf })
  for _, client in ipairs(lsp_clients) do
    local workspace = client.config.workspace_folders
    for _, ws in ipairs(workspace or {}) do
      roots[#roots + 1] = vim.uri_to_fname(ws.uri)
    end
    if client.root_dir then roots[#roots + 1] = client.root_dir end
  end
  return vim.tbl_filter(function(path)
    path = Utils.norm(path)
    return path and bufpath:find(path, 1, true) == 1
  end, roots)
end

---@param patterns string[]|string
function M.detectors.pattern(buf, patterns)
  local patterns_ = type(patterns) == "string" and { patterns } or patterns
  ---@cast patterns_ string[]
  local path = M.bufpath(buf) or vim.uv.cwd()
  local pattern = vim.fs.find(function(name)
    for _, p in ipairs(patterns_) do
      if name == p then return true end
      if p:sub(1, 1) == "*" and name:find(vim.pesc(p:sub(2)) .. "$") then return true end
    end
    return false
  end, { path = path, upward = true })[1]
  return pattern and { vim.fs.dirname(pattern) } or {}
end

function M.bufpath(buf)
  if buf == nil or type(buf) ~= "number" then
    -- TODO: Consider logging this unexpected buffer type or nil value if assert was bypassed.
    vim.notify("avante: M.bufpath received invalid buffer: " .. tostring(buf), vim.log.levels.WARN)
    return nil
  end

  local buf_name_str
  local success, result = pcall(vim.api.nvim_buf_get_name, buf)

  if not success then
    -- TODO: Consider logging the actual error from pcall.
    vim.notify(
      "avante: nvim_buf_get_name failed for buffer " .. tostring(buf) .. ": " .. tostring(result),
      vim.log.levels.WARN
    )
    return nil
  end
  buf_name_str = result

  -- M.realpath will handle buf_name_str == "" (empty string for unnamed buffer) correctly, returning nil.
  return M.realpath(buf_name_str)
end

function M.cwd() return M.realpath(vim.uv.cwd()) or "" end

function M.realpath(path)
  if path == "" or path == nil then return nil end
  path = vim.uv.fs_realpath(path) or path
  return Utils.norm(path)
end

---@param spec AvanteRootSpec
---@return AvanteRootFn
function M.resolve(spec)
  if M.detectors[spec] then
    return M.detectors[spec]
  elseif type(spec) == "function" then
    return spec
  end
  return function(buf) return M.detectors.pattern(buf, spec) end
end

---@param opts? { buf?: number, spec?: AvanteRootSpec[], all?: boolean }
function M.detect(opts)
  opts = opts or {}
  opts.spec = opts.spec or type(vim.g.root_spec) == "table" and vim.g.root_spec or M.spec
  opts.buf = (opts.buf == nil or opts.buf == 0) and vim.api.nvim_get_current_buf() or opts.buf

  local ret = {} ---@type AvanteRoot[]
  for _, spec in ipairs(opts.spec) do
    local paths = M.resolve(spec)(opts.buf)
    paths = paths or {}
    paths = type(paths) == "table" and paths or { paths }
    local roots = {} ---@type string[]
    for _, p in ipairs(paths) do
      local pp = M.realpath(p)
      if pp and not vim.tbl_contains(roots, pp) then roots[#roots + 1] = pp end
    end
    table.sort(roots, function(a, b) return #a > #b end)
    if #roots > 0 then
      ret[#ret + 1] = { spec = spec, paths = roots }
      if opts.all == false then break end
    end
  end
  return ret
end

---@type table<number, string>
M.cache = {}
local buf_names = {}

---Git worktrees have a `.git` *file* pointing at the main repo, not a
---directory. LSP and `vim.fs.find(".git")` both follow that pointer, so two
---Neovim instances — one in `~/nuon/nuon`, one in a worktree — used to share a
---project root, a history folder, and `latest_filename`. A reply in the
---worktree then showed up as the live thread in the other pane.
---@param path? string
---@return string|nil
function M.git_worktree_root(path)
  if not path or path == "" then return nil end
  local git = vim.fs.find(".git", { path = path, upward = true })[1]
  if not git then return nil end
  local stat = vim.uv.fs_stat(git)
  if not stat or stat.type ~= "file" then return nil end
  return M.realpath(vim.fs.dirname(git)) or vim.fs.dirname(git)
end

---Pick the directory Avante should treat as "this project".
---
---`detected` is whatever LSP / `.git` / patterns found, which for a worktree
---is usually the main checkout. History and ACP sessions are keyed off the
---result, so a worktree must win over that.
---@param detected? string
---@param cwd? string
---@return string|nil
function M.resolve_project_root(detected, cwd)
  cwd = cwd and (M.realpath(cwd) or cwd) or nil
  detected = detected and (M.realpath(detected) or detected) or nil
  if cwd then
    local worktree = M.git_worktree_root(cwd)
    if worktree then return worktree end
    if detected and #detected > #cwd then return cwd end
  end
  return detected or cwd
end

---Whether `:cd` to `target` would stay inside this Neovim's checkout.
---
---Auto-restoring `last_session.working_directory` used to `:cd` the original
---repo's Vim into the worktree the other pane had just been chatting in,
---because that path was the last thing written to the shared metadata file.
---@param target? string
---@param cwd? string
---@return boolean
function M.should_follow_working_directory(target, cwd)
  if not target or target == "" or not cwd or cwd == "" then return false end
  if vim.fn.isdirectory(target) ~= 1 then return false end
  target = M.realpath(target) or target
  cwd = M.realpath(cwd) or cwd
  if target == cwd then return false end
  local target_wt = M.git_worktree_root(target)
  local cwd_wt = M.git_worktree_root(cwd)
  if target_wt or cwd_wt then return (target_wt or target) == (cwd_wt or cwd) end
  local function under(child, parent)
    return child == parent or vim.startswith(child, parent .. "/")
  end
  return under(target, cwd) or under(cwd, target)
end

-- returns the root directory based on:
-- * git worktree of cwd (so worktrees don't share the main checkout's history)
-- * lsp workspace folders
-- * lsp root_dir
-- * root pattern of filename of the current buffer
-- * root pattern of cwd
---@param opts? {normalize?:boolean, buf?:number}
---@return string
function M.get(opts)
  if Config.ask_opts and Config.ask_opts.project_root then return Config.ask_opts.project_root end
  local cwd = vim.uv.cwd()
  if Config.behaviour and Config.behaviour.use_cwd_as_project_root then
    if cwd and cwd ~= "" then return cwd end
  end
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(buf)
  local ret = buf_names[buf] == buf_name and M.cache[buf] or nil
  if not ret then
    local roots = M.detect({ all = false, buf = buf })
    ret = roots[1] and roots[1].paths[1] or vim.uv.cwd()
    buf_names[buf] = buf_name
    M.cache[buf] = ret
  end
  ret = M.resolve_project_root(ret, cwd) or ret
  if opts and opts.normalize then return ret end
  return Utils.is_win() and ret:gsub("/", "\\") or ret
end

function M.git()
  local root = M.get()
  local git_root = vim.fs.find(".git", { path = root, upward = true })[1]
  local ret = git_root and vim.fn.fnamemodify(git_root, ":h") or root
  return ret
end

return M