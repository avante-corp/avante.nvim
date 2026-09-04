---@mod avante-nvim avante.nvim
---
---@brief [[
--- avante.nvim is a Neovim plugin designed to emulate the behaviour of the Cursor
--- AI IDE. It provides AI-driven code suggestions, chat, code editing, and the
--- ability to apply recommendations directly to source files.
---
--- Main features:
---
--- - AI-powered code assistance for the current file or selected context.
--- - One-command application of suggested changes.
--- - Project-specific instruction files with `avante.md`.
--- - Agentic mode with tool use.
--- - ACP integration for agents such as Gemini CLI, Claude Code, Goose, Codex,
---   and Kimi CLI.
--- - Optional RAG service and web-search tools.
---
---@brief ]]
---@toc avante-contents
---
---@mod avante-installation Installation
---
---@brief [[
---See the official README at https://github.com/yetone/avante.nvim for installation instructions.
---@brief ]]
---
---@mod avante-requirements Requirements
---@brief [[
--- avante.nvim requires Neovim 0.12.0 or later.
--- Mandatory dependencies are:
--- - 'nvim-lua/plenary.nvim'
--- - 'MunifTanjim/nui.nvim'.
---
--- Optional dependencies are:
--- - 'MeanderingProgrammer/render-markdown.nvim'
--- - https://github.com/Kaiser-Yang/blink-cmp-avante for autocompletion
---
--- If you wish to build from source, then `cargo` is required. Otherwise `curl` and `tar` will be used to get prebuilt binary from GitHub. See |:AvanteBuild|.
---@brief ]]
---@mod avante-usage Usage
---
---@brief [[
--- Basic workflow:
---
--- 1. Open a code file in Neovim.
--- 2. Run |:AvanteAsk| with a question, or open the chat with |:AvanteChat|.
--- 3. Review the AI response and suggested changes.
--- 4. Apply edits from the sidebar with the configured keymaps.
---@brief ]]
---@tag avante-zen-mode
---@brief [[
---This is an era of Coding Agent CLIs. Allegedly "editors are no longer needed": you only need to use the CLI in the terminal. But have people realized that for more than half a century, Terminal-based Editors have solved and standardized the biggest problem with Terminal-based applications — that is, the awkward TUI interactions! No matter how much these Coding Agent CLIs optimize their UI/UX, their UI/UX will always be a subset of Terminal-based Editors (Vim, Emacs)! They cannot achieve Vim’s elegant action + text objects abstraction (imagine how you usually edit large multi-line prompts in an Agent CLI), nor can they leverage thousands of mature Vim/Neovim plugins to help optimize TUI UI/UX—such as easymotions and so on. Moreover, when they want to view or modify code, they often have to jump into other applications which forcibly interrupts the UI/UX experience.
---Therefore, Avante’s Zen Mode was born! It looks like a Vibe Coding Agent CLI but it is completely Neovim underneath. So you can use your muscle-memory Vim operations and those rich and mature Neovim plugins on it. At the same time, by leveraging [ACP](https://github.com/yetone/avante.nvim#acp-support) it has all capabilities of claude code / gemini-cli / codex! Why not enjoy both?
---Now all you need to do is alias this command to avante; then every time you simply type avante just like using claude code and enter Avante’s Zen Mode!
---@brief ]]
---@mod avante

local api = vim.api

local Utils = require("avante.utils")
local Config = require("avante.config")

---@class Avante
local M = {
  --- per tab sidebar
  ---@type avante.Sidebar[] we use this to track chat command across tabs
  sidebars = {},
  --- per tab selection
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

---Registers keymaps
---@see avante.Config.mappings
function H.keymaps()
  local Diff = require("avante.diff")
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
  vim.keymap.set({ "n", "v" }, "<Plug>(AvanteZenMode)", function() require("avante.api").zen_mode() end, {
    noremap = true,
  })
  vim.keymap.set("v", "<Plug>(AvanteEdit)", function() require("avante.api").edit() end, { noremap = true })
  vim.keymap.set("n", "<Plug>(AvanteStop)", function() require("avante.api").stop() end, { noremap = true })
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
  vim.keymap.set("n", "<Plug>(AvanteSelectHistory)", function() require("avante.api").select_history() end)
  vim.keymap.set("n", "<Plug>(AvanteSelectACPModel)", function() require("avante.api").select_acp_model() end, {
    noremap = true,
  })
  vim.keymap.set("n", "<Plug>(AvanteSelectACPMode)", function() require("avante.api").select_acp_mode() end, {
    noremap = true,
  })
  vim.keymap.set("n", "<Plug>(AvanteShowRepoMap)", function() require("avante.repo_map").show() end, {
    noremap = true,
    silent = true,
  })
  vim.keymap.set("n", "<Plug>(AvanteAddAllBuffers)", function() require("avante.api").add_buffer_files() end, {
    noremap = true,
  })

  vim.keymap.set("i", "<Plug>(AvanteSuggestionAccept)", function()
    local _, _, sg = M.get()
    sg:accept()
  end, { noremap = true, silent = true })
  vim.keymap.set("i", "<Plug>(AvanteSuggestionDismiss)", function()
    local _, _, sg = M.get()
    if sg:is_visible() then sg:dismiss() end
  end, { noremap = true, silent = true })
  vim.keymap.set("i", "<Plug>(AvanteSuggestionNext)", function()
    local _, _, sg = M.get()
    sg:next()
  end, { noremap = true, silent = true })
  vim.keymap.set("i", "<Plug>(AvanteSuggestionPrev)", function()
    local _, _, sg = M.get()
    sg:prev()
  end, { noremap = true, silent = true })

  local has_lazy, _ = pcall(require, "lazy.core.handler")

  local safe_keymap_set = vim.keymap.set

  if has_lazy then
    safe_keymap_set = Utils.safe_keymap_set
    Utils.debug("lazy.nvim is available. Using Utils.safe_keymap_set")
  end

  if Config.behaviour.auto_set_keymaps then
    safe_keymap_set({ "n", "v" }, Config.mappings.ask, "<Plug>(AvanteAsk)", { desc = "avante: ask" })
    safe_keymap_set(
      { "n", "v" },
      Config.mappings.zen_mode,
      "<Plug>(AvanteZenMode)",
      { desc = "avante: toggle Zen Mode" }
    )
    safe_keymap_set({ "n", "v" }, Config.mappings.new_ask, "<Plug>(AvanteAskNew)", { desc = "avante: create new ask" })
    safe_keymap_set("v", Config.mappings.edit, "<Plug>(AvanteEdit)", { desc = "avante: edit" })
    safe_keymap_set("n", Config.mappings.stop, "<Plug>(AvanteStop)", { desc = "avante: stop" })
    safe_keymap_set("n", Config.mappings.refresh, "<Plug>(AvanteRefresh)", { desc = "avante: refresh" })
    safe_keymap_set("n", Config.mappings.focus, "<Plug>(AvanteFocus)", { desc = "avante: focus" })

    safe_keymap_set("n", Config.mappings.toggle.default, "<Plug>(AvanteToggle)", { desc = "avante: toggle" })
    safe_keymap_set("n", Config.mappings.toggle.debug, "<Plug>(AvanteToggleDebug)", { desc = "avante: toggle debug" })
    safe_keymap_set(
      "n",
      Config.mappings.toggle.selection,
      "<Plug>(AvanteToggleSelection)",
      { desc = "avante: toggle selection" }
    )
    safe_keymap_set(
      "n",
      Config.mappings.toggle.suggestion,
      "<Plug>(AvanteToggleSuggestion)",
      { desc = "avante: toggle suggestion" }
    )
    safe_keymap_set("n", Config.mappings.toggle.repomap, "<Plug>(AvanteShowRepoMap)", {
      desc = "avante: display repo map",
      noremap = true,
      silent = true,
    })
    safe_keymap_set("n", Config.mappings.select_model, "<Plug>(AvanteSelectModel)", { desc = "avante: select model" })
    safe_keymap_set(
      "n",
      Config.mappings.select_history,
      "<Plug>(AvanteSelectHistory)",
      { desc = "avante: select history" }
    )
    safe_keymap_set(
      "n",
      Config.mappings.select_acp_model,
      "<Plug>(AvanteSelectACPModel)",
      { desc = "avante: select ACP model" }
    )
    safe_keymap_set(
      "n",
      Config.mappings.select_acp_mode,
      "<Plug>(AvanteSelectACPMode)",
      { desc = "avante: select ACP mode" }
    )

    safe_keymap_set(
      "n",
      Config.mappings.files.add_all_buffers,
      "<Plug>(AvanteAddAllBuffers)",
      { desc = "avante: add all open buffers" }
    )
  end

  if Config.behaviour.auto_suggestions then
    safe_keymap_set("i", Config.mappings.suggestion.accept, "<Plug>(AvanteSuggestionAccept)", {
      desc = "avante: accept suggestion",
      noremap = true,
      silent = true,
    })

    safe_keymap_set("i", Config.mappings.suggestion.dismiss, "<Plug>(AvanteSuggestionDismiss)", {
      desc = "avante: dismiss suggestion",
      noremap = true,
      silent = true,
    })

    safe_keymap_set("i", Config.mappings.suggestion.next, "<Plug>(AvanteSuggestionNext)", {
      desc = "avante: next suggestion",
      noremap = true,
      silent = true,
    })

    safe_keymap_set("i", Config.mappings.suggestion.prev, "<Plug>(AvanteSuggestionPrev)", {
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

  -- Fix Issue #2749: Cleanup ACP processes on Neovim exit
  api.nvim_create_autocmd("VimLeavePre", {
    group = H.augroup,
    desc = "Cleanup all ACP processes before Neovim exits",
    callback = function()
      Utils.debug("VimLeavePre: Starting ACP cleanup...")
      -- Cancel any inflight requests first
      local ok, Llm = pcall(require, "avante.llm")
      if ok then pcall(function() Llm.cancel_inflight_request() end) end
      -- Cleanup all registered ACP clients
      M.cleanup_all_acp_clients()
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
    local Sidebar = require("avante.sidebar")
    sidebar = Sidebar:new(id)
    M.sidebars[id] = sidebar
  end
  if not selection then
    local Selection = require("avante.selection")
    selection = Selection:new(id)
    M.selections[id] = selection
  end
  if not suggestion then
    local Suggestion = require("avante.suggestion")
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

---Main setup function that calls each submodule (repo_map, html2md,...) setup.
---It is advised to pass configuration via vim.g.avante instead
---@see vim.g.avante
---@param opts? avante.Config
function M.setup(opts)
  ---PERF: we can still allow running require("avante").setup() multiple times to override config if users wish to
  ---but most of the other functionality will only be called once from lazy.nvim
  Config.setup(opts)
  require("avante.utils.log").set_level(vim.g.avante.log_level)

  if M.did_setup then return end

  require("avante.html2md").setup()
  require("avante.repo_map").setup()
  require("avante.path").setup()
  require("avante.highlights").setup()
  require("avante.diff").setup()
  require("avante.providers").setup()
  require("avante.clipboard").setup()

  -- setup helpers
  H.autocmds()
  H.keymaps()
  H.signs()

  M.did_setup = true

  if Config.rag_service.enabled then require("avante.rag_service").run_rag_service() end

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
