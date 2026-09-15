local stub = require("luassert.stub")
local Config = require("avante.config")
local Tools = require("avante.llm_tools")
local WebSearch = require("avante.llm_tools.web_search")
local Utils = require("avante.utils")
local curl = require("plenary.curl")

describe("Parallel web search", function()
  local module_name = "mcphub.extensions.avante"
  local original_loaded, original_preload
  local calls
  local result = '{"results":[{"url":"https://neovim.io/","title":"Neovim","excerpts":["Text editor"]}]}'

  before_each(function()
    Config.setup()
    calls = {}
    original_loaded = package.loaded[module_name]
    original_preload = package.preload[module_name]
    package.loaded[module_name] = nil
    package.preload[module_name] = function()
      return {
        mcp_tool = function()
          -- MCPHub returns multiple tools without guaranteeing their order.
          return { name = "access_mcp_resource" }, {
            name = "use_mcp_tool",
            func = function(input, opts)
              table.insert(calls, { input = input, opts = opts })
              return result, nil
            end,
          }
        end,
      }
    end
  end)

  after_each(function()
    package.loaded[module_name] = original_loaded
    package.preload[module_name] = original_preload
    Config.setup()
  end)

  it("keeps the default search tool and loads Parallel only when configured", function()
    local defaults = Tools.get_tools("", {})
    assert.is_truthy(vim.iter(defaults):find(function(tool) return tool.name == "web_search_tavily" end))
    assert.is_nil(vim.iter(defaults):find(function(tool) return tool.name == "web_search_parallel" end))
    assert.is_nil(package.loaded[module_name])

    Config.setup({ custom_tools = { WebSearch.web_search_parallel }, disabled_tools = { "web_search_tavily" } })
    local tools = Tools.get_tools("", {})
    assert.is_nil(vim.iter(tools):find(function(tool) return tool.name == "web_search_tavily" end))
    assert.is_truthy(vim.iter(tools):find(function(tool) return tool.name == "web_search_parallel" end))
    local output, err = Tools.process_tool_use(tools, {
      id = "search",
      name = "web_search_parallel",
      input = { query = "Neovim documentation" },
    }, { session_ctx = {} })
    assert.is_nil(err)
    assert.equals(result, output)
    assert.equals(1, #calls)
  end)

  it("maps the query and preserves the MCP tool's options and result", function()
    local opts = { session_ctx = {}, on_log = function() end, on_complete = function() end }
    local output, err = WebSearch.web_search_parallel.func({ query = "Neovim documentation" }, opts)
    assert.is_nil(err)
    assert.equals(result, output)
    assert.equals("avante-parallel", calls[1].input.server_name)
    assert.equals("web_search", calls[1].input.tool_name)
    assert.equals("Neovim documentation", calls[1].input.tool_input.objective)
    assert.are.same({ "Neovim documentation" }, calls[1].input.tool_input.search_queries)
    assert.equals(opts, calls[1].opts)
  end)

  it("reuses session metadata within a context and separates independent contexts", function()
    local first, second = {}, {}
    WebSearch.web_search_parallel.func({ query = "Neovim" }, { session_ctx = first })
    WebSearch.web_search_parallel.func({ query = "Neovim plugins" }, { session_ctx = first })
    WebSearch.web_search_parallel.func({ query = "Neovim" }, { session_ctx = second })
    local session_id = calls[1].input.tool_input.session_id
    assert.is_truthy(session_id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"))
    assert.equals(session_id, calls[2].input.tool_input.session_id)
    assert.are_not.equals(session_id, calls[3].input.tool_input.session_id)
  end)

  it("rejects missing or blank queries before loading MCPHub", function()
    for _, input in ipairs({ {}, { query = "" }, { query = " \n\t" }, { query = 42 } }) do
      local output, err = WebSearch.web_search_parallel.func(input, {})
      assert.is_nil(output)
      assert.equals("A search query is required", err)
    end
    assert.equals(0, #calls)
    assert.is_nil(package.loaded[module_name])
  end)

  it("rejects a shared proxy setting before any MCP request", function()
    Config.setup({ web_search_engine = { proxy = "http://127.0.0.1:7890" } })
    local output, err = WebSearch.web_search_parallel.func({ query = "Neovim" }, {})
    assert.is_nil(output)
    assert.equals("web_search_engine.proxy is not supported by the Parallel MCP tool", err)
    assert.equals(0, #calls)
    assert.is_nil(package.loaded[module_name])
  end)

  it("reports the missing optional client without affecting other tools", function()
    package.preload[module_name] = function() error("optional client is not installed") end
    local output, err = WebSearch.web_search_parallel.func({ query = "Neovim" }, {})
    assert.is_nil(output)
    assert.is_truthy(err:find("requires mcphub.nvim", 1, true))

    local request
    local key = stub(Utils.environment, "parse", function() return "existing-provider-key" end)
    local post = stub(curl, "post", function(url, opts)
      request = { url = url, opts = opts }
      return { status = 200, body = vim.json.encode({ answer = "Existing provider result" }) }
    end)
    output, err = WebSearch.web_search_tavily.func({ query = "Neovim" }, {})
    key:revert()
    post:revert()
    assert.is_nil(err)
    assert.equals("Existing provider result", output)
    assert.equals("https://api.tavily.com/search", request.url)
    assert.equals("Bearer existing-provider-key", request.opts.headers.Authorization)
    assert.is_nil(request.opts.headers["User-Agent"])
  end)

  it("preserves asynchronous completion and MCP errors", function()
    local completion
    package.preload[module_name] = function()
      return {
        mcp_tool = function()
          return {
            name = "use_mcp_tool",
            func = function(_, opts)
              completion = opts.on_complete
              return nil, nil
            end,
          }
        end,
      }
    end
    local completed_result, completed_error
    local output, err = WebSearch.web_search_parallel.func({ query = "Neovim" }, {
      on_complete = function(value, error)
        completed_result, completed_error = value, error
      end,
    })
    assert.is_nil(output)
    assert.is_nil(err)
    completion(nil, "MCP service error")
    assert.is_nil(completed_result)
    assert.equals("MCP service error", completed_error)
  end)

  it("reports an unavailable MCP tool rather than returning an empty success", function()
    package.preload[module_name] = function()
      return { mcp_tool = function() return { name = "access_mcp_resource" } end }
    end
    local output, err = WebSearch.web_search_parallel.func({ query = "Neovim" }, {})
    assert.is_nil(output)
    assert.equals("MCPHub's Avante tool is unavailable", err)
  end)
end)
