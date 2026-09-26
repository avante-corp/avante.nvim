local Config = require("avante.config")
local Path = require("avante.path")

describe("thread title color persistence", function()
  local storage_path
  local original_options
  local original_storage_path
  local original_title_colors

  before_each(function()
    storage_path = vim.fn.tempname()
    vim.fn.mkdir(storage_path, "p")
    original_options = Config._options
    Config._options = vim.deepcopy(Config._defaults)
    original_storage_path = Config.history.storage_path
    original_title_colors = Config.windows.sidebar_header.title_colors
    Config.history.storage_path = storage_path
    Config.windows.sidebar_header.title_colors = { "#111111", "#222222" }
  end)

  after_each(function()
    Config.history.storage_path = original_storage_path
    Config.windows.sidebar_header.title_colors = original_title_colors
    Config._options = original_options
    vim.fn.delete(storage_path, "rf")
  end)

  it("stores a round-robin color index in each new history", function()
    local first = Path.history.new(0)
    local second = Path.history.new(0)
    local third = Path.history.new(0)

    assert.equals(1, first.title_color_index)
    assert.equals(2, second.title_color_index)
    assert.equals(1, third.title_color_index)

    local saved = vim.json.decode(Path.history.get_filepath(0, second.filename):read())
    assert.equals(2, saved.title_color_index)
  end)
end)
