local Config = require("avante.config")
local Utils = require("avante.utils")

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

  local function show_selector()
    local client = sidebar.acp_client
    if not client or not client.config_options then
      Utils.warn("No ACP config options available")
      return
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
      if not idx then return end
      if sidebar.is_generating then
        Utils.warn("Cannot switch ACP configuration during generation")
        return
      end

      local choice = items[idx]
      local session_id = sidebar.chat_history and sidebar.chat_history.acp_session_id
      if not session_id then
        Utils.warn("ACP session is not initialized yet")
        return
      end

      if client._legacy_api then
        if choice.config_id == "mode" then
          client:set_mode(session_id, choice.value, function(_, err)
            vim.schedule(function()
              if err then
                Utils.error("Failed: " .. (err.message or ""))
                return
              end
              Utils.info("ACP mode updated")
              if sidebar:is_open() then sidebar:render_result() end
            end)
          end)
        elseif choice.config_id == "model" then
          client:set_model(session_id, choice.value, function(_, err)
            vim.schedule(function()
              if err then
                Utils.warn("Model switching is not supported by this ACP agent")
                return
              end
              Utils.info("ACP model updated")
              if sidebar:is_open() then sidebar:render_result() end
            end)
          end)
        end
      else
        client:set_config_option(session_id, choice.config_id, choice.value, function(_, err)
          vim.schedule(function()
            if err then
              Utils.error("Failed: " .. (err.message or ""))
              return
            end
            Utils.info("ACP " .. category .. " updated")
            if sidebar:is_open() then sidebar:render_result() end
          end)
        end)
      end
    end)
  end

  if sidebar.acp_client and sidebar.acp_client.config_options then
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
        if sidebar.acp_client and sidebar.acp_client.config_options then
          timer:stop()
          timer:close()
          show_selector()
        elseif
          sidebar.acp_client
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
