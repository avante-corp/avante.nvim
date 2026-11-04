local Utils = require("avante.utils")
local M = {}

---@param selector avante.ui.Selector
function M.show(selector)
  local success, fzf_lua = pcall(require, "fzf-lua")
  if not success then
    Utils.error("fzf-lua is not installed. Please install fzf-lua to use it as a file selector.")
    return
  end

  local title_to_id = {}
  for _, item in ipairs(selector.items) do
    title_to_id[item.title] = item.id
  end

  local function close_action() selector.on_select(nil) end
  fzf_lua.fzf_live(
    function(args)
      local query = args[1] or ""
      local items = {}
      for _, item in ipairs(vim.iter(selector.items):map(function(item) return item.title end):totable()) do
        if query == "" or item:match(query:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")) then
          table.insert(items, item)
        end
      end
      return items
    end,
    vim.tbl_deep_extend("force", {
      prompt = selector.title,
      query = selector.default_query,
      preview = selector.get_preview_content and function(item)
        local id = title_to_id[item[1]]
        local content = selector.get_preview_content(id)
        return content
      end or nil,
      fzf_opts = { ["--multi"] = true },
      git_icons = false,
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then return close_action() end
          ---@type string[]
          local selections = {}
          for _, entry in ipairs(selected) do
            local id = title_to_id[entry]
            if id then table.insert(selections, id) end
          end

          selector.on_select(selections)
        end,
        ["esc"] = close_action,
        ["ctrl-c"] = close_action,
        ["ctrl-delete"] = {
          fn = function(selected)
            if not selected or #selected == 0 then return close_action() end
            local selections = selected
            vim.ui.input({ prompt = "Remove·selection?·(" .. #selections .. " items) [y/N]" }, function(input)
              if input and input:lower() == "y" then
                for _, selection in ipairs(selections) do
                  selector.on_delete_item(title_to_id[selection])
                  for i, item in ipairs(selector.items) do
                    if item.id == title_to_id[selection] then table.remove(selector.items, i) end
                  end
                end
              end
            end)
          end,
          reload = true,
        },
      },
    }, selector.provider_opts)
  )
end

return M
