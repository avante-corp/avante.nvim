local Config = require("avante.config")
local Utils = require("avante.utils")
local ACPClient = require("avante.libs.acp_client")

---@class avante.ACPConfigSelector
local M = {}

---@param category string "model" | "mode"
---@param prompt_label string
function M.open(category, prompt_label)
  if not Config.acp_providers[Config.provider] then
    Utils.warn("Current provider is not an ACP provider")
    return
  end

  local sidebar = require("avante").get(false)
  if not sidebar then
    Utils.warn("Please open the Avante sidebar first")
    return
  end
  if sidebar.is_generating then
    Utils.warn("Cannot switch ACP configuration during generation")
    return
  end

  local provider = Config.provider
  local provider_config = vim.deepcopy(Config.acp_providers[provider])
  local tab = vim.api.nvim_get_current_tabpage()
  local history = sidebar.chat_history
  local generation = sidebar.acp_client_generation
  local function is_current()
    return vim.api.nvim_get_current_tabpage() == tab
      and require("avante").get(false) == sidebar
      and Config.provider == provider
      and vim.deep_equal(Config.acp_providers[provider], provider_config)
      and sidebar.chat_history == history
      and sidebar.acp_client_generation == generation
  end
  local function has_options()
    local client = sidebar.acp_client
    return client and ACPClient.is_same_process_config(client.config, provider_config) and client.config_options ~= nil
  end

  local function show_selector()
    if not is_current() then return end
    local client = sidebar.acp_client
    if not client or not client.config_options or not has_options() then
      Utils.warn("No ACP config options available for " .. provider)
      return
    end
    local session_id = history and history.acp_session_id
    if not history or not session_id then
      Utils.warn("ACP session is not initialized yet")
      return
    end
    local function is_current_selection()
      return is_current() and has_options() and sidebar.acp_client == client and history.acp_session_id == session_id
    end

    local items = {}
    local display = {}
    for _, opt in ipairs(client.config_options) do
      if opt.category == category and opt.options then
        for _, val in ipairs(opt.options) do
          local prefix = val.value == opt.currentValue and "* " or "  "
          local label = prefix .. val.name
          if val.description then label = label .. " - " .. val.description end
          table.insert(display, label)
          table.insert(items, { config_id = opt.id, value = val.value })
        end
      end
    end

    if #items == 0 then
      Utils.warn("No " .. category .. " options available from " .. (Config.provider or "current") .. " ACP agent")
      return
    end

    vim.ui.select(display, { prompt = prompt_label }, function(_, idx)
      if not idx or not is_current_selection() then return end
      if sidebar.is_generating then
        Utils.warn("Cannot switch ACP configuration during generation")
        return
      end

      local choice = items[idx]
      if not choice then return end

      client:set_session_option(session_id, choice.config_id, choice.value, function(_, err)
        vim.schedule(function()
          if not is_current_selection() then return end
          if err then
            Utils.error("Failed: " .. (err.message or ""))
            return
          end
          Utils.info("ACP " .. category .. " updated")
          if sidebar:is_open() then sidebar:render_result() end
        end)
      end)
    end)
  end

  if has_options() then
    show_selector()
    return
  end

  sidebar:handle_submit("")

  local attempts = 0
  local timer = vim.uv.new_timer()
  if timer then
    timer:start(
      200,
      200,
      vim.schedule_wrap(function()
        attempts = attempts + 1
        if not is_current() then
          timer:stop()
          timer:close()
        elseif has_options() then
          timer:stop()
          timer:close()
          show_selector()
        elseif
          sidebar.acp_client
          and ACPClient.is_same_process_config(sidebar.acp_client.config, provider_config)
          and sidebar.acp_client:is_ready()
          and sidebar.chat_history
          and sidebar.chat_history.acp_session_id
          and not sidebar.acp_client.config_options
        then
          timer:stop()
          timer:close()
          Utils.warn("No " .. category .. " options available from " .. (Config.provider or "current") .. " ACP agent")
        elseif attempts > 50 then
          timer:stop()
          timer:close()
          Utils.warn("Timed out waiting for ACP session to initialize")
        end
      end)
    )
  end
end

function M.open_model() M.open("model", "ACP Agent Models> ") end

function M.open_mode() M.open("mode", "ACP Agent Modes> ") end

return M
