local M = {}
local H = require("vim.health")
local Utils = require("avante.utils")
local Config = require("avante.config")

function M.check()
  H.start("avante.nvim")

  -- Required dependencies with their module names
  local required_plugins = {
    ["plenary.nvim"] = {
      path = "nvim-lua/plenary.nvim",
      module = "plenary",
    },
    ["nui.nvim"] = {
      path = "MunifTanjim/nui.nvim",
      module = "nui.popup",
    },
  }

  for name, plugin in pairs(required_plugins) do
    if Utils.has(name) or Utils.has(plugin.module) then
      H.ok(string.format("Found required plugin: %s", plugin.path))
    else
      H.error(string.format("Missing required plugin: %s", plugin.path))
    end
  end

  -- Optional dependencies
  if Utils.icons_enabled() then
    H.ok("Found icons plugin (nvim-web-devicons or mini.icons)")
  else
    H.warn("No icons plugin found (nvim-web-devicons or mini.icons). Icons will not be displayed")
  end

  -- Check input UI provider
  local input_provider = Config.input and Config.input.provider or "native"
  if input_provider == "dressing" then
    Utils.warn(
      "The 'dressing' provider is deprecated. Update your config 'input.provider' to 'native' for instance (see "
    )

    if Utils.has("dressing.nvim") or Utils.has("dressing") then
      H.ok("Found configured input provider: dressing.nvim")
    else
      H.error("Input provider is set to 'dressing' but dressing.nvim is not installed")
    end
  elseif input_provider == "snacks" then
    if Utils.has("snacks.nvim") or Utils.has("snacks") then
      H.ok("Found configured input provider: snacks.nvim")
    else
      H.error("Input provider is set to 'snacks' but snacks.nvim is not installed")
    end
  else
    H.ok("Using native input provider (no additional dependencies required)")
  end

  if Config.provider == "copilot" then
    H.info("Copilot authentication is managed by Rig. Sign in with :Avante copilot login")
  end

  -- Check TreeSitter dependencies
  M.check_treesitter()
end

-- Check TreeSitter functionality and parsers
function M.check_treesitter()
  H.start("TreeSitter Dependencies")

  -- List of important parsers for avante.nvim
  local essential_parsers = {
    "markdown",
  }

  local missing_parsers = {} ---@type string[]

  for _, parser_name in ipairs(essential_parsers) do
    local loaded_parser = vim.treesitter.language.add(parser_name)
    if not loaded_parser then missing_parsers[#missing_parsers + 1] = parser_name end
  end

  if #missing_parsers == 0 then
    H.ok("All essential TreeSitter parsers are installed")
  else
    H.warn(
      string.format(
        "Missing recommended parsers: %s. Install with :TSInstall %s",
        table.concat(missing_parsers, ", "),
        table.concat(missing_parsers, " ")
      )
    )
  end

  -- Check TreeSitter highlight
  local _, highlighter = pcall(require, "vim.treesitter.highlighter")
  if not highlighter then
    H.warn("TreeSitter highlighter not available. Syntax highlighting might be limited")
  else
    H.ok("TreeSitter highlighter is available")
  end
end

return M
