local Utils = require("avante.utils")
local M = {}

---@param selector avante.ui.Selector
function M.show(selector)
  ---@diagnostic disable-next-line: undefined-field
  if not _G.Snacks then
    Utils.error("Snacks is not set up. Please install and set up Snacks to use it as a file selector.")
    return
  end
  local function snacks_finder(opts, ctx)
    local query = ctx.filter.search or ""
    local items = {}
    for i, item in ipairs(selector.items) do
      if not vim.list_contains(selector.selected_item_ids, item.id) then
        if query == "" or item.title:match(query:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")) then
          table.insert(items, {
            formatted = item.title,
            text = item.title,
            item = item,
            idx = i,
            preview = selector.get_preview_content and (function()
              local content, filetype = selector.get_preview_content(item.id)
              return {
                text = content,
                ft = filetype,
              }
            end)() or nil,
          })
        end
      end
    end
    return items
  end

  local completed = false

  ---@diagnostic disable-next-line: undefined-global
  Snacks.picker.pick(vim.tbl_deep_extend("force", {
    source = "select",
    live = true,
    search = selector.default_query,
    finder = snacks_finder,
    ---@diagnostic disable-next-line: undefined-global
    format = Snacks.picker.format.ui_select({ format_item = function(item, _) return item.title end }),
    title = selector.title,
    preview = selector.get_preview_content and "preview" or nil,
    layout = {
      preset = "default",
    },
    confirm = function(picker)
      if completed then return end
      completed = true
      picker:close()
      local items = picker:selected({ fallback = true })
      local selected_item_ids = vim.tbl_map(function(item) return item.item.id end, items)
      selector.on_select(selected_item_ids)
    end,
    on_close = function()
      if completed then return end
      completed = true
      vim.schedule(function() selector.on_select(nil) end)
    end,
    actions = {
      delete_selection = function(picker)
        local selections = picker:selected({ fallback = true })
        if #selections == 0 then return end
        vim.ui.input({ prompt = "Remove·selection?·(" .. #selections .. " items) [y/N]" }, function(input)
          if input and input:lower() == "y" then
            for _, selection in ipairs(selections) do
              selector.on_delete_item(selection.item.id)
              for i, item in ipairs(selector.items) do
                if item.id == selection.item.id then table.remove(selector.items, i) end
              end
            end
            picker:refresh()
          end
        end)
      end,
    },

    win = {
      input = {
        keys = {
          ["<C-DEL>"] = { "delete_selection", mode = { "i", "n" } },
        },
      },
    },
  }, selector.provider_opts))
end

return M
