local stub = require("luassert.stub")
local Config = require("avante.config")
local Avante = require("avante")
local Selector = require("avante.acp_config_selector")
local ACPClient = require("avante.libs.acp_client")

describe("ACP configuration selector ownership", function()
  local provider, providers, sidebars, original_tab, created_tab, select_stub, timer_stub, owner, client, select_choice, applied

  before_each(function()
    provider, providers = Config.provider, Config.acp_providers
    Config.provider = "test-acp"
    Config.acp_providers = { ["test-acp"] = { command = "/bin/true" }, other = { command = "/bin/false" } }
    original_tab = vim.api.nvim_get_current_tabpage()
    sidebars = vim.tbl_extend("force", {}, Avante.sidebars)
    select_choice, created_tab, timer_stub, applied = nil, nil, nil, {}
    client = {
      config = Config.acp_providers["test-acp"],
      is_ready = function() return true end,
      config_options = {
        { id = "model", category = "model", currentValue = "old", options = { { value = "new", name = "New" } } },
      },
      set_session_option = function(_, session, option, value) table.insert(applied, { session, option, value }) end,
    }
    owner = {
      code = { bufnr = vim.api.nvim_get_current_buf() },
      chat_history = { filename = "original.json", acp_session_id = "original-session" },
      acp_client = client,
      acp_client_generation = 0,
      is_generating = false,
    }
    Avante.sidebars[original_tab] = owner
    select_stub = stub(vim.ui, "select").invokes(function(_, _, callback) select_choice = callback end)
  end)

  after_each(function()
    select_stub:revert()
    if timer_stub then timer_stub:revert() end
    if created_tab and vim.api.nvim_tabpage_is_valid(created_tab) then
      vim.api.nvim_set_current_tabpage(created_tab)
      vim.cmd("noautocmd tabclose!")
    end
    vim.api.nvim_set_current_tabpage(original_tab)
    Avante.sidebars = sidebars
    Config.provider, Config.acp_providers = provider, providers
  end)

  it("applies a choice when its client and session are still current", function()
    Selector.open_model()
    select_choice(nil, 1)
    assert.same({ { "original-session", "model", "new" } }, applied)
  end)

  it("initializes the current provider instead of showing another provider's cached options", function()
    Config.provider = "other"
    local initialized, tick, closed = 0, nil, false
    owner.handle_submit = function(_, request)
      assert.equals("", request)
      initialized = initialized + 1
    end
    timer_stub = stub(vim.uv, "new_timer").returns({
      start = function(_, _, _, callback) tick = callback end,
      stop = function() end,
      close = function() closed = true end,
    })

    Selector.open_model()

    assert.equals(1, initialized)
    assert.is_nil(select_choice)
    assert.is_function(tick)
    tick()
    vim.wait(100, function() return select_choice ~= nil or closed end, 5)
    assert.is_nil(select_choice)
    assert.is_false(closed)

    owner.acp_client = vim.tbl_extend("force", {}, client, { config = Config.acp_providers.other })
    owner.chat_history.acp_session_id = "other-session"
    tick()
    assert.is_true(vim.wait(100, function() return select_choice ~= nil end, 5))
    select_choice(nil, 1)

    assert.is_true(closed)
    assert.same({ { "other-session", "model", "new" } }, applied)
  end)

  it("waits for a pending session load before deciding the agent has no model options", function()
    local options = client.config_options
    client = ACPClient:new({ command = "/bin/true", handlers = {} })
    client.state = "ready"
    client.native = { load_session = function() return { operationId = 1 } end }
    client:load_session("original-session", "/tmp", {}, function() end)
    owner.acp_client = client
    owner.handle_submit = function() end
    local tick, closed
    timer_stub = stub(vim.uv, "new_timer").returns({
      start = function(_, _, _, callback) tick = callback end,
      stop = function() end,
      close = function() closed = true end,
    })
    Selector.open_model()
    tick()
    local flushed = false
    vim.schedule(function() flushed = true end)
    assert.is_true(vim.wait(100, function() return flushed end, 5))
    assert.is_nil(select_choice)
    assert.is_not_true(closed)

    client:_handle_event({ type = "operation_completed", operationId = 1, result = { configOptions = options } })
    tick()
    assert.is_true(vim.wait(100, function() return select_choice ~= nil end, 5))
    assert.is_true(closed)
  end)

  for _, changed in ipairs({ "session", "chat", "client", "provider", "tab" }) do
    it("discards a model choice after its " .. changed .. " changes", function()
      Selector.open_model()
      assert.is_function(select_choice)
      if changed == "session" then
        owner.chat_history.acp_session_id = "different-session"
      elseif changed == "chat" then
        owner.chat_history = { filename = "different.json", acp_session_id = "original-session" }
      elseif changed == "client" then
        owner.acp_client = vim.tbl_extend("force", {}, client)
      elseif changed == "provider" then
        Config.provider = "other"
      else
        vim.cmd("noautocmd tabnew")
        created_tab = vim.api.nvim_get_current_tabpage()
      end

      select_choice(nil, 1)

      assert.same({}, applied)
    end)
  end
end)
