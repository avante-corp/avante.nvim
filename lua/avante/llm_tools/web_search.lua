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

return M
