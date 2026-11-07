local Copilot = require("avante.providers.copilot")
local RigClient = require("avante.libs.rig_client")

describe("Copilot authentication through Rig", function()
  it("passes a private credential directory without reading plugin credentials", function()
    local input = RigClient._build_request(
      vim.tbl_extend("force", Copilot, {
        _name = "copilot",
        _protocol = "copilot",
        auth_type = "subscription",
        model = "gpt-6-luna",
        endpoint = "https://api.githubcopilot.com",
        get_session_token = function() error("must not read Lua tokens") end,
        parse_api_key = function() error("must not read API keys") end,
      }),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
    )
    assert.same("copilot", input.provider.auth)
    assert.same(vim.fn.stdpath("data") .. "/avante/copilot", input.provider.authHome)
    assert.is_nil(input.provider.apiKey)
  end)

  it("lists account models using the native authenticator", function()
    local models = { { id = "gpt-6-luna", policy = true } }
    local list = stub(RigClient, "copilot_models").returns(models)
    local result = Copilot:list_models(1500)
    list:revert()
    assert.same(models, result)
    assert.stub(list).was_called_with(1500)
  end)

  it("keeps requests responsive and cancellable while Rust resolves credentials", function()
    local saved = package.loaded.avante_llm
    local cancelled, stopped, native_input
    package.loaded.avante_llm = {
      start = function(input)
        native_input = input
        return {
          poll = function() return cancelled and { { type = "cancelled" } } or {} end,
          cancel = function() cancelled = true end,
        }
      end,
    }
    local request = RigClient.start({
      _name = "copilot",
      _protocol = "copilot",
      model = "gpt-6-luna",
      get_session_token = function() error("authentication belongs in Rust") end,
    }, { system_prompt = "system", messages = {} }, { on_stop = function(result) stopped = result end })
    local scheduled = false
    vim.schedule(function() scheduled = true end)
    assert.is_true(vim.wait(200, function() return scheduled end, 1))
    request:cancel()
    local finished = vim.wait(500, function() return stopped ~= nil end, 1)
    package.loaded.avante_llm = saved
    assert.is_true(finished)
    assert.same("copilot", native_input.provider.auth)
    assert.same("cancelled", stopped.reason)
  end)
end)
