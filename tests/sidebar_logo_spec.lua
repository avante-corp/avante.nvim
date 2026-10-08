local Sidebar = require("avante.sidebar")

describe("Sidebar logo", function()
  it("renders before a narrow sidebar expands into zen mode", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 10,
      style = "minimal",
    })
    local sidebar = setmetatable({ containers = { result = { bufnr = bufnr, winid = winid } } }, { __index = Sidebar })

    local ok, line_count = pcall(sidebar.render_logo, sidebar)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_win_close(winid, true)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_true(ok, tostring(line_count))
    assert.equals(#vim.split(require("avante.utils.logo"), "\n"), line_count)
    assert.same(vim.tbl_map(vim.trim, vim.split(require("avante.utils.logo"), "\n")), lines)
  end)
end)
