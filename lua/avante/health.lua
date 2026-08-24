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

  -- Check Copilot if configured
  if Config.provider and Config.provider == "copilot" then
    if Utils.has("copilot.lua") or Utils.has("copilot.vim") or Utils.has("copilot") then
      H.ok("Found Copilot plugin")
    else
      H.error("Copilot provider is configured but neither copilot.lua nor copilot.vim is installed")
    end
  end

  -- Check ACP backend
  M.check_acp_backend()

  -- Check TreeSitter dependencies
  M.check_treesitter()

  -- Check notification tools
  M.check_notification_tools()
end

-- Check ACP backend availability
function M.check_acp_backend()
  H.start("ACP Backend")
  local acp_backend = Config.acp_backend or "lua"
  H.info("Configured ACP backend: " .. acp_backend)

  local ok_bridge, ACPBridge = pcall(require, "avante.acp.bridge")
  if not ok_bridge then
    H.error("Failed to load avante.acp.bridge: " .. tostring(ACPBridge))
    return
  end

  local command, args, err = ACPBridge.resolve_interpreter()
  if command then
    H.ok("Python ACP bridge interpreter: " .. command .. " " .. table.concat(args or {}, " "))
  else
    H.warn(err or "No Python environment found for the ACP bridge")
  end

  if acp_backend == "python" then
    if command then
      H.ok("Using the Python ACP bridge (full protocol support: terminals, resume, MCP forwarding)")
    else
      H.error("acp_backend is 'python' but no interpreter was found. Run: cd " .. ACPBridge.plugin_root() .. "/python && uv sync")
    end
  elseif acp_backend == "lua" then
    H.ok("Using the Lua ACP backend (built-in)")
    H.info(
      "The Lua backend does not implement terminal/*, session/resume or MCP forwarding. "
        .. "Set acp_backend = 'python' for full protocol support."
    )
  else
    H.warn("Unknown acp_backend '" .. tostring(acp_backend) .. "'. Expected 'lua' or 'python'.")
  end
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

-- Check notification tool availability
function M.check_notification_tools()
  H.start("Desktop Notifications")
  
  if not Config.notifications.enabled then
    H.info("Desktop notifications are disabled in config")
    return
  end
  
  local os_name = vim.uv.os_uname().sysname
  local tool_name, install_cmd, optional_tool
  
  if os_name == "Darwin" then
    tool_name = "osascript"
    install_cmd = "Built-in on macOS"
    optional_tool = "terminal-notifier"
  elseif os_name == "Linux" then
    tool_name = "notify-send"
    install_cmd = "sudo apt install libnotify-bin (Ubuntu/Debian) or sudo pacman -S libnotify (Arch)"
  elseif os_name == "Windows_NT" then
    tool_name = "powershell"
    install_cmd = "Built-in on Windows 10+"
  else
    H.warn("Unknown operating system: " .. os_name)
    return
  end
  
  -- Check primary notification tool
  if vim.fn.executable(tool_name) == 1 then
    H.ok(string.format("Notification tool '%s' is available", tool_name))
  else
    H.warn(
      string.format("Notification tool '%s' not found", tool_name),
      install_cmd
    )
  end
  
  -- Check for optional enhanced tools on macOS
  if os_name == "Darwin" and optional_tool then
    if vim.fn.executable(optional_tool) == 1 then
      H.ok(string.format("Enhanced notification tool '%s' is available", optional_tool))
    else
      H.info(
        string.format("Optional: Install '%s' for better notifications", optional_tool),
        "brew install terminal-notifier"
      )
    end
  end
  
  -- Show configuration status
  H.info(string.format("Notify on complete: %s", Config.notifications.notify_on_complete and "enabled" or "disabled"))
  H.info(string.format("Notify on error: %s", Config.notifications.notify_on_error and "enabled" or "disabled"))
  H.info(string.format("Notify on cancel: %s", Config.notifications.notify_on_cancel and "enabled" or "disabled"))
end

return M