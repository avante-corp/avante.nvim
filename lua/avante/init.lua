local api = vim.api

local Utils = require("avante.utils")
local Sidebar = require("avante.sidebar")
local Selection = require("avante.selection")
local Suggestion = require("avante.suggestion")
local Config = require("avante.config")
local Diff = require("avante.diff")
local RagService = require("avante.rag_service")

---@class Avante
local M = {
  ---@type avante.Sidebar[] we use this to track chat command across tabs
  sidebars = {},
  ---@type avante.Selection[]
  selections = {},
  ---@type avante.Suggestion[]
  suggestions = {},
  ---@type {sidebar?: avante.Sidebar, selection?: avante.Selection, suggestion?: avante.Suggestion}
  current = { sidebar = nil, selection = nil, suggestion = nil },
  ---@type table<string, any> Global ACP client registry for cleanup on exit
  acp_clients = {},
}

M.did_setup = false

-- ACP Client Management Functions
---Register an ACP client for cleanup on exit
---@param client_id string Unique identifier for the client
---@param client any ACP client instance
function M.register_acp_client(client_id, client)
  M.acp_clients[client_id] = client
  Utils.debug("Registered ACP client: " .. client_id)
end

---Unregister an ACP client
---@param client_id string Unique identifier for the client
function M.unregister_acp_client(client_id)
  M.acp_clients[client_id] = nil
  Utils.debug("Unregistered ACP client: " .. client_id)
end

---Cleanup all registered ACP clients
function M.cleanup_all_acp_clients()
  Utils.debug("Cleaning up all ACP clients...")
  for client_id, client in pairs(M.acp_clients) do
    if client and client.stop then
      Utils.debug("Stopping ACP client: " .. client_id)
      pcall(function() client:stop() end)
    end
  end
  M.acp_clients = {}
  Utils.debug("All ACP clients cleaned up")
end

local H = {}

function H.load_path()
  local ok, LazyConfig = pcall(require, "lazy.core.config")

  if ok then
    Utils.debug("LazyConfig loaded")
    local name = "avante.nvim"
    local function load_path() require("avante_lib").load() end

    if LazyConfig.plugins[name] and LazyConfig.plugins[name]._.loaded then
      vim.schedule(load_path)
    else
      api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        callback = function(event)
          if event.data == name then
            load_path()
            return true
          end
        end,
      })
    end

    api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      callback = load_path,
    })
  else
    require("avante_lib").load()
  end
end

