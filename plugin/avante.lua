if vim.fn.has("nvim-0.12") == 0 then
  vim.api.nvim_echo({
    { "Avante requires at least nvim-0.12", "ErrorMsg" },
    { "Please upgrade your neovim version", "WarningMsg" },
    { "Press any key to exit", "ErrorMsg" },
  }, true, {})
  vim.fn.getchar()
  vim.cmd([[quit]])
end

if vim.g.avante_loaded ~= nil then return end

vim.g.avante_loaded = 1

--- NOTE: We will override vim.paste if img-clip.nvim is available to work with avante.nvim internal logic paste
local Config = require("avante.config")
local Utils = require("avante.utils")
local P = require("avante.path")
local api = vim.api

if Config.support_paste_image() then
  vim.paste = (function(overridden)
    ---@param lines string[]
    ---@param phase -1|1|2|3
    return function(lines, phase)
      local Clipboard = require("avante.clipboard")
      -- NOTE: require("img-clip.util").verbose = false does NOT silence warnings
      -- because img-clip's warn() reads config.get_opt("verbose"), not util.verbose.
      -- Suppress via api_opts which has highest priority in img-clip's config lookup.
      require("img-clip.config").api_opts = { default = { verbose = false } }

      local bufnr = vim.api.nvim_get_current_buf()
      local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if filetype ~= "AvanteInput" then return overridden(lines, phase) end

      ---@type string
      local line = lines[1]

      -- Only attempt image paste if the line looks like an image path/URL,
      -- or if the clipboard actually contains an image. This avoids the
      -- "Content is not an image" warning when Chinese IME commits text via
      -- vim.paste (which is not a real paste from clipboard).
      local img_clip_util = require("img-clip.util")
      local img_clip_clipboard = require("img-clip.clipboard")
      local is_image_candidate = (line and (img_clip_util.is_image_url(line) or img_clip_util.is_image_path(line)))
        or img_clip_clipboard.content_is_image()
      if not is_image_candidate then return overridden(lines, phase) end

      local ok = Clipboard.paste_image(line)
      if not ok then return overridden(lines, phase) end

      -- After pasting, insert a new line and set cursor to this line
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
      local last_line = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(0, { last_line, 0 })
    end
  end)(vim.paste)
end

local function ask_complete(prefix, _, _)
  local candidates = {} ---@type string[]
  vim.list_extend(
    candidates,
    ---@param x string
    vim.tbl_map(function(x) return "position=" .. x end, { "left", "right", "top", "bottom" })
  )
  vim.list_extend(
    candidates,
    ---@param x string
    vim.tbl_map(function(x) return "project_root=" .. x.root end, P.list_projects())
  )
  return vim.tbl_filter(function(candidate) return vim.startswith(candidate, prefix) end, candidates)
end

