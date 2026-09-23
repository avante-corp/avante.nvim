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

  it("keeps a session across sidebar submissions, resumed history, and clear/new chat boundaries", function()
    -- This test exercises submission state without mounting NUI windows.
    local saved_modules = {}
    for name, value in pairs({ ["nui.split"] = {}, ["nui.utils.autocmd"] = { event = {} } }) do
      saved_modules[name] = { loaded = package.loaded[name], preload = package.preload[name] }
      package.loaded[name] = value
    end
    local original_sidebar = package.loaded["avante.sidebar"]
    package.loaded["avante.sidebar"] = nil
    local Sidebar = require("avante.sidebar")
    package.loaded["avante.sidebar"] = original_sidebar
    for name, value in pairs(saved_modules) do
      package.loaded[name], package.preload[name] = value.loaded, value.preload
    end

    local Llm = require("avante.llm")
    local Path = require("avante.path")
    local streams, saved = {}, nil
    local stream = stub(Llm, "stream", function(opts) streams[#streams + 1] = opts end)
    local save = stub(Path.history, "save", function(_, history) saved = vim.deepcopy(history) end)
    local sidebar = setmetatable({
      code = { bufnr = vim.api.nvim_get_current_buf() },
      containers = { result = { bufnr = vim.api.nvim_get_current_buf() } },
      chat_history = { filename = "0.json", messages = {}, entries = {} },
      file_selector = { get_selected_filepaths = function() return {} end },
      update_content = function() end,
      update_content_with_history = function() end,
      add_history_messages = function() end,
      clear_state = function() end,
      render_state = function() end,
      reload_chat_history = function(self) self.chat_history = vim.deepcopy(saved) end,
      get_generate_prompts_options = function(_, _, cb) cb({}) end,
    }, { __index = Sidebar })
    local function submit(query)
      sidebar:handle_submit(query)
      local output, err = Tools.process_tool_use({ WebSearch.web_search_parallel }, {
        id = "submission",
        name = "web_search_parallel",
        input = { query = query },
      }, { session_ctx = streams[#streams].session_ctx })
      assert.is_nil(err)
      assert.equals(result, output)
      return calls[#calls].input.tool_input.session_id
    end
    local ok, failure = xpcall(function()
      sidebar:handle_submit("Before searching")
      assert.is_nil(saved) -- Optional search creates no session until it is called.
      assert.is_nil(package.loaded[module_name])
      local first = submit("Neovim")
      assert.equals(first, submit("Neovim Lua"))
      assert.are_not.equals(streams[2].session_ctx, streams[3].session_ctx)
      sidebar:reload_chat_history()
      assert.equals(first, submit("Resume Neovim"))
      sidebar:clear_history()
      local cleared = submit("Search after clearing")
      assert.are_not.equals(first, cleared)
      sidebar.chat_history = { filename = "1.json", messages = {}, entries = {} }
      assert.are_not.equals(cleared, submit("Independent chat"))
    end, debug.traceback)
    stream:revert()
    save:revert()
    for _, key in ipairs({ "j", "k", "G" }) do
      vim.keymap.del("n", key, { buffer = sidebar.containers.result.bufnr })
    end
    assert.is_true(ok, failure)
  end)
end)
