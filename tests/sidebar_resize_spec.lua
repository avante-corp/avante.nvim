local Config = require("avante.config")
local Sidebar = require("avante.sidebar")

-- Config fields are only populated by setup(); mirror tests/config_spec.lua.
Config.get_last_used_model = function() end
Config.setup({ provider = "claude" })
-- normally defined during avante's setup(); needed by Sidebar:place_sign_at_first_line
vim.fn.sign_define("AvanteInputPromptSign", { text = Config.windows.input.prefix })

-- Regression tests for https://github.com/avante-corp/avante.nvim/issues/3298
--
-- Resizing the editor while the cursor sits inside the sidebar used to leave
-- the sidebar broken: extra windows bound to the same container buffer (two
-- "Ask" panels, a duplicated conversation) and redistributed container heights.
-- The trigger was another plugin's VimResized handler rebalancing splits
-- (LazyVim runs `tabdo wincmd =`), combined with avante's repair step being
-- skipped whenever focus happened to be inside the sidebar.

describe("Sidebar resize", function()
  ---@type avante.Sidebar, integer, table<string, integer>
  local sidebar, code_win, baseline

  ---@return table<string, integer[]> ft -> window ids of avante containers
  local function avante_windows()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
        if ft:match("^Avante") then
          wins[ft] = wins[ft] or {}
          table.insert(wins[ft], win)
        end
      end
    end
    return wins
  end

  ---@return string[] filetypes that occupy more than one window
  local function duplicated_filetypes()
    local dups = {}
    for ft, wins in pairs(avante_windows()) do
      if #wins > 1 then table.insert(dups, ft) end
    end
    table.sort(dups)
    return dups
  end

  ---@param name string container name
  ---@return integer[] window ids currently showing that container's buffer
  local function windows_showing(name)
    local container = sidebar and sidebar.containers[name]
    if not container or not vim.api.nvim_buf_is_valid(container.bufnr) then return {} end
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == container.bufnr then
        table.insert(wins, win)
      end
    end
    return wins
  end

  local function height(name)
    local container = sidebar and sidebar.containers[name]
    if not container or not vim.api.nvim_win_is_valid(container.winid) then return nil end
    return vim.api.nvim_win_get_height(container.winid)
  end

  local original_cmd = vim.cmd

  before_each(function()
    -- `:AvanteRefresh` comes from plugin/avante.lua, which nlua does not
    -- source; swallow it so the deferred refresh inside resize() cannot mask
    -- the assertions below with E492 noise.
    vim.cmd = function(cmd)
      if tostring(cmd):match("AvanteRefresh") then return end
      return original_cmd(cmd)
    end

    Config.override({ windows = { position = "right" } })

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local a = 1", "print(a)" })
    code_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(bufnr)

    sidebar = Sidebar:new(vim.api.nvim_get_current_tabpage())
    sidebar.code.winid = code_win
    sidebar.code.bufnr = bufnr
    sidebar:reset()
    sidebar:render({})

    baseline = { input = height("input"), result = height("result") }
  end)

  after_each(function()
    vim.cmd = original_cmd
    pcall(function() sidebar:close() end)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
  end)

  it("opens exactly one window per container", function()
    assert.is_true(sidebar:is_open())
    assert.are.same({}, duplicated_filetypes())
  end)

  it("repairs a container buffer displayed by several windows", function()
    -- The state an external `wincmd =` rebalance leaves behind: a second window
    -- bound to the same container buffer, i.e. a visibly duplicated "Ask" panel.
    vim.fn.win_execute(sidebar.containers.input.winid, "split")
    assert.are.equal(2, #windows_showing("input"), "precondition: duplicated input window")

    vim.api.nvim_set_current_win(sidebar.containers.input.winid)
    sidebar:resize()
    vim.wait(800, function() return #windows_showing("input") == 1 end)

    assert.are.same({}, duplicated_filetypes())
    assert.are.equal(1, #windows_showing("input"))
  end)

  it("restores container heights when the cursor is inside the sidebar", function()
    -- resize() only used to re-apply widths, so redistributed heights stuck.
    vim.api.nvim_win_set_height(sidebar.containers.input.winid, 2)
    assert.are.equal(2, height("input"), "precondition: input height was redistributed")

    vim.api.nvim_set_current_win(sidebar.containers.input.winid)
    sidebar:resize()
    vim.wait(800, function() return height("input") == baseline.input end)

    -- the geometry avante built at render time is what a resize must return to
    assert.are.equal(baseline.input, height("input"))
    assert.are.equal(baseline.input, sidebar:get_container_geometry("input").height)
  end)

  it("survives repeated resizes without losing the draft or duplicating panels", function()
    vim.api.nvim_buf_set_lines(sidebar.containers.input.bufnr, 0, -1, false, { "draft before first" })

    for round = 1, 3 do
      vim.fn.win_execute(sidebar.containers.input.winid, "split")
      vim.api.nvim_win_set_height(sidebar.containers.input.winid, 2)
      vim.api.nvim_set_current_win(sidebar.containers.input.winid)
      sidebar:resize()
      vim.wait(900, function() return #windows_showing("input") == 1 and height("input") == baseline.input end)

      assert.are.same({}, duplicated_filetypes(), "round " .. round)
      local draft = table.concat(vim.api.nvim_buf_get_lines(sidebar.containers.input.bufnr, 0, -1, false), "\n")
      assert.are.equal("draft before first", draft, "round " .. round)
    end

    assert.are.equal(baseline.input, height("input"))
  end)

  it("keeps an unsent draft while repairing the layout", function()
    vim.api.nvim_buf_set_lines(sidebar.containers.input.bufnr, 0, -1, false, { "my unsent draft" })
    vim.fn.win_execute(sidebar.containers.input.winid, "split")

    vim.api.nvim_set_current_win(sidebar.containers.input.winid)
    sidebar:resize()
    vim.wait(800, function() return #windows_showing("input") == 1 end)

    assert.are.equal(1, #windows_showing("input"))
    local draft = table.concat(vim.api.nvim_buf_get_lines(sidebar.containers.input.bufnr, 0, -1, false), "\n")
    assert.are.equal("my unsent draft", draft)
  end)

  it("does not resurrect a draft the user deleted", function()
    vim.api.nvim_buf_set_lines(sidebar.containers.input.bufnr, 0, -1, false, { "typo" })
    vim.fn.win_execute(sidebar.containers.input.winid, "split")
    vim.api.nvim_set_current_win(sidebar.containers.input.winid)
    sidebar:resize()
    vim.wait(800, function() return #windows_showing("input") == 1 end) -- rebuild restores "typo"

    vim.api.nvim_buf_set_lines(sidebar.containers.input.bufnr, 0, -1, false, {})

    vim.fn.win_execute(sidebar.containers.input.winid, "split")
    vim.api.nvim_set_current_win(sidebar.containers.input.winid)
    sidebar:resize()
    vim.wait(800, function() return #windows_showing("input") == 1 end)

    assert.are.same({}, duplicated_filetypes())
    -- the input is back to empty (nvim keeps a single blank line in an empty buffer)
    local text = table.concat(vim.api.nvim_buf_get_lines(sidebar.containers.input.bufnr, 0, -1, false), "\n")
    assert.are.equal("", text)
  end)

  it("does not force sidebar widths in horizontal layout", function()
    Config.override({ windows = { position = "bottom" } })
    local input_win = sidebar.containers.input.winid
    local input_width = vim.api.nvim_win_get_width(input_win)

    sidebar:resize()
    vim.wait(800)

    assert.is_true(vim.api.nvim_win_is_valid(input_win))
    assert.are.equal(input_width, vim.api.nvim_win_get_width(input_win))
    assert.are.same({}, duplicated_filetypes())
  end)

  it("leaks no sidebar windows when closed after a resize storm", function()
    for _, columns in ipairs({ 132, 96, 120 }) do
      vim.o.columns = columns
      vim.cmd("doautocmd VimResized")
      vim.wait(600, function() return false end)
    end

    sidebar:close()
    vim.wait(1500, function() return next(avante_windows()) == nil end)

    assert.are.same({}, avante_windows())
    assert.is_false(sidebar:is_open())
  end)
end)
