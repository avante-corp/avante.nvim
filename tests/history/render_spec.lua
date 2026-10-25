local Message = require("avante.history.message")
local Render = require("avante.history.render")

describe("Reasoning history rendering", function()
  for _, text in ipairs({ "", " \n\t " }) do
    it("hides reasoning without readable text while retaining native metadata", function()
      local message = Message:new("assistant", { type = "thinking", thinking = text })
      message.message.native = '{"item":{"type":"reasoning","encrypted_content":"cipher","summary":[]}}'
      local before = vim.deepcopy(message)

      assert.same({}, Render.message_to_lines(message, { message }))
      assert.same("", Render.message_to_text(message, { message }))
      assert.same(before, message)
    end)
  end

  it("shows readable reasoning summaries", function()
    local message = Message:new("assistant", { type = "thinking", thinking = "\nCheck the covariance.\n" })
    local text = Render.message_to_text(message, { message })

    assert.matches("Thought content:", text, nil, true)
    assert.matches("> Check the covariance.", text, nil, true)
  end)

  it("does not show opaque redacted reasoning", function()
    local message = Message:new("assistant", { type = "redacted_thinking", data = "Y2lwaGVy" })
    assert.same("", Render.message_to_text(message, { message }))
    assert.same("Y2lwaGVy", message.message.content[1].data)
  end)
end)
