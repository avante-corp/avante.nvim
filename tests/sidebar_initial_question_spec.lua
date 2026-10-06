local Config = require("avante.config")
local Sidebar = require("avante.sidebar")

describe("Sidebar initial question", function()
  local original_options
  before_each(function()
    original_options = Config._options
    Config.setup({})
  end)
  after_each(function() Config._options = original_options end)

  it("keeps a submitted question when the deferred zen layout renders", function()
    local sidebar = setmetatable({
      id = vim.api.nvim_get_current_tabpage(),
      containers = {},
      code = {},
      chat_history = { messages = {} },
    }, { __index = Sidebar })
    for _, method in ipairs({
      "create_input_container",
      "create_selected_files_container",
      "create_selected_code_container",
      "create_todos_container",
      "on_mount",
      "setup_colors",
    }) do
      sidebar[method] = function() end
    end
    function sidebar:get_result_container_width() return 30 end
    function sidebar:get_result_container_height() return 10 end
    function sidebar:reload_chat_history() self.chat_history = { messages = {} } end
    function sidebar:update_content()
      vim.bo[self.containers.result.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.containers.result.bufnr, 0, -1, false, self.chat_history.messages)
      vim.bo[self.containers.result.bufnr].modifiable = false
    end

    local rendered = false
    sidebar:render({
      win = { position = "right" },
      sidebar_post_render = function() rendered = true end,
    })
    sidebar.chat_history.messages = { "hello world" }
    sidebar:update_content("")
    local completed = vim.wait(500, function() return rendered end)
    local lines = vim.api.nvim_buf_get_lines(sidebar.containers.result.bufnr, 0, -1, false)
    vim.api.nvim_del_augroup_by_id(sidebar.augroup)
    sidebar.containers.result:unmount()

    assert.is_true(completed)
    assert.same({ "hello world" }, lines)
  end)

  for _, question in ipairs({ "hello world", "" }) do
    it("only preconnects ACP when the initial question is empty: " .. vim.inspect(question), function()
      local original_login = vim.g.avante_login
      Config.override({ acp_providers = { [Config.provider] = {} } })
      vim.g.avante_login = true
      local requests = {}
      local sidebar = setmetatable({ code = {} }, { __index = Sidebar })
      function sidebar:is_open() return true end
      function sidebar:focus() end
      function sidebar:handle_submit(request) table.insert(requests, request) end
      sidebar:open({ question = question })
      vim.g.avante_login = original_login
      assert.same(question == "" and { "" } or {}, requests)
    end)
  end
end)
