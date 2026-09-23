---@mod avante-tools-web-search Web search tools
---@brief [[
---<
---  vim.g.avante = {
---    web_search_engine = {
---      proxy = nil,
---    },
---  }
--->
---
--- Supported providers and environment variables:
---
--- - Tavily: `TAVILY_API_KEY`
--- - SerpApi: `SERPAPI_API_KEY`
--- - SearchAPI: `SEARCHAPI_API_KEY`
--- - Google: `GOOGLE_SEARCH_API_KEY` and `GOOGLE_SEARCH_ENGINE_ID`
--- - Kagi: `KAGI_API_KEY`
--- - Brave Search: `BRAVE_API_KEY`
--- - SearXNG: `SEARXNG_API_URL`
--- - Parallel Search MCP: no API key; requires |avante-tools-web-search-parallel|
---@brief ]]

local Config = require("avante.config")
local Utils = require("avante.utils")

---@alias WebSearchProviderName
---| '"tavily"'
---| '"serpapi"'
---| '"searchapi"'
---| '"google"'
---| '"kagi"'
---| '"brave"'
---| '"searxng"'
---| '"parallel"'

---@alias WebSearchResponseFormatter fun(body: table): (string, string?)

---@param provider WebSearchProviderName
---@param input { query: string }
---@param opts AvanteLLMToolFuncOpts
local function log_search(provider, input, opts)
  if opts.on_log then opts.on_log("provider: " .. provider) end
  if opts.on_log then opts.on_log("query: " .. input.query) end
end

---@param api_key_name string
---@return string? api_key
---@return string? error
local function get_api_key(api_key_name)
  if api_key_name == "" then return nil, "No API key provided" end
  local api_key = Utils.environment.parse(api_key_name)
  if api_key == nil or api_key == "" then return nil, "Environment variable " .. api_key_name .. " is not set" end
  return api_key, nil
end

---@param query_params table<string, any>
---@return string
local function encode_query(query_params)
  local query_string = ""
  for key, value in pairs(query_params) do
    query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
  end
  return query_string
end

---@param resp { body: string }
---@param formatter WebSearchResponseFormatter
---@return string? result
---@return string? error
local function format_response(resp, formatter) return formatter(vim.json.decode(resp.body)) end

---@param method string
---@param url string
---@param request_opts table
---@param opts AvanteLLMToolFuncOpts
---@param formatter WebSearchResponseFormatter
local function request(method, url, request_opts, opts, formatter)
  if Config.web_search_engine.proxy then return nil, "web_search_engine.proxy is not supported by vim.net" end
  --- TODO: Remove this suppression when the vendored Neovim 0.12 runtime annotations include the method overload.
  ---@diagnostic disable-next-line: redundant-parameter, param-type-mismatch
  vim.net.request(method, url, request_opts, function(err, resp)
    if err then
      opts.on_complete(nil, err)
      return
    end
    assert(resp)
    local result, format_err = format_response(resp, formatter)
    opts.on_complete(result, format_err)
  end)
  return nil, nil
end

---@type AvanteLLMToolFunc<{ query: string }>
---Expects TAVILY_API_KEY in environment
local function web_search_tavily_func(input, opts)
  log_search("tavily", input, opts)
  local api_key, api_key_err = get_api_key("TAVILY_API_KEY")
  if not api_key then return nil, api_key_err end
  return request("POST", "https://api.tavily.com/search", {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    },
    body = vim.json.encode({
      query = input.query,
      include_answer = "basic",
    }),
  }, opts, function(body) return body.answer, nil end)
end