function H.keymaps()
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteAsk)", function() require("avante.api").ask() end, { noremap = true })
  vim.keymap.set(
    { "n", "v" },
    "<Plug>(AvanteAskNew)",
    function() require("avante.api").ask({ new_chat = true }) end,
    { noremap = true }
  )
  vim.keymap.set(
    { "n", "v" },
    "<Plug>(AvanteChat)",
    function() require("avante.api").ask({ ask = false }) end,
    { noremap = true }
  )
  vim.keymap.set("v", "<Plug>(AvanteEdit)", function() require("avante.api").edit() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteRefresh)", function() require("avante.api").refresh() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteFocus)", function() require("avante.api").focus() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteBuild)", function() require("avante.api").build() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteToggle)", function() M.toggle() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteToggleDebug)", function() M.toggle.debug() end)
  vim.keymap.set("n", "<Plug>(AvanteToggleSelection)", function() M.toggle.selection() end)
  vim.keymap.set("n", "<Plug>(AvanteToggleSuggestion)", function() M.toggle.suggestion() end)

  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictOurs)", function() Diff.choose("ours") end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictBoth)", function() Diff.choose("both") end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictTheirs)", function() Diff.choose("theirs") end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictAllTheirs)", function() Diff.choose("all_theirs") end)
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteConflictCursor)", function() Diff.choose("cursor") end)
  vim.keymap.set("n", "<Plug>(AvanteConflictNextConflict)", function() Diff.find_next("ours") end)
  vim.keymap.set("n", "<Plug>(AvanteConflictPrevConflict)", function() Diff.find_prev("ours") end)
  vim.keymap.set("n", "<Plug>(AvanteSelectModel)", function() require("avante.api").select_model() end)

  if Config.behaviour.auto_set_keymaps then
    Utils.safe_keymap_set(
      { "n", "v" },
      Config.mappings.ask,
      function() require("avante.api").ask() end,
      { desc = "avante: ask" }
    )
    Utils.safe_keymap_set(
      { "n", "v" },
      Config.mappings.zen_mode,
      function() require("avante.api").zen_mode() end,
      { desc = "avante: toggle Zen Mode" }
    )
    Utils.safe_keymap_set(
      { "n", "v" },
      Config.mappings.new_ask,
      function() require("avante.api").ask({ new_chat = true }) end,
      { desc = "avante: create new ask" }
    )
    Utils.safe_keymap_set(
      "v",
      Config.mappings.edit,
      function() require("avante.api").edit() end,
      { desc = "avante: edit" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.stop,
      function() require("avante.api").stop() end,
      { desc = "avante: stop" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.refresh,
      function() require("avante.api").refresh() end,
      { desc = "avante: refresh" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.focus,
      function() require("avante.api").focus() end,
      { desc = "avante: focus" }
    )

    Utils.safe_keymap_set("n", Config.mappings.toggle.default, function() M.toggle() end, { desc = "avante: toggle" })
    Utils.safe_keymap_set(
      "n",
      Config.mappings.toggle.debug,
      function() M.toggle.debug() end,
      { desc = "avante: toggle debug" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.toggle.selection,
      function() M.toggle.hint() end,
      { desc = "avante: toggle selection" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.toggle.suggestion,
      function() M.toggle.suggestion() end,
      { desc = "avante: toggle suggestion" }
    )
    Utils.safe_keymap_set("n", Config.mappings.toggle.repomap, function() require("avante.repo_map").show() end, {
      desc = "avante: display repo map",
      noremap = true,
      silent = true,
    })

    Utils.safe_keymap_set(
      "n",
      Config.mappings.select_model,
      function() require("avante.api").select_model() end,
      { desc = "avante: select model" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.select_history,
      function() require("avante.api").select_history() end,
      { desc = "avante: select history" }
    )
    Utils.safe_keymap_set(
      "n",
      Config.mappings.select_prompt,
      function() require("avante.api").select_prompt() end,
      { desc = "avante: select and reuse prompt" }
    )

    Utils.safe_keymap_set(
      "n",
      Config.mappings.files.add_all_buffers,
      function() require("avante.api").add_buffer_files() end,
      { desc = "avante: add all open buffers" }
    )
  end

  if Config.behaviour.auto_suggestions then
    Utils.safe_keymap_set("i", Config.mappings.suggestion.accept, function()
      local _, _, sg = M.get()
      sg:accept()
    end, {
      desc = "avante: accept suggestion",
      noremap = true,
      silent = true,
    })

    Utils.safe_keymap_set("i", Config.mappings.suggestion.dismiss, function()
      local _, _, sg = M.get()
      if sg:is_visible() then sg:dismiss() end
    end, {
      desc = "avante: dismiss suggestion",
      noremap = true,
      silent = true,
    })

    Utils.safe_keymap_set("i", Config.mappings.suggestion.next, function()
      local _, _, sg = M.get()
      sg:next()
    end, {
      desc = "avante: next suggestion",
      noremap = true,
      silent = true,
    })

    Utils.safe_keymap_set("i", Config.mappings.suggestion.prev, function()
      local _, _, sg = M.get()
      sg:prev()
    end, {
      desc = "avante: previous suggestion",
      noremap = true,
      silent = true,
    })
  end
end

---@class ApiCaller
---@operator call(...): any

function H.api(fun)
  return setmetatable({ api = true }, {
    __call = function(...) return fun(...) end,
  }) --[[@as ApiCaller]]
end

function H.signs() vim.fn.sign_define("AvanteInputPromptSign", { text = Config.windows.input.prefix }) end

H.augroup = api.nvim_create_augroup("avante_autocmds", { clear = true })

function H.autocmds()
  api.nvim_create_autocmd("TabEnter", {
    group = H.augroup,
    pattern = "*",
    once = true,
    callback = function(ev)
      local tab = tonumber(ev.file)
      M._init(tab or api.nvim_get_current_tabpage())
      if Config.selection.enabled and not M.current.selection.did_setup then M.current.selection:setup_autocmds() end
    end,
  })

  api.nvim_create_autocmd("VimResized", {
    group = H.augroup,
    callback = function()
      local sidebar = M.get()
      if not sidebar then return end
      if not sidebar:is_open() then return end
      sidebar:resize()
    end,
  })

  api.nvim_create_autocmd("QuitPre", {
    group = H.augroup,
    callback = function()
      local current_buf = vim.api.nvim_get_current_buf()
      if Utils.is_sidebar_buffer(current_buf) then return end

      local non_sidebar_wins = 0
      local sidebar_wins = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local win_buf = vim.api.nvim_win_get_buf(win)
          if Utils.is_sidebar_buffer(win_buf) then
            table.insert(sidebar_wins, win)
          else
            non_sidebar_wins = non_sidebar_wins + 1
          end
        end
      end

      if non_sidebar_wins <= 1 then
        for _, win in ipairs(sidebar_wins) do
          pcall(vim.api.nvim_win_close, win, false)
        end
      end
    end,
    nested = true,
  })

  api.nvim_create_autocmd("TabClosed", {
    group = H.augroup,
    pattern = "*",
    callback = function(ev)
      local tab = tonumber(ev.file)
      local s = M.sidebars[tab]
      local sl = M.selections[tab]
      if s then s:reset() end
      if sl then sl:delete_autocmds() end
      if tab ~= nil then M.sidebars[tab] = nil end
    end,
  })

  -- Cleanup ACP on Neovim exit
  api.nvim_create_autocmd("VimLeavePre", {
    group = H.augroup,
    desc = "Cleanup ACP processes before Neovim exits",
    callback = function()
      Utils.debug("VimLeavePre: Starting ACP cleanup...")

      -- Do NOT cancel inflight requests on exit — let the agent session continue
      -- running on the server side. The session can be resumed later.
      -- Only cancel/cleanup if explicitly configured to do so.
      if Config.behaviour.prompt_on_exit_with_active_session then
        local ok, Llm = pcall(require, "avante.llm")
        if ok then pcall(function() Llm.cancel_inflight_request() end) end
        M.cleanup_all_acp_clients()
      end
      -- Otherwise, just disconnect cleanly without cancelling sessions

      Utils.debug("VimLeavePre: ACP cleanup completed")
    end,
  })

  vim.schedule(function()
    M._init(api.nvim_get_current_tabpage())
    if Config.selection.enabled then M.current.selection:setup_autocmds() end
  end)

  local function setup_colors()
    Utils.debug("Setting up avante colors")
    require("avante.highlights").setup()
  end

  api.nvim_create_autocmd("ColorSchemePre", {
    group = H.augroup,
    callback = function()
      vim.schedule(function() setup_colors() end)
    end,
  })

  api.nvim_create_autocmd("ColorScheme", {
    group = H.augroup,
    callback = function()
      vim.schedule(function() setup_colors() end)
    end,
  })

  -- automatically setup Avante filetype to markdown
  vim.treesitter.language.register("markdown", "Avante")

  vim.filetype.add({
    extension = {
      ["avanterules"] = "jinja",
    },
    pattern = {
      ["%.avanterules%.[%w_.-]+"] = "jinja",
    },
  })
end

---@param current boolean? false to disable setting current, otherwise use this to track across tabs.
---@return avante.Sidebar, avante.Selection, avante.Suggestion
function M.get(current)
  local tab = api.nvim_get_current_tabpage()
  local sidebar = M.sidebars[tab]
  local selection = M.selections[tab]
  local suggestion = M.suggestions[tab]
  if current ~= false then
    M.current.sidebar = sidebar
    M.current.selection = selection
    M.current.suggestion = suggestion
  end
  return sidebar, selection, suggestion
end

---@param id integer
function M._init(id)
  local sidebar = M.sidebars[id]
  local selection = M.selections[id]
  local suggestion = M.suggestions[id]

  if not sidebar then
    sidebar = Sidebar:new(id)
    M.sidebars[id] = sidebar
  end
  if not selection then
    selection = Selection:new(id)
    M.selections[id] = selection
  end
  if not suggestion then
    suggestion = Suggestion:new(id)
    M.suggestions[id] = suggestion
  end
  M.current = { sidebar = sidebar, selection = selection, suggestion = suggestion }
  return M
end

M.toggle = { api = true }

---@param opts? AskOptions
function M.toggle_sidebar(opts)
  opts = opts or {}
  if opts.ask == nil then opts.ask = true end

  local sidebar = M.get()
  if not sidebar then
    M._init(api.nvim_get_current_tabpage())
    ---@cast opts SidebarOpenOptions
    M.current.sidebar:open(opts)
    return true
  end

  return sidebar:toggle(opts)
end

function M.is_sidebar_open()
  local sidebar = M.get()
  if not sidebar then return false end
  return sidebar:is_open()
end

---@param opts? AskOptions
function M.open_sidebar(opts)
  opts = opts or {}
  if opts.ask == nil then opts.ask = true end
  local sidebar = M.get()
  if not sidebar then M._init(api.nvim_get_current_tabpage()) end
  ---@cast opts SidebarOpenOptions
  M.current.sidebar:open(opts)
end

function M.close_sidebar()
  local sidebar = M.get()
  if not sidebar then return end
  sidebar:close()
end

M.toggle.debug = H.api(Utils.toggle_wrap({
  name = "debug",
  get = function() return Config.debug end,
  set = function(state) Config.override({ debug = state }) end,
}))

M.toggle.selection = H.api(Utils.toggle_wrap({
  name = "selection",
  get = function() return Config.selection.enabled end,
  set = function(state) Config.override({ selection = { enabled = state } }) end,
}))

M.toggle.suggestion = H.api(Utils.toggle_wrap({
  name = "suggestion",
  get = function() return Config.behaviour.auto_suggestions end,
  set = function(state)
    Config.override({ behaviour = { auto_suggestions = state } })
    local _, _, sg = M.get()
    if state ~= false then
      if sg then sg:setup_autocmds() end
      H.keymaps()
    else
      if sg then sg:delete_autocmds() end
    end
  end,
}))

setmetatable(M.toggle, {
  __index = M.toggle,
  __call = function() M.toggle_sidebar() end,
})

M.slash_commands_id = nil

---@param opts? avante.Config
function M.setup(opts)
  ---PERF: we can still allow running require("avante").setup() multiple times to override config if users wish to
  ---but most of the other functionality will only be called once from lazy.nvim
  Config.setup(opts)

  if M.did_setup then return end

  H.load_path()

  require("avante.html2md").setup()
  require("avante.repo_map").setup()
  require("avante.path").setup()
  require("avante.highlights").setup()
  require("avante.diff").setup()
  require("avante.providers").setup()
  require("avante.clipboard").setup()

  -- Initialize notification system
  if Config.notifications.enabled then
    local ok, Notifications = pcall(require, "avante.notifications")
    if ok then
      Notifications.setup()
    else
      if Config.debug then
        Utils.warn("Failed to initialize notification system", { once = true })
      end
    end
  end

  -- TODO: pinned threads startup check disabled — scanning 1500+ history files blocks the UI.
  -- Re-enable once list_all() is made async or uses a metadata index.

  -- setup helpers
  H.autocmds()
  H.keymaps()
  H.signs()

  M.did_setup = true

  local function run_rag_service()
    local started_at = os.time()
    local add_resource_with_delay
    local function add_resource()
      local is_ready = RagService.is_ready()
      if not is_ready then
        local elapsed = os.time() - started_at
        if elapsed > 1000 * 60 * 15 then
          Utils.warn("Rag Service is not ready, giving up")
          return
        end
        add_resource_with_delay()
        return
      end
      vim.defer_fn(function()
        Utils.info("Adding project root to Rag Service ...")
        local uri = "file://" .. Utils.get_project_root()
        if uri:sub(-1) ~= "/" then uri = uri .. "/" end
        RagService.add_resource(uri)
      end, 5000)
    end
    add_resource_with_delay = function()
      vim.defer_fn(function() add_resource() end, 5000)
    end
    vim.schedule(function()
      Utils.info("Starting Rag Service ...")
      RagService.launch_rag_service(add_resource_with_delay)
    end)
  end

  if Config.rag_service.enabled then run_rag_service() end

  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp then
    M.slash_commands_id = cmp.register_source("avante_commands", require("cmp_avante.commands"):new())

    cmp.register_source("avante_mentions", require("cmp_avante.mentions"):new(Utils.get_chat_mentions))

    cmp.register_source("avante_prompt_mentions", require("cmp_avante.mentions"):new(Utils.get_mentions))

    cmp.register_source("avante_shortcuts", require("cmp_avante.shortcuts"):new())

    cmp.setup.filetype({ "AvanteInput" }, {
      enabled = true,
      sources = {
        { name = "avante_commands" },
        { name = "avante_mentions" },
        { name = "avante_shortcuts" },
        { name = "avante_files" },
      },
    })

    cmp.setup.filetype({ "AvantePromptInput" }, {
      enabled = true,
      sources = {
        { name = "avante_prompt_mentions" },
      },
    })
  end
end

return M