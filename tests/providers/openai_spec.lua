describe("OpenAI subscription model selection", function()
  it("uses Rig's ChatGPT catalog without an API key or HTTP request", function()
    local RigClient = require("avante.libs.rig_client")
    local models = { { id = "gpt-6.1-sol", name = "gpt-6.1-sol" } }
    local list = stub(RigClient, "chatgpt_models").returns(models)
    local result = require("avante.providers.openai").list_models({
      auth_type = "subscription",
      _model_list_cache = { { id = "stale-api-model" } },
      parse_api_key = function() error("must not read an API key") end,
    })
    list:revert()
    assert.same(models, result)
    assert.stub(list).was_called(1)
  end)
end)
