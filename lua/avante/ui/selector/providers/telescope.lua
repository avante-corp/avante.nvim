local Utils = require("avante.utils")

local M = {}

---@param selector avante.ui.Selector
function M.show(selector)
  local success, _ = pcall(require, "telescope")
  if not success then
    Utils.error("telescope is not installed. Please install telescope to use it as a file selector.")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local items = {}
  for _, item in ipairs(selector.items) do
    if not vim.list_contains(selector.selected_item_ids, item.id) then table.insert(items, item) end
  end

  pickers
    .new(
      {},
      vim.tbl_extend("force", {
        prompt_title = selector.title,
        default_text = selector.default_query,
        finder = finders.new_table({
          results = items,
          entry_maker = function(entry)
            return {
              value = entry.id,
              display = entry.title,
              ordinal = entry.title,
            }
          end,
        }),
        sorter = conf.file_sorter(),
        previewer = selector.get_preview_content and previewers.new_buffer_previewer({
          title = "Preview",
          define_preview = function(self, entry)
            if not entry then return end
            local content, filetype = selector.get_preview_content(entry.value)
            local lines = vim.split(content or "", "\n")
            -- Ensure the buffer exists and is valid before setting lines
            if vim.api.nvim_buf_is_valid(self.state.bufnr) then
              vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
              -- Set filetype after content is loaded
              vim.api.nvim_set_option_value("filetype", filetype, { buf = self.state.bufnr })
              -- Ensure cursor is within bounds
              vim.schedule(function()
                if vim.api.nvim_buf_is_valid(self.state.bufnr) then
                  local row = math.min(vim.api.nvim_buf_line_count(self.state.bufnr), 1)
                  pcall(vim.api.nvim_win_set_cursor, self.state.winnr, { row, 0 })
                end
              end)
            end
          end,
        }),
        attach_mappings = function(prompt_bufnr, map)
          map("i", "<esc>", require("telescope.actions").close)
          map("i", "<c-del>", function()
            local picker = action_state.get_current_picker(prompt_bufnr)

            local selections
            local multi_selection = picker:get_multi_selection()
            if #multi_selection ~= 0 then
              selections = multi_selection
            else
              selections = action_state.get_selected_entry()
              selections = vim.islist(selections) and selections or { selections }
            end

            local selected_item_ids = vim
              .iter(selections)
              :map(function(selection) return selection.value end)
              :totable()

            vim.ui.input({ prompt = "Remove·selection?·(" .. #selected_item_ids .. " items) [y/N]" }, function(input)
              if input and input:lower() == "y" then
                for _, item_id in ipairs(selected_item_ids) do
                  selector.on_delete_item(item_id)
                end

                local new_items = {}
                for _, item in ipairs(items) do
                  if not vim.list_contains(selected_item_ids, item.id) then table.insert(new_items, item) end
                end

                local new_finder = finders.new_table({
                  results = new_items,
                  entry_maker = function(entry)
                    return {
                      value = entry.id,
                      display = entry.title,
                      ordinal = entry.title,
                    }
                  end,
                })

                picker:refresh(new_finder, { reset_prompt = true })
              end
            end)
          end, { desc = "delete_selection" })
          actions.select_default:replace(function()
            local picker = action_state.get_current_picker(prompt_bufnr)

            local selections
            local multi_selection = picker:get_multi_selection()
            if #multi_selection ~= 0 then
              selections = multi_selection
            else
              selections = action_state.get_selected_entry()
              selections = vim.islist(selections) and selections or { selections }
            end

            local selected_item_ids = vim
              .iter(selections)
              :map(function(selection) return selection.value end)
              :totable()

            selector.on_select(selected_item_ids)

            pcall(actions.close, prompt_bufnr)
          end)
          return true
        end,
      }, selector.provider_opts)
    )
    :find()
end

return M
