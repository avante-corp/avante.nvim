local stub = require("luassert.stub")
local Api = require("avante.api")
local NvimTree = require("avante.extensions.nvim_tree")

describe("NvimTree selection", function()
  local previous_api
  local previous_filetype
  local get_node
  local add_file
  local remove_file
  local notify

  before_each(function()
    previous_api = package.loaded["nvim-tree.api"]
    previous_filetype = vim.bo.filetype
    vim.bo.filetype = "NvimTree"
    local tree = { get_node_under_cursor = function() end }
    package.loaded["nvim-tree.api"] = { tree = tree }
    get_node = stub(tree, "get_node_under_cursor")
    add_file = stub(Api, "add_selected_file")
    remove_file = stub(Api, "remove_selected_file")
    notify = stub(vim, "notify")
  end)

  after_each(function()
    get_node:revert()
    add_file:revert()
    remove_file:revert()
    notify:revert()
    package.loaded["nvim-tree.api"] = previous_api
    vim.bo.filetype = previous_filetype
  end)

  for _, method in ipairs({ "add_file", "remove_file" }) do
    it(method .. " ignores a missing node", function()
      assert.has_no.errors(NvimTree[method])
      assert.stub(add_file).was_not_called()
      assert.stub(remove_file).was_not_called()
    end)

    it(method .. " uses the current node's path", function()
      get_node.returns({ absolute_path = "/tmp/file.lua" })
      NvimTree[method]()
      assert.stub(method == "add_file" and add_file or remove_file).was_called_with("/tmp/file.lua")
    end)

    it(method .. " reports lookup errors", function()
      get_node.invokes(function() error("lookup failed") end)
      assert.has_no.errors(NvimTree[method])
      assert.stub(notify).was_called(1)
      assert.stub(add_file).was_not_called()
      assert.stub(remove_file).was_not_called()
    end)
  end
end)
