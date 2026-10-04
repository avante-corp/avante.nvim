local M = {}

---@param selector avante.ui.Selector
function M.show(selector)
  local items = {}
  for _, item in ipairs(selector.items) do
    if not vim.list_contains(selector.selected_item_ids, item.id) then table.insert(items, item) end
  end
  vim.ui.select(
    items,
    vim.tbl_deep_extend("force", {
      prompt = selector.title,
      format_item = function(item)
        local title = item.title
        if item.id == selector.default_item_id then title = "● " .. title end
        return title
      end,
    }, selector.provider_opts),
    function(item)
      if not item then
        selector.on_select(nil)
        return
      end

      -- If on_delete_item callback is provided, prompt for action
      if type(selector.on_delete_item) == "function" then
        vim.ui.input(
          { prompt = "Action for '" .. item.title .. "': (o)pen, (d)elete, (c)ancel?", default = "" },
          function(input)
            if not input then -- User cancelled input
              selector.on_select(nil) -- Treat as cancellation of selection
              return
            end
            local choice = input:lower()
            if choice == "d" or choice == "delete" then
              selector.on_delete_item(item.id)
              -- The native provider handles the UI flow; we just need to refresh.
              selector.on_open() -- Re-open the selector to refresh the list
            elseif choice == "" or choice == "o" or choice == "open" then
              selector.on_select({ item.id })
            elseif choice == "c" or choice == "cancel" then
              if type(selector.on_open) == "function" then
                selector.on_open()
              else
                selector.on_select(nil) -- Fallback if on_open is not defined
              end
            else -- c or any other input, treat as cancel
              selector.on_select(nil) -- Fallback if on_open is not defined
            end
          end
        )
      else
        -- Default behavior: directly select the item
        selector.on_select({ item.id })
      end
    end
  )
end

return M
