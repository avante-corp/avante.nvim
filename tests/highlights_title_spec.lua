local Config = require("avante.config")
local Highlights = require("avante.highlights")

describe("session title highlights", function()
  local original_options

  before_each(function()
    original_options = Config._options
    Config._options = vim.deepcopy(Config._defaults)
    Config.windows.sidebar_header.title_colors = { "#111111", "#222222" }
  end)

  after_each(function() Config._options = original_options end)

  it("selects and wraps configured title highlight pairs", function()
    assert.same({ "AvanteSessionTitle1", "AvanteReversedSessionTitle1" }, { Highlights.session_title(1) })
    assert.same({ "AvanteSessionTitle2", "AvanteReversedSessionTitle2" }, { Highlights.session_title(2) })
    assert.same({ "AvanteSessionTitle1", "AvanteReversedSessionTitle1" }, { Highlights.session_title(3) })
  end)
end)