api.nvim_create_user_command("AvanteAsk", function(opts)
  ---@type AskOptions
  local args = { question = nil, win = {} }

  local parsed_args, question = Utils.parse_args(opts.fargs, {
    collect_remaining = true,
    boolean_keys = { "ask" },
  })

  if parsed_args.position then args.win.position = parsed_args.position end

  require("avante.api").ask(vim.tbl_deep_extend("force", args, {
    ask = parsed_args.ask,
    project_root = parsed_args.project_root,
    question = question or nil,
  }))
end, {
  desc = "avante: ask AI for code suggestions",
  nargs = "*",
  complete = ask_complete,
})
api.nvim_create_user_command("AvanteChat", function(opts)
  local args = Utils.parse_args(opts.fargs)
  args.ask = false

  require("avante.api").ask(args)
end, {
  desc = "avante: chat with the codebase",
  nargs = "*",
  complete = ask_complete,
})
api.nvim_create_user_command("AvanteChatNew", function(opts)
  local args = Utils.parse_args(opts.fargs)
  args.ask = false
  args.new_chat = true
  require("avante.api").ask(args)
end, { desc = "avante: create new chat", nargs = "*", complete = ask_complete })
api.nvim_create_user_command("AvanteToggle", function() require("avante").toggle() end, {
  desc = "avante: toggle AI panel",
  nargs = 0,
})
api.nvim_create_user_command("AvanteBuild", function(opts)
  local args = Utils.parse_args(opts.fargs)

  if args.source == nil then args.source = false end

  require("avante.api").build(args)
end, {
  desc = "avante: build dependencies",
  nargs = "*",
  complete = function(_, _, _) return { "source=true", "source=false" } end,
})
api.nvim_create_user_command(
  "AvanteEdit",
  function(opts) require("avante.api").edit(vim.trim(opts.args), opts.line1, opts.line2) end,
  { desc = "avante: edit selected block", nargs = "*", range = 2 }
)
api.nvim_create_user_command("AvanteRefresh", function() require("avante.api").refresh() end, {
  desc = "avante: refresh windows",
  nargs = 0,
})
api.nvim_create_user_command("AvanteFocus", function() require("avante.api").focus() end, {
  desc = "avante: switch focus windows",
  nargs = 0,
})
api.nvim_create_user_command("AvanteSwitchProvider", function(_opts)
  local providers = vim.tbl_keys(Config.providers)
  vim.list_extend(providers, vim.tbl_keys(Config.acp_providers))
  vim.ui.select(providers, { prompt = "Provider> " }, function(choice, idx)
    if idx ~= nil then require("avante.api").switch_provider(vim.trim(choice)) end
  end)
end, {
  nargs = 0,
  desc = "avante: switch provider",
})
api.nvim_create_user_command(
  "AvanteSwitchSelectorProvider",
  function(opts) require("avante.api").switch_selector_provider(vim.trim(opts.args or "")) end,
  {
    nargs = 1,
    desc = "avante: switch selector provider",
  }
)
api.nvim_create_user_command(
  "AvanteSwitchInputProvider",
  function(opts) require("avante.api").switch_input_provider(vim.trim(opts.args or "")) end,
  {
    nargs = 1,
    desc = "avante: switch input provider",
    complete = function(_, line, _)
      local prefix = line:match("AvanteSwitchInputProvider%s*(.*)$") or ""
      local providers = { "native", "dressing", "snacks" }
      return vim.tbl_filter(function(key) return key:find(prefix, 1, true) == 1 end, providers)
    end,
  }
)
api.nvim_create_user_command("AvanteClear", function(opts)
  local arg = vim.trim(opts.args or "")
  arg = arg == "" and "history" or arg
  if arg == "history" then
    local sidebar = require("avante").get()
    if not sidebar then
      Utils.error("No sidebar found")
      return
    end
    sidebar:clear_history()
  elseif arg == "cache" then
    local history_path = vim.fs.abspath(tostring(P.history_path))
    local cache_path = vim.fs.abspath(tostring(P.cache_path))
    local prompt = string.format("Recursively delete %s and %s?", history_path, cache_path)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then P.clear() end
  else
    Utils.error("Invalid argument. Valid arguments: 'history', 'memory', 'cache'")
    return
  end
end, {
  desc = "avante: clear history, memory or cache",
  nargs = "?",
  complete = function(_, _, _) return { "history", "cache" } end,
})
api.nvim_create_user_command("AvanteShowRepoMap", function() require("avante.repo_map").show() end, {
  desc = "avante: show repo map",
  nargs = 0,
})
api.nvim_create_user_command("AvanteModels", function() require("avante.model_selector").open() end, {
  desc = "avante: show models",
  nargs = 0,
})
api.nvim_create_user_command("AvanteACPModels", function() require("avante.api").select_acp_model() end, {
  desc = "avante: switch ACP model",
  nargs = 0,
})
api.nvim_create_user_command("AvanteACPModes", function() require("avante.api").select_acp_mode() end, {
  desc = "avante: switch ACP mode",
  nargs = 0,
})
api.nvim_create_user_command("AvanteHistory", function() require("avante.api").select_history() end, {
  desc = "avante: show histories",
  nargs = 0,
})
api.nvim_create_user_command("AvanteStop", function() require("avante.api").stop() end, {
  desc = "avante: stop current AI request",
  nargs = 0,
})
