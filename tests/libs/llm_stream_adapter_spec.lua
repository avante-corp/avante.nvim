local Adapter = require("avante.libs.llm_stream_adapter")

describe("LLM stream adapter", function()
  it("keeps provider-native reasoning data in Avante history", function()
    local added = {}
    local opts = { on_messages_add = function(items) added[#added + 1] = items[1] end }
    local part = { turn_id = "turn", content = { type = "thinking", thinking = "plan" } }
    Adapter.add_message(part, "generating", opts)
    part.native = '{"item":{"signature":"signed"},"fingerprint":"0123456789abcdef"}'
    part.order = 0
    local origin = { api = "anthropic.messages", provider = "anthropic", model = "test-model" }
    Adapter.finish_pending_messages({ part }, opts, true, origin)

    assert.same(part.native, added[2].message.native)
    assert.same(origin, added[2].message.origin)
    assert.same(added[1].uuid, added[2].uuid)
    assert.same("turn", added[2].turn_id)
    assert.same(0, added[2].order)
  end)
end)
