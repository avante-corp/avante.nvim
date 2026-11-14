local Utils = require("avante.utils")
local Config = require("avante.config")
local Selector = require("avante.ui.selector")

local PROMPT_TITLE = "(Avante) Add file(s)"

---@class FileSelector
---@field id integer
---@field selected_filepaths string[] Absolute paths
---@field event_handlers table<string, function[]>
local FileSelector = {}

---@alias FileSelectorHandler fun(self: FileSelector, on_select: fun(filepaths: string[] | nil)): nil

local function has_scheme(path) return path:find("^(?!term://)%w+://") ~= nil end

---@param absolute_path string
function FileSelector:process_directory(absolute_path)
  if absolute_path:sub(-1) == Utils.path_sep then absolute_path = absolute_path:sub(1, -2) end
  local files = Utils.scan_directory({ directory = absolute_path, add_dirs = false })

  for _, file in ipairs(files) do
    if not vim.tbl_contains(self.selected_filepaths, file) then table.insert(self.selected_filepaths, file) end
  end
  self:emit("update")
end

---@param selected_paths string[] | nil
---@return nil
function FileSelector:handle_path_selection(selected_paths)
  if not selected_paths then return end

  for _, selected_path in ipairs(selected_paths) do
    local absolute_path = Utils.to_absolute_path(selected_path)
    if vim.fn.isdirectory(absolute_path) == 1 then
      self:process_directory(absolute_path)
    else
      if Config.file_selector.provider == "native" then
        table.insert(self.selected_filepaths, absolute_path)
      else
        if not vim.tbl_contains(self.selected_filepaths, absolute_path) then
          table.insert(self.selected_filepaths, absolute_path)
        end
      end
    end
  end
  self:emit("update")
end

---Scans a given directory and produces a list of files/directories with absolute paths
---@param excluded_paths_set? table<string, boolean> Optional set of absolute paths to exclude
---@return { path: string, is_dir: boolean }[]
local function get_project_filepaths(excluded_paths_set)
  excluded_paths_set = excluded_paths_set or {}
  local project_root = Utils.get_project_root()
  local files = Utils.scan_directory({ directory = project_root, add_dirs = true })
  return vim
    .iter(files)
    :filter(function(path) return not excluded_paths_set[path] end)
    :map(function(path)
      local is_dir = vim.fn.isdirectory(path) == 1
      return { path = path, is_dir = is_dir }
    end)
    :totable()
end

---@param id integer
---@return FileSelector
function FileSelector:new(id)
  ---@type FileSelector
  local selector = {
    id = id,
    selected_filepaths = {},
    event_handlers = {},
  }
  setmetatable(selector, { __index = self })
  return selector
end

function FileSelector:reset()
  self.selected_filepaths = {}
  self.event_handlers = {}
  self:emit("update")
end

---@param filepath string
function FileSelector:add_selected_file(filepath)
  if not filepath or filepath == "" or has_scheme(filepath) then return end
  if filepath:match("^oil:") then filepath = filepath:gsub("^oil:", "") end
  local absolute_path = Utils.to_absolute_path(filepath)
  if vim.fn.isdirectory(absolute_path) == 1 then
    self:process_directory(absolute_path)
    return
  end
  -- Avoid duplicates
  if not vim.tbl_contains(self.selected_filepaths, absolute_path) then
    table.insert(self.selected_filepaths, absolute_path)
    self:emit("update")
  end
end

function FileSelector:add_current_buffer()
  local current_buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(current_buf)
  if filepath and filepath ~= "" and not has_scheme(filepath) then
    for i, path in ipairs(self.selected_filepaths) do
      if path == filepath then
        table.remove(self.selected_filepaths, i)
        self:emit("update")
        return true
      end
    end
    self:add_selected_file(filepath)
    return true
  end
  return false
end

function FileSelector:on(event, callback)
  local handlers = self.event_handlers[event]
  if not handlers then
    handlers = {}
    self.event_handlers[event] = handlers
  end

  table.insert(handlers, callback)
end

function FileSelector:emit(event, ...)
  local handlers = self.event_handlers[event]
  if not handlers then return end

  for _, handler in ipairs(handlers) do
    handler(...)
  end
end

function FileSelector:off(event, callback)
  if not callback then
    self.event_handlers[event] = {}
    return
  end
  local handlers = self.event_handlers[event]
  if not handlers then return end

  for i, handler in ipairs(handlers) do
    if handler == callback then
      table.remove(handlers, i)
      break
    end
  end
end

function FileSelector:open() self:show_selector_ui() end

---@return string[]
function FileSelector:get_filepaths()
  if type(Config.file_selector.provider_opts.get_filepaths) == "function" then
    ---@type avante.file_selector.opts.IGetFilepathsParams
    local params = {
      cwd = Utils.get_project_root(),
      selected_filepaths = self.selected_filepaths,
    }
    return Config.file_selector.provider_opts.get_filepaths(params)
  end

  ---@type table<string, boolean>
  local selected_filepaths_set = {}
  for _, abs_path in ipairs(self.selected_filepaths) do
    selected_filepaths_set[abs_path] = true
  end

  local project_root = Utils.get_project_root()
  local file_info = get_project_filepaths(selected_filepaths_set)

  table.sort(file_info, function(a, b)
    -- Sort alphabetically with directories being first
    if a.is_dir and not b.is_dir then
      return true
    elseif not a.is_dir and b.is_dir then
      return false
    else
      return a.path < b.path
    end
  end)

  return vim
    .iter(file_info)
    :map(function(info)
      local rel_path = Utils.filesystem.relative(project_root, info.path, false)
      if info.is_dir then rel_path = rel_path .. "/" end
      return rel_path
    end)
    :totable()