---@type AvanteLLMToolFunc<{ query: string }>
---Export your key as SERPAPI_API_KEY
---Free plan asks for phone number
local function web_search_serpapi_func(input, opts)
  log_search("serpapi", input, opts)
  local api_key, api_key_err = get_api_key("SERPAPI_API_KEY")
  if not api_key then return nil, api_key_err end
  local query = encode_query({
    api_key = api_key,
    q = input.query,
    engine = "google",
    google_domain = "google.com",
  })
  return request(
    "GET",
    "https://serpapi.com/search?" .. query,
    {
      headers = { ["Content-Type"] = "application/json" },
    },
    opts,
    function(body)
      if body.answer_box ~= nil and body.answer_box.result ~= nil then return body.answer_box.result, nil end
      if body.organic_results ~= nil then
        local results = vim
          .iter(body.organic_results)
          :map(
            function(result)
              return {
                title = result.title,
                link = result.link,
                snippet = result.snippet,
                date = result.date,
              }
            end
          )
          :take(10)
          :totable()
        return vim.json.encode(results), nil
      end
      return "", nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
local function web_search_searchapi_func(input, opts)
  log_search("searchapi", input, opts)
  local api_key, api_key_err = get_api_key("SEARCHAPI_API_KEY")
  if not api_key then return nil, api_key_err end
  local query = encode_query({
    api_key = api_key,
    q = input.query,
    engine = "google",
  })
  return request(
    "GET",
    "https://searchapi.io/api/v1/search?" .. query,
    {
      headers = { ["Content-Type"] = "application/json" },
    },
    opts,
    function(body)
      if body.answer_box ~= nil then return body.answer_box.result, nil end
      if body.organic_results ~= nil then
        local results = vim
          .iter(body.organic_results)
          :map(
            function(result)
              return {
                title = result.title,
                link = result.link,
                snippet = result.snippet,
                date = result.date,
              }
            end
          )
          :take(10)
          :totable()
        return vim.json.encode(results), nil
      end
      return "", nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
---Lets you ask your custom search engine
--- Note: Closed to new customers: https://developers.google.com/custom-search/v1/overview
---Needs:
---- GOOGLE_SEARCH_API_KEY: get it from https://console.cloud.google.com ("customsearch" section)
---- GOOGLE_SEARCH_ENGINE_ID: create one from https://programmablesearchengine.google.com
local function web_search_google_func(input, opts)
  log_search("google", input, opts)
  local api_key, api_key_err = get_api_key("GOOGLE_SEARCH_API_KEY")
  if not api_key then return nil, api_key_err end
  local engine_id = Utils.environment.parse("GOOGLE_SEARCH_ENGINE_ID")
  if engine_id == nil or engine_id == "" then return nil, "Environment variable GOOGLE_SEARCH_ENGINE_ID is not set" end
  local query = encode_query({
    key = api_key,
    cx = engine_id,
    q = input.query,
  })
  return request(
    "GET",
    "https://www.googleapis.com/customsearch/v1?" .. query,
    {
      headers = { ["Content-Type"] = "application/json" },
    },
    opts,
    function(body)
      if body.items ~= nil then
        local results = vim
          .iter(body.items)
          :map(
            function(result)
              return {
                title = result.title,
                link = result.link,
                snippet = result.snippet,
              }
            end
          )
          :take(10)
          :totable()
        return vim.json.encode(results), nil
      end
      return "", nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
local function web_search_kagi_func(input, opts)
  log_search("kagi", input, opts)
  local api_key, api_key_err = get_api_key("KAGI_API_KEY")
  if not api_key then return nil, api_key_err end
  local query = encode_query({ q = input.query, limit = "10" })
  return request(
    "GET",
    "https://kagi.com/api/v0/search?" .. query,
    {
      headers = {
        ["Authorization"] = "Bot " .. api_key,
        ["Content-Type"] = "application/json",
      },
    },
    opts,
    function(body)
      if body.data ~= nil then
        local results = vim
          .iter(body.data)
          :filter(function(result) return result.t == 0 end)
          :map(
            function(result)
              return {
                title = result.title,
                url = result.url,
                snippet = result.snippet,
              }
            end
          )
          :take(10)
          :totable()
        return vim.json.encode(results), nil
      end
      return "", nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
---Paying service. Export your key as BRAVE_API_KEY
local function web_search_brave_func(input, opts)
  log_search("brave", input, opts)
  local api_key, api_key_err = get_api_key("BRAVE_API_KEY")
  if not api_key then return nil, api_key_err end
  local query = encode_query({ q = input.query, count = "10", result_filter = "web" })
  return request(
    "GET",
    "https://api.search.brave.com/res/v1/web/search?" .. query,
    {
      headers = {
        ["Content-Type"] = "application/json",
        ["X-Subscription-Token"] = api_key,
      },
    },
    opts,
    function(body)
      if body.web == nil then return "", nil end
      local results = vim.iter(body.web.results):map(
        function(result)
          return {
            title = result.title,
            url = result.url,
            snippet = result.description,
          }
        end
      )
      return vim.json.encode(results), nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
local function web_search_searxng_func(input, opts)
  log_search("searxng", input, opts)
  local api_url = Utils.environment.parse("SEARXNG_API_URL")
  if api_url == nil or api_url == "" then return nil, "Environment variable SEARXNG_API_URL is not set" end
  local query = encode_query({ q = input.query, format = "json" })
  return request(
    "GET",
    api_url .. "?" .. query,
    { headers = { ["Content-Type"] = "application/json" } },
    opts,
    function(body)
      if body.results == nil then return "", nil end
      local results = vim.iter(body.results):map(
        function(result)
          return {
            title = result.title,
            url = result.url,
            snippet = result.content,
          }
        end
      )
      return vim.json.encode(results), nil
    end
  )
end

---@type AvanteLLMToolFunc<{ query: string }>
local function web_search_parallel_func(input, opts)
  if type(input.query) ~= "string" or input.query:match("^%s*$") then return nil, "A search query is required" end
  if Config.web_search_engine.proxy then
    return nil, "web_search_engine.proxy is not supported by the Parallel MCP tool"
  end
  local ok, mcp = pcall(require, "mcphub.extensions.avante")
  if not ok then return nil, "Parallel Search MCP requires mcphub.nvim; see the Web Search Engines setup" end

  log_search("parallel", input, opts)
  local arguments = { objective = input.query, search_queries = { input.query } }
  if opts.session_ctx then
    -- Sidebar contexts are per submission; use the chat's persisted session when available.
    local ctx = opts.session_ctx
    if ctx.get_parallel_search_session_id then
      arguments.session_id = ctx.get_parallel_search_session_id()
    else
      ctx.parallel_search_session_id = ctx.parallel_search_session_id or Utils.uuid()
      arguments.session_id = ctx.parallel_search_session_id
    end
  end
  -- Reuse MCPHub's Avante tool so its approval policy and MCP lifecycle stay intact.
  for _, tool in ipairs({ mcp.mcp_tool() }) do
    if tool.name == "use_mcp_tool" then
      return tool.func({ server_name = "avante-parallel", tool_name = "web_search", tool_input = arguments }, opts)
    end
  end
  return nil, "MCPHub's Avante tool is unavailable"
end

---@param provider WebSearchProviderName
---@param func AvanteLLMToolFunc<{ query: string }>
---@return AvanteLLMTool
local function web_search_tool(provider, func)
  return {
    name = "web_search_" .. provider,
    description = "Search the web using " .. provider,
    param = {
      type = "table",
      fields = {
        { name = "query", description = "Query to search", type = "string" },
      },
      usage = { query = "Query to search" },
    },
    returns = {
      { name = "result", description = "Result of the search", type = "string" },
      {
        name = "error",
        description = "Error message if the search was not successful",
        type = "string",
        optional = true,
      },
    },
    func = func,
  }
end

local M = {}

---@brief Search with tavily
M.web_search_tavily = web_search_tool("tavily", web_search_tavily_func)
M.web_search_serpapi = web_search_tool("serpapi", web_search_serpapi_func)
M.web_search_searchapi = web_search_tool("searchapi", web_search_searchapi_func)
M.web_search_google = web_search_tool("google", web_search_google_func)
M.web_search_kagi = web_search_tool("kagi", web_search_kagi_func)
M.web_search_brave = web_search_tool("brave", web_search_brave_func)
M.web_search_searxng = web_search_tool("searxng", web_search_searxng_func)

---@tag avante-tools-web-search-parallel
---@brief [[
---Parallel Search MCP is an optional search tool. Install and set up
---mcphub.nvim, then merge this connection into its servers.json:
--->json
---  {
---    "mcpServers": {
---      "avante-parallel": {
---        "url": "https://search.parallel.ai/mcp",
---        "headers": { "User-Agent": "avante.nvim mcphub.nvim" }
---      }
---    }
---  }
---<
---The project-wide User-Agent identifies this Avante connection so Parallel can
---measure aggregate free MCP usage. Keep it when changing the transport; do not
---add user or installation identifiers.
---
---Add the tool through |avante-custom-tools|:
--->lua
---  custom_tools = {
---    require("avante.llm_tools.web_search").web_search_parallel,
---  }
---<
---Tavily remains enabled by default. To use Parallel as your only search tool,
---also add "web_search_tavily" to disabled_tools. MCPHub's approval settings
---still apply. The shared web_search_engine.proxy setting is not supported.
---
---No Parallel account or API key is required. Free access is rate limited.
---Once enabled, the agent may request searches. Queries, their objective, and
---supplied session metadata go to Parallel, subject to its Customer Terms and
---Privacy Policy: https://parallel.ai/customer-terms and
---https://parallel.ai/privacy-policy. LLM provider authentication is separate.
---@brief ]]
M.web_search_parallel = web_search_tool("parallel", web_search_parallel_func)

return M
