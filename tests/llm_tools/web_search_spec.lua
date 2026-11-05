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

describe("web_search_outcrawl", function()
  it("posts the query and maps hits to title, url and snippet", function()
    Config.setup()
    local parse = stub(Utils.environment, "parse", function() return "test-key" end)
    local request = stub(
      vim.net,
      "request",
      function(_, _, _, on_response)
        on_response(nil, {
          body = vim.json.encode({
            hits = { { url = "https://neovim.io/", title = "Neovim", snippet = "Vim-based editor", rank = 1 } },
            usage = { credits = "0.5" },
          }),
        })
      end
    )

    local result
    WebSearch.web_search_outcrawl.func({ query = "neovim" }, { on_complete = function(r) result = r end })

    local method, url, opts = unpack(request.calls[1].refs)
    local body = vim.json.decode(opts.body)
    parse:revert()
    request:revert()
    assert.is_true(vim.wait(1000, function() return result ~= nil end), "web search did not complete")
    assert.equals("POST", method)
    assert.equals("https://api.outcrawl.ai/v1/search", url)
    assert.equals("Bearer test-key", opts.headers["Authorization"])
    assert.are.same({ query = "neovim", limit = 10 }, body)
    assert.are.same(
      { { title = "Neovim", url = "https://neovim.io/", snippet = "Vim-based editor" } },
      vim.json.decode(result)
    )
  end)
end)

describe("web_search_sofya", function()
  it("posts the query and maps results to title, url and snippet", function()
    Config.setup()
    local parse = stub(Utils.environment, "parse", function() return "test-key" end)
    local request = stub(
      vim.net,
      "request",
      function(_, _, _, on_response)
        on_response(nil, {
          body = vim.json.encode({
            query = "neovim",
            results = { { url = "https://neovim.io/", title = "Neovim", content = "Vim-based editor" } },
            credits_used = 1,
          }),
        })
      end
    )

    local result
    WebSearch.web_search_sofya.func({ query = "neovim" }, { on_complete = function(r) result = r end })

    local method, url, opts = unpack(request.calls[1].refs)
    local body = vim.json.decode(opts.body)
    parse:revert()
    request:revert()
    assert.is_true(vim.wait(1000, function() return result ~= nil end), "web search did not complete")
    assert.equals("POST", method)
    assert.equals("https://sofya.co/v1/search", url)
    assert.equals("Bearer test-key", opts.headers["Authorization"])
    assert.are.same({ query = "neovim", search_depth = "snippets", max_results = 10 }, body)
    assert.are.same(
      { { title = "Neovim", url = "https://neovim.io/", snippet = "Vim-based editor" } },
      vim.json.decode(result)
    )
  end)
end)
