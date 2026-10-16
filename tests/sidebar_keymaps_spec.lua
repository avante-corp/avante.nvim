local Config = require("avante.config")
local Sidebar = require("avante.sidebar")

describe("Sidebar keymaps", function()
  local sidebar

  before_each(function()
    -- token counting renders the prompt templates, which this test doesn't need
    Config.setup({ provider = "claude", behaviour = { enable_token_counting = false } })
    -- normally defined by avante's setup(), needed to render the input container
    vim.fn.sign_define("AvanteInputPromptSign", { text = Config.windows.input.prefix })
    sidebar = Sidebar:new(vim.api.nvim_get_current_tabpage())
    sidebar:open({})
  end)

  after_each(function()
    -- let the callbacks scheduled while rendering run before tearing down
    vim.wait(100)
    sidebar:close()
  end)

  it("focuses the input when pressing i in the result window", function()
    vim.api.nvim_set_current_win(sidebar.containers.result.winid)
    vim.api.nvim_feedkeys("i", "x", false)
    assert.are.equal(sidebar.containers.input.winid, vim.api.nvim_get_current_win())
  end)
end)
