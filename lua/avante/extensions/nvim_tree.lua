local Api = require("avante.api")

---@class avante.extensions.nvim_tree
local M = {}

--- Adds the currently selected file in NvimTree to the selection via Api.add_selected_file.
-- Notifies the user if not invoked within NvimTree or if errors occur.
function M.add_file()
  if vim.bo.filetype ~= "NvimTree" then
    vim.notify("This action can only be used inside NvimTree.", vim.log.levels.WARN)
    return
  end

  local ok, nvim_tree_api = pcall(require, "nvim-tree.api")
  if not ok then
    vim.notify("nvim-tree needed", vim.log.levels.ERROR)
    return
  end

  local success, node = pcall(function() return nvim_tree_api.tree.get_node_under_cursor() end)
  if not success then
    vim.notify("Error getting node: " .. tostring(node), vim.log.levels.ERROR)
    return
  end

  local filepath = node.absolute_path
  Api.add_selected_file(filepath)
end

--- Removes the currently selected file in NvimTree from the selection via Api.remove_selected_file.
-- Notifies the user if not invoked within NvimTree or if errors occur.
function M.remove_file()
  if vim.bo.filetype ~= "NvimTree" then
    vim.notify("This action can only be used inside NvimTree.", vim.log.levels.WARN)
    return
  end

  local ok, nvim_tree_api = pcall(require, "nvim-tree.api")
  if not ok then
    vim.notify("nvim-tree needed", vim.log.levels.ERROR)
    return
  end

  local success, node = pcall(function() return nvim_tree_api.tree.get_node_under_cursor() end)
  if not success then
    vim.notify("Error getting node: " .. tostring(node), vim.log.levels.ERROR)
    return
  end

  local filepath = node.absolute_path
  Api.remove_selected_file(filepath)
end

return M