end

---@return nil
function FileSelector:show_selector_ui()
  local function handler(selected_paths) self:handle_path_selection(selected_paths) end

  vim.schedule(function()
    if Config.file_selector.provider ~= nil then
      Utils.warn("config.file_selector is deprecated, please use config.selector instead!")
      if type(Config.file_selector.provider) == "function" then
        ---@type string
        local title = string.format("%s:", PROMPT_TITLE)
        ---@type string[]
        local filepaths = self:get_filepaths()
        ---@type avante.file_selector.IParams
        local params = { title = title, filepaths = filepaths, handler = handler }
        Config.file_selector.provider(params)
      else
        ---@type avante.SelectorProvider
        local provider = "native"
        if Config.file_selector.provider == "native" then
          provider = "native"
        elseif Config.file_selector.provider == "fzf" then
          provider = "fzf_lua"
        elseif Config.file_selector.provider == "mini.pick" then
          provider = "mini_pick"
        elseif Config.file_selector.provider == "snacks" then
          provider = "snacks"
        elseif Config.file_selector.provider == "telescope" then
          provider = "telescope"
        elseif type(Config.file_selector.provider) == "function" then
          provider = Config.file_selector.provider --[[@as fun(selector: avante.ui.Selector): nil]]
        end
        ---@cast provider avante.SelectorProvider
        local selector = Selector:new({
          provider = provider,
          title = PROMPT_TITLE,
          items = vim.tbl_map(
            ---@param filepath string
            ---@return avante.ui.SelectorItem
            function(filepath) return { id = filepath, title = filepath } end,
            self:get_filepaths()
          ),
          default_item_id = self.selected_filepaths[1],
          selected_item_ids = self.selected_filepaths,
          provider_opts = Config.file_selector.provider_opts,
          on_select = function(item_ids) self:handle_path_selection(item_ids) end,
          get_preview_content = function(item_id)
            local content = Utils.read_file_from_buf_or_disk(item_id)
            local filetype = Utils.get_filetype(item_id)
            return table.concat(content or {}, "\n"), filetype
          end,
        })
        selector:open()
      end
    else
      local selector = Selector:new({
        provider = Config.selector.provider,
        title = PROMPT_TITLE,
        items = vim.tbl_map(
          ---@param filepath string
          ---@return avante.ui.SelectorItem
          function(filepath) return { id = filepath, title = filepath } end,
          self:get_filepaths()
        ),
        default_item_id = self.selected_filepaths[1],
        selected_item_ids = self.selected_filepaths,
        provider_opts = Config.selector.provider_opts,
        on_select = function(item_ids) self:handle_path_selection(item_ids) end,
        get_preview_content = function(item_id)
          local content = Utils.read_file_from_buf_or_disk(item_id)
          local filetype = Utils.get_filetype(item_id)
          return table.concat(content or {}, "\n"), filetype
        end,
      })
      selector:open()
    end
  end)

  -- unlist the current buffer as vim.ui.select will be listed
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  vim.api.nvim_set_option_value("buflisted", false, { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
end

---@param idx integer
---@return boolean
function FileSelector:remove_selected_filepaths_with_index(idx)
  if idx > 0 and idx <= #self.selected_filepaths then
    table.remove(self.selected_filepaths, idx)
    self:emit("update")
    return true
  end
  return false
end

function FileSelector:remove_selected_file(rel_path)
  local abs_path = Utils.to_absolute_path(rel_path)
  local idx = Utils.tbl_indexof(self.selected_filepaths, abs_path)
  if idx then self:remove_selected_filepaths_with_index(idx) end
end

---@return { path: string, content: string, file_type: string }[]
function FileSelector:get_selected_files_contents()
  local contents = {}
  for _, filepath in ipairs(self.selected_filepaths) do
    local lines, error = Utils.read_file_from_buf_or_disk(filepath)
    lines = lines or {}
    local filetype = Utils.get_filetype(filepath)
    if error ~= nil then
      Utils.error("error reading file: " .. error)
    else
      local content = table.concat(lines, "\n")
      table.insert(contents, { path = filepath, content = content, file_type = filetype })
    end
  end
  return contents
end

function FileSelector:get_selected_filepaths() return vim.deepcopy(self.selected_filepaths) end

---@return nil
function FileSelector:add_quickfix_files()
  ---@type string[]
  local quickfix_files = vim
    .iter(vim.fn.getqflist({ items = 0 }).items)
    :filter(function(item) return item.bufnr ~= 0 end)
    :map(function(item) return vim.api.nvim_buf_get_name(item.bufnr) end)
    :totable()
  for _, filepath in ipairs(quickfix_files) do
    self:add_selected_file(filepath)
  end
end

---@return nil
function FileSelector:add_buffer_files()
  local buffers = vim.api.nvim_list_bufs()
  for _, bufnr in ipairs(buffers) do
    -- Skip invalid or unlisted buffers
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted then
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      -- Skip empty paths and special buffers (like terminals)
      if filepath ~= "" and not has_scheme(filepath) then self:add_selected_file(filepath) end
    end
  end
end

return FileSelector
