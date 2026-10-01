local M = {}

---@type AvanteLLMTool
M.add_file_to_context = {
  name = "add_file_to_context",
  description = "Add a file to the context",
  ---@type AvanteLLMToolFunc<{ rel_path: string }>
  func = function(input)
    local sidebar = require("avante").get()
    if not sidebar then return nil, "Avante sidebar not found" end
    sidebar.file_selector:add_selected_file(input.rel_path)
    return "Added file to context", nil
  end,
  param = {
    type = "table",
    fields = { { name = "rel_path", description = "Relative path to the file", type = "string" } },
  },
  returns = {},
}

---@type AvanteLLMTool
M.remove_file_from_context = {
  name = "remove_file_from_context",
  description = "Remove a file from the context",
  ---@type AvanteLLMToolFunc<{ rel_path: string }>
  func = function(input)
    local sidebar = require("avante").get()
    if not sidebar then return nil, "Avante sidebar not found" end
    sidebar.file_selector:remove_selected_file(input.rel_path)
    return "Removed file from context", nil
  end,
  param = {
    type = "table",
    fields = { { name = "rel_path", description = "Relative path to the file", type = "string" } },
  },
  returns = {},
}

return M
