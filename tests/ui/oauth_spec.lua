local ui = require("avante.ui.oauth")

describe("OAuth URL fallback", function()
  it("makes the URL available and runs manual login when no UI is attached", function()
    local original_notify, original_setreg = vim.notify, vim.fn.setreg
    local copied, context
    vim.notify = function() end
    vim.fn.setreg = function(_, value) copied = value end
    local ok, result = pcall(ui.show_auth_url, {
      provider_name = "Claude",
      auth_url = "https://example.com/authorize",
      on_copy = function(ctx) context = ctx end,
    })
    vim.notify, vim.fn.setreg = original_notify, original_setreg
    assert.is_true(ok)
    assert.is_false(result)
    assert.equals("https://example.com/authorize", copied)
    assert.equals("Claude", context.provider_name)
    assert.equals(copied, context.auth_url)
  end)
end)
