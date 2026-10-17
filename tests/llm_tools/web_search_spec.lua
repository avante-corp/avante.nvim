local stub = require("luassert.stub")
local Config = require("avante.config")
local Utils = require("avante.utils")
local WebSearch = require("avante.llm_tools.web_search")

describe("web_search_firecrawl", function()
  it("posts the query and maps results to title, url and snippet", function()
    Config.setup()
    local parse = stub(Utils.environment, "parse", function() return "test-key" end)
    local request = stub(
      vim.net,
      "request",
      function(_, _, _, on_response)
        on_response(nil, {
          body = vim.json.encode({
            success = true,
            data = { web = { { url = "https://neovim.io/", title = "Neovim", description = "Vim-based editor" } } },
          }),
        })
      end
    )

    local result
    WebSearch.web_search_firecrawl.func({ query = "neovim" }, { on_complete = function(r) result = r end })

    local method, url, opts = unpack(request.calls[1].refs)
    local body = vim.json.decode(opts.body)
    parse:revert()
    request:revert()
    assert.is_true(vim.wait(1000, function() return result ~= nil end), "web search did not complete")
    assert.equals("POST", method)
    assert.equals("https://api.firecrawl.dev/v2/search", url)
    assert.equals("Bearer test-key", opts.headers["Authorization"])
    assert.are.same({ query = "neovim", limit = 10, sources = { "web" }, origin = "avante" }, body)
    assert.are.same(
      { { title = "Neovim", url = "https://neovim.io/", snippet = "Vim-based editor" } },
      vim.json.decode(result)
    )
  end)
end)

describe("web_search_serply", function()
  it("gets the query and maps results to title, url and snippet", function()
    Config.setup()
    local parse = stub(Utils.environment, "parse", function() return "test-key" end)
    local request = stub(
      vim.net,
      "request",
      function(_, _, _, on_response)
        on_response(nil, {
          body = vim.json.encode({
            results = {
              { link = "https://neovim.io/", title = "Neovim", description = "Vim-based editor" },
              { link = "CAESAg", title = "Not a page", description = "dropped" },
            },
          }),
        })
      end
    )

    local result
    WebSearch.web_search_serply.func({ query = "neovim editor" }, { on_complete = function(r) result = r end })

    local method, url, opts = unpack(request.calls[1].refs)
    parse:revert()
    request:revert()
    assert.is_true(vim.wait(1000, function() return result ~= nil end), "web search did not complete")
    assert.equals("GET", method)
    assert.equals("https://api.serply.io/v1/search", url:match("^[^?]+"))
    assert.is_truthy(url:find("q=neovim%20editor&", 1, true))
    assert.is_truthy(url:find("num=10&", 1, true))
    assert.equals("test-key", opts.headers["X-Api-Key"])
    assert.equals("avante", opts.headers["User-Agent"])
    assert.are.same(
      { { title = "Neovim", url = "https://neovim.io/", snippet = "Vim-based editor" } },
      vim.json.decode(result)
    )
  end)
end)
