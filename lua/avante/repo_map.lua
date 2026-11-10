---@mod avante-repo-map Summarize codebase
---@brief [[
--- Generate a summary of your codebase via an avante rust library.
--- Builds upon treesitter to list nodes.
--- Run 'AvanteShowRepoMap' to see the result. You can also reference
--- Use @codebase in the input container.
---]]
---@see AvanteShowRepoMap
local Popup = require("nui.popup")
local Utils = require("avante.utils")
local event = require("nui.utils.autocmd").event

local filetype_map = {
  ["javascriptreact"] = "javascript",
  ["typescriptreact"] = "typescript",
  ["cs"] = "csharp",
}

---@class AvanteRepoMap
---@field stringify_definitions fun(lang: string, source: string): string
local repo_map_lib = nil

---@class AvanteRepoMapEntry
---@field path string
---@field lang string
---@field defs string

local RepoMap = {}

---@return AvanteRepoMap|nil
function RepoMap._init_repo_map_lib()
  if repo_map_lib ~= nil then return repo_map_lib end

  local ok, core = pcall(require, "avante_repo_map")
  if not ok then return nil end

  repo_map_lib = core
  return repo_map_lib
end

function RepoMap.setup() vim.defer_fn(RepoMap._init_repo_map_lib, 1000) end

function RepoMap.get_ts_lang(filepath)
  local filetype = Utils.get_filetype(filepath)
  return filetype_map[filetype] or filetype
end

---@param project_root string
---@param file_ext string
---@return AvanteRepoMapEntry[]?
function RepoMap._build_repo_map(project_root, file_ext)
  local output = {}

  local filepaths = Utils.scan_directory({
    directory = project_root,
  })
  if filepaths and not RepoMap._init_repo_map_lib() then
    -- or just throw an error if we don't want to execute request without codebase
    Utils.error("Failed to load avante_repo_map")
    return
  end
  vim.iter(filepaths):each(function(filepath)
    if not Utils.is_same_file_ext(file_ext, filepath) then return end
    local filetype = RepoMap.get_ts_lang(filepath)
    local lines = Utils.read_file_from_buf_or_disk(filepath)
    local content = lines and table.concat(lines, "\n") or ""
    local definitions = filetype and repo_map_lib.stringify_definitions(filetype, content) or ""
    if definitions == "" then return end
    table.insert(output, {
      path = Utils.relative_path(filepath),
      lang = Utils.get_filetype(filepath),
      defs = definitions,
    })
  end)
  return output
end

---@type table<string, AvanteRepoMapEntry[]>
local cache = {}

function RepoMap.get_repo_map(file_ext)
  -- Add safety check for file_ext
  if not file_ext then
    Utils.warn("No file extension available - please open a file first")
    return {}
  end

  local repo_map = RepoMap._get_repo_map(file_ext) or {}
  if not repo_map or next(repo_map) == nil then
    Utils.warn("The repo map is empty. Maybe do not support this language: " .. file_ext)
  end
  return repo_map
end

---@param file_ext? string
---@return AvanteRepoMapEntry[]?
function RepoMap._get_repo_map(file_ext)
  -- Add safety check at the start of the function
  if not file_ext then
    local current_buf = vim.api.nvim_get_current_buf()
    local buf_name = vim.api.nvim_buf_get_name(current_buf)
    if buf_name and buf_name ~= "" then file_ext = vim.fn.fnamemodify(buf_name, ":e") end

    if not file_ext or file_ext == "" then return {} end
  end

  local project_root = Utils.root.get()
  local cache_key = project_root .. "." .. file_ext
  local cached = cache[cache_key]
  if cached then return cached end

  local Path = require("avante.path")
  ---@type AvanteRepoMapEntry[]?
  local repo_map

  local function build_and_save()
    repo_map = RepoMap._build_repo_map(project_root, file_ext)
    cache[cache_key] = repo_map
    Path.repo_map.save(project_root, file_ext, repo_map)
  end

  repo_map = Path.repo_map.load(project_root, file_ext)

  if not repo_map or next(repo_map) == nil then
    build_and_save()
    if not repo_map then return end
  else
    local timer = vim.uv.new_timer()

    if timer then
      timer:start(
        0,
        0,
        vim.schedule_wrap(function()
          build_and_save()
          timer:close()
        end)
      )
    end
  end

  local update_repo_map = vim.schedule_wrap(function(rel_filepath)
    if rel_filepath and Utils.is_same_file_ext(file_ext, rel_filepath) then
      local abs_filepath = vim.fs.abspath(vim.fs.joinpath(project_root, rel_filepath))
      local lines = Utils.read_file_from_buf_or_disk(abs_filepath)
      local content = lines and table.concat(lines, "\n") or ""
      local definitions = repo_map_lib.stringify_definitions(RepoMap.get_ts_lang(abs_filepath), content)
      if definitions == "" then return end
      local found = false
      for _, m in
        ipairs(repo_map --[=[@as AvanteRepoMapEntry[]]=])
      do
        if m.path == rel_filepath then
          m.defs = definitions
          found = true
          break
        end
      end
      if not found then
        table.insert(repo_map, {
          path = Utils.relative_path(abs_filepath),
          lang = Utils.get_filetype(abs_filepath),
          defs = definitions,
        })
      end
      cache[cache_key] = repo_map
      Path.repo_map.save(project_root, file_ext, repo_map)
    end
  end)

  local handle = vim.uv.new_fs_event()

  if handle then
    handle:start(project_root, { recursive = true }, function(err, rel_filepath)
      if err then
        print("Error watching directory " .. project_root .. ":", err)
        return
      end

      if rel_filepath then update_repo_map(rel_filepath) end
    end)
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    callback = function(ev)
      vim.defer_fn(function()
        local ok, filepath = pcall(vim.api.nvim_buf_get_name, ev.buf)
        if not ok or not filepath then return end
        if not vim.startswith(filepath, project_root) then return end
        local rel_filepath = Utils.relative_path(filepath)
        update_repo_map(rel_filepath)
      end, 0)
    end,
  })

  return repo_map
end

function RepoMap.show()
  local file_ext = vim.fn.expand("%:e")
  local repo_map = RepoMap.get_repo_map(file_ext)

  if not repo_map or next(repo_map) == nil then
    Utils.warn("The repo map is empty or not supported for this language: " .. file_ext)
    return
  end

  local popup = Popup({
    position = "50%",
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      padding = { 1, 1 },
      text = {
        top = " Avante Repo Map ",
        top_align = "center",
      },
    },
    size = {
      width = math.floor(vim.o.columns * 0.8),
      height = math.floor(vim.o.lines * 0.8),
    },
  })

  popup:mount()

  popup:map("n", "q", function() popup:unmount() end, { noremap = true, silent = true })

  popup:on(event.BufLeave, function() popup:unmount() end)

  -- Format the repo map for display
  local lines = {}
  for _, entry in ipairs(repo_map) do
    table.insert(lines, string.format("Path: %s", entry.path))
    table.insert(lines, string.format("Lang: %s", entry.lang))
    table.insert(lines, "Defs:")
    for def_line in entry.defs:gmatch("[^\r\n]+") do
      table.insert(lines, def_line)
    end
    table.insert(lines, "") -- Add an empty line between entries
  end

  -- Set the buffer content
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
end

return RepoMap
