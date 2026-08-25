---@tag avante-custom-tools
---@brief [[
---Custom tools can run shell commands, scripts, or Lua functions
---<
---   vim.g.avante = {
---     custom_tools = {
---       {
---         name = "run_go_tests",
---         description = "Run Go unit tests and return results",
---         param = {
---           type = "table",
---           fields = {
---             {
---               name = "target",
---               description = "Package or directory to test",
---               type = "string",
---               optional = true,
---             },
---           },
---         },
---         returns = {
---           {
---             name = "result",
---             description = "Test output",
---             type = "string",
---           },
---         },
---         func = function(params)
---           local target = params.target or "./..."
---           return vim.system({ "go", "test", "-v", target }, { text = true }):wait().stdout
---         end,
---       },
---     },
---   }
--->
---@brief ]]
---
---@mod avante-tools avante tools
---@brief [[
---
--- Agentic mode enables tool use. If a model does not support tools, disable
--- them for that provider:
--->
---   require("avante").setup({
---     providers = {
---       claude = {
---         disable_tools = true,
---       },
---     },
---   })
---<
---
---
---@brief ]]
---@tag avante-tools-builtins
---@brief [[
--- Built-in tool names include:
--->
---   rag_search, python, git_diff, git_commit, glob, search_keyword,
---   read_file_toplevel_symbols, read_file, create_file, move_path, copy_path,
---   delete_path, create_dir, bash, web_search, fetch
---<
---
---@brief ]]

local Utils = require("avante.utils")
local Path = require("plenary.path")
local Config = require("avante.config")
local Helpers = require("avante.llm_tools.helpers")

local M = {}

---@type AvanteLLMToolFunc<{ path: string }>
function M.read_file_toplevel_symbols(input, opts)
  local on_log = opts.on_log
  local RepoMap = require("avante.repo_map")
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  if not Path:new(abs_path):exists() then return "", "File does not exists: " .. abs_path end
  local filetype = RepoMap.get_ts_lang(abs_path)
  local repo_map_lib = RepoMap._init_repo_map_lib()
  if not repo_map_lib then return "", "Failed to load avante_repo_map" end
  local lines = Utils.read_file_from_buf_or_disk(abs_path)
  local content = lines and table.concat(lines, "\n") or ""
  local definitions = filetype and repo_map_lib.stringify_definitions(filetype, content) or ""
  return definitions, nil
end

---@type AvanteLLMToolFunc<{ command: "view" | "str_replace" | "create" | "insert" | "undo_edit", path: string, old_str?: string, new_str?: string, file_text?: string, insert_line?: integer, new_str?: string, view_range?: integer[] }>
function M.str_replace_editor(input, opts)
  if input.command == "undo_edit" then return require("avante.llm_tools.undo_edit").func(input, opts) end
  ---@cast input any
  return M.str_replace_based_edit_tool(input, opts)
end

---@type AvanteLLMToolFunc<{ command: "view" | "str_replace" | "create" | "insert", path: string, old_str?: string, new_str?: string, file_text?: string, insert_line?: integer, new_str?: string, view_range?: integer[] }>
function M.str_replace_based_edit_tool(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  if not input.command then return false, "command not provided" end
  if on_log then on_log("command: " .. input.command) end
  if not on_complete then return false, "on_complete not provided" end
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if input.command == "view" then
    local view = require("avante.llm_tools.view")
    local input_ = { path = input.path }
    if input.view_range then
      local start_line, end_line = unpack(input.view_range)
      input_.start_line = start_line
      input_.end_line = end_line
    end
    return view(input_, opts)
  end
  if input.command == "str_replace" then
    if input.new_str == nil and input.file_text ~= nil then
      input.new_str = input.file_text
      input.file_text = nil
    end
    return require("avante.llm_tools.str_replace").func(input, opts)
  end
  if input.command == "create" then return require("avante.llm_tools.create").func(input, opts) end
  if input.command == "insert" then return require("avante.llm_tools.insert").func(input, opts) end
  return false, "Unknown command: " .. input.command
end

---@type AvanteLLMToolFunc<{ abs_path: string }>
function M.read_global_file(input, opts)
  local on_log = opts.on_log
  local abs_path = Helpers.get_abs_path(input.abs_path)
  if Helpers.is_ignored(abs_path) then return "", "This file is ignored: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  local file = io.open(abs_path, "r")
  if not file then return "", "file not found: " .. abs_path end
  local content = file:read("*a")
  file:close()
  return content, nil
end

---@type AvanteLLMToolFunc<{ abs_path: string, content: string }>
function M.write_global_file(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.abs_path)
  if Helpers.is_ignored(abs_path) then return false, "This file is ignored: " .. abs_path end
  if on_log then on_log("path: " .. abs_path) end
  if on_log then on_log("content: " .. input.content) end
  if not on_complete then return false, "on_complete not provided" end
  Helpers.confirm("Are you sure you want to write to the file: " .. abs_path, function(ok)
    if not ok then
      on_complete(false, "User canceled")
      return
    end
    local file = io.open(abs_path, "w")
    if not file then
      on_complete(false, "file not found: " .. abs_path)
      return
    end
    file:write(input.content)
    file:close()
    on_complete(true, nil)
  end, nil, opts.session_ctx, "write_global_file")
end

---@type AvanteLLMToolFunc<{ source_path: string, destination_path: string }>
function M.move_path(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.source_path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "The source path not found: " .. abs_path end
  local new_abs_path = Helpers.get_abs_path(input.destination_path)
  if on_log then on_log(abs_path .. " -> " .. new_abs_path) end
  if not Helpers.has_permission_to_access(new_abs_path) then
    return false, "No permission to access path: " .. new_abs_path
  end
  if Path:new(new_abs_path):exists() then return false, "The destination path already exists: " .. new_abs_path end
  if not on_complete then return false, "on_complete not provided" end
  Helpers.confirm(
    "Are you sure you want to move the path: " .. abs_path .. " to: " .. new_abs_path,
    function(ok, reason)
      if not ok then
        on_complete(false, "User declined, reason: " .. (reason or "unknown"))
        return
      end
      os.rename(abs_path, new_abs_path)
      on_complete(true, nil)
    end,
    nil,
    opts.session_ctx,
    "move_path"
  )
end

---@type AvanteLLMToolFunc<{ source_path: string, destination_path: string }>
function M.copy_path(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.source_path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "The source path not found: " .. abs_path end
  local new_abs_path = Helpers.get_abs_path(input.destination_path)
  if not Helpers.has_permission_to_access(new_abs_path) then
    return false, "No permission to access path: " .. new_abs_path
  end
  if Path:new(new_abs_path):exists() then return false, "The destination path already exists: " .. new_abs_path end
  if not on_complete then return false, "on_complete not provided" end
  Helpers.confirm(
    "Are you sure you want to copy the path: " .. abs_path .. " to: " .. new_abs_path,
    function(ok, reason)
      if not ok then
        on_complete(false, "User declined, reason: " .. (reason or "unknown"))
        return
      end
      if on_log then on_log("Copying path: " .. abs_path .. " to " .. new_abs_path) end
      if vim.fn.isdirectory(abs_path) == 1 then
        Path:new(new_abs_path):mkdir({ parents = true })
        for _, entry in ipairs(Path:new(abs_path):list()) do
          local new_entry_path = Path:new(new_abs_path):joinpath(entry)
          if entry:match("^%.") then goto continue end
          if Path:new(new_entry_path):exists() then
            if vim.fn.isdirectory(tostring(new_entry_path)) == 1 then
              vim.fs.rm(tostring(new_entry_path), { recursive = true })
            else
              Path:new(new_entry_path):unlink()
            end
          end
          vim.fn.mkdir(new_entry_path, "p")
          Path:new(new_entry_path):write(Path:new(abs_path):joinpath(entry):read(), "w")
          ::continue::
        end
      else
        Path:new(new_abs_path):write(Path:new(abs_path):read(), "w")
      end
      on_complete(true, nil)
    end,
    nil,
    opts.session_ctx,
    "copy_path"
  )
end

---@type AvanteLLMToolFunc<{ path: string }>
function M.delete_path(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Path not found: " .. abs_path end
  if not on_complete then return false, "on_complete not provided" end
  Helpers.confirm("Are you sure you want to delete the path: " .. abs_path, function(ok, reason)
    if not ok then
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    if on_log then on_log("Deleting path: " .. abs_path) end
    os.remove(abs_path)
    on_complete(true, nil)
  end, nil, opts.session_ctx, "delete_path")
end

---@type AvanteLLMToolFunc<{ path: string }>
function M.create_dir(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if Path:new(abs_path):exists() then return false, "Directory already exists: " .. abs_path end
  if not on_complete then return false, "on_complete not provided" end
  Helpers.confirm("Are you sure you want to create the directory: " .. abs_path, function(ok, reason)
    if not ok then
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    if on_log then on_log("Creating directory: " .. abs_path) end
    Path:new(abs_path):mkdir({ parents = true })
    on_complete(true, nil)
  end, nil, opts.session_ctx, "create_dir")
end

---@tag avante-web-search
---@brief [[
---<
---  vim.g.avante = {
---    web_search_engine = {
---      provider = "tavily",
---      proxy = nil,
---    },
---  }
--->
---
--- Supported providers and environment variables:
---
--- - Tavily: `TAVILY_API_KEY`
--- - SerpApi: `SERPAPI_API_KEY`
--- - Google: `GOOGLE_SEARCH_API_KEY` and `GOOGLE_SEARCH_ENGINE_ID`
--- - Kagi: `KAGI_API_KEY`
--- - Brave Search: `BRAVE_API_KEY`
--- - SearXNG: `SEARXNG_API_URL`
---@brief ]]
---@type AvanteLLMToolFunc<{ query: string }>
function M.web_search(input, opts)
  local curl = require("plenary.curl")
  local on_log = opts.on_log
  local provider_type = Config.web_search_engine.provider
  local proxy = Config.web_search_engine.proxy
  if provider_type == nil then return nil, "Search engine provider is not set" end
  if on_log then on_log("provider: " .. provider_type) end
  if on_log then on_log("query: " .. input.query) end
  local search_engine = Config.web_search_engine.providers[provider_type]
  if search_engine == nil then return nil, "No search engine found: " .. provider_type end
  if provider_type ~= "searxng" and search_engine.api_key_name == "" then return nil, "No API key provided" end
  local api_key = provider_type ~= "searxng" and Utils.environment.parse(search_engine.api_key_name) or nil
  if provider_type ~= "searxng" and api_key == nil or api_key == "" then
    return nil, "Environment variable " .. search_engine.api_key_name .. " is not set"
  end
  if provider_type == "tavily" then
    local curl_opts = {
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
      },
      body = vim.json.encode(vim.tbl_deep_extend("force", {
        query = input.query,
      }, search_engine.extra_request_body)),
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.post("https://api.tavily.com/search", curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "serpapi" then
    local query_params = vim.tbl_deep_extend("force", {
      api_key = api_key,
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local curl_opts = {
      headers = {
        ["Content-Type"] = "application/json",
      },
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.get("https://serpapi.com/search?" .. query_string, curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "searchapi" then
    local query_params = vim.tbl_deep_extend("force", {
      api_key = api_key,
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local curl_opts = {
      headers = {
        ["Content-Type"] = "application/json",
      },
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.get("https://searchapi.io/api/v1/search?" .. query_string, curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "google" then
    local engine_id = Utils.environment.parse(search_engine.engine_id_name)
    if engine_id == nil or engine_id == "" then
      return nil, "Environment variable " .. search_engine.engine_id_name .. " is not set"
    end
    local query_params = vim.tbl_deep_extend("force", {
      key = api_key,
      cx = engine_id,
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local curl_opts = {
      headers = {
        ["Content-Type"] = "application/json",
      },
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.get("https://www.googleapis.com/customsearch/v1?" .. query_string, curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "kagi" then
    local query_params = vim.tbl_deep_extend("force", {
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local curl_opts = {
      headers = {
        ["Authorization"] = "Bot " .. api_key,
        ["Content-Type"] = "application/json",
      },
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.get("https://kagi.com/api/v0/search?" .. query_string, curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "brave" then
    local query_params = vim.tbl_deep_extend("force", {
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local curl_opts = {
      headers = {
        ["Content-Type"] = "application/json",
        ["X-Subscription-Token"] = api_key,
      },
    }
    if proxy then curl_opts.proxy = proxy end
    local resp = curl.get("https://api.search.brave.com/res/v1/web/search?" .. query_string, curl_opts)
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  elseif provider_type == "searxng" then
    local searxng_api_url = Utils.environment.parse(search_engine.api_url_name)
    if searxng_api_url == nil or searxng_api_url == "" then
      return nil, "Environment variable " .. search_engine.api_url_name .. " is not set"
    end
    local query_params = vim.tbl_deep_extend("force", {
      q = input.query,
    }, search_engine.extra_request_body)
    local query_string = ""
    for key, value in pairs(query_params) do
      query_string = query_string .. key .. "=" .. vim.uri_encode(value) .. "&"
    end
    local resp = curl.get(searxng_api_url .. "?" .. query_string, {
      headers = {
        ["Content-Type"] = "application/json",
      },
    })
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return search_engine.format_response_body(jsn)
  end
  return nil, "Error: No search engine found"
end

---@type AvanteLLMToolFunc<{ url: string }>
function M.fetch(input, opts)
  local on_log = opts.on_log
  if on_log then on_log("url: " .. input.url) end
  local Html2Md = require("avante.html2md")
  local res, err = Html2Md.fetch_md(input.url)
  if err then return nil, err end
  return res, nil
end

---@type AvanteLLMToolFunc<{ scope?: string }>
function M.git_diff(input, opts)
  local on_log = opts.on_log
  local git_cmd = vim.fn.exepath("git")
  if git_cmd == "" then return nil, "Git command not found" end
  local project_root = Utils.get_project_root()
  if not project_root then return nil, "Not in a git repository" end

  -- Check if we're in a git repository
  local git_dir = vim.system({ "git", "rev-parse", "--git-dir" }, { text = true }):wait().stdout:gsub("\n", "")
  if git_dir == "" then return nil, "Not a git repository" end

  -- Get the diff
  local scope = input.scope or ""
  local cmd = { "git", "diff", "--cached", scope }
  if on_log then on_log("Running command: " .. table.concat(cmd, " ")) end
  local diff = vim.system(cmd, { text = true }):wait().stdout

  if diff == "" then
    -- If there's no staged changes, get unstaged changes
    cmd = { "git", "diff", scope }
    if on_log then on_log("No staged changes. Running command: " .. table.concat(cmd, " ")) end
    diff = vim.system(cmd, { text = true }):wait().stdout
  end

  if diff == "" then return nil, "No changes detected" end

  return diff, nil
end

---@type AvanteLLMToolFunc<{ message: string, scope?: string }>
function M.git_commit(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete

  local git_cmd = vim.fn.exepath("git")
  if git_cmd == "" then return false, "Git command not found" end
  local project_root = Utils.get_project_root()
  if not project_root then return false, "Not in a git repository" end

  -- Check if we're in a git repository
  local git_dir = vim.system({ "git", "rev-parse", "--git-dir" }, { text = true }):wait().stdout:gsub("\n", "")
  if git_dir == "" then return false, "Not a git repository" end

  -- First check if there are any changes to commit
  local status = vim.system({ "git", "status", "--porcelain" }, { text = true }):wait().stdout
  if status == "" then return false, "No changes to commit" end

  -- Get git user name and email
  local git_user = vim.system({ "git", "config", "user.name" }, { text = true }):wait().stdout:gsub("\n", "")
  local git_email = vim.system({ "git", "config", "user.email" }, { text = true }):wait().stdout:gsub("\n", "")

  -- Check if GPG signing is available and configured
  local has_gpg = false
  local signing_key = vim
    .system({ "git", "config", "--get", "user.signingkey" }, { text = true })
    :wait().stdout
    :gsub("\n", "")

  if signing_key ~= "" then
    -- Try to find gpg executable based on OS
    local gpg_cmd
    if vim.fn.has("win32") == 1 then
      -- Check common Windows GPG paths
      gpg_cmd = vim.fn.exepath("gpg.exe") ~= "" and vim.fn.exepath("gpg.exe") or vim.fn.exepath("gpg2.exe")
    else
      -- Unix-like systems (Linux/MacOS)
      gpg_cmd = vim.fn.exepath("gpg") ~= "" and vim.fn.exepath("gpg") or vim.fn.exepath("gpg2")
    end

    if gpg_cmd ~= "" then
      -- Verify GPG is working
      has_gpg = vim.system({ gpg_cmd, "--version" }, { text = true }):wait().code == 0
    end
  end

  if on_log then on_log(string.format("GPG signing %s", has_gpg and "enabled" or "disabled")) end

  -- Prepare commit message
  local commit_msg_lines = {}
  for line in input.message:gmatch("[^\r\n]+") do
    commit_msg_lines[#commit_msg_lines + 1] = line:gsub('"', '\\"')
  end
  commit_msg_lines[#commit_msg_lines + 1] = ""
  -- add Generated-by line using provider and model name
  if Config.behaviour and Config.behaviour.include_generated_by_commit_line then
    local provider_name = Config.provider or "unknown"
    local model_name = (Config.providers and Config.providers[provider_name] and Config.providers[provider_name].model)
      or "unknown"
    commit_msg_lines[#commit_msg_lines + 1] = string.format("Generated-by: %s/%s", provider_name, model_name)
  end
  if git_user ~= "" and git_email ~= "" then
    commit_msg_lines[#commit_msg_lines + 1] = string.format("Signed-off-by: %s <%s>", git_user, git_email)
  end

  -- Construct full commit message for confirmation
  local full_commit_msg = table.concat(commit_msg_lines, "\n")

  if not on_complete then return false, "on_complete not provided" end

  -- Confirm with user
  Helpers.confirm("Are you sure you want to commit with message:\n" .. full_commit_msg, function(ok, reason)
    if not ok then
      on_complete(false, "User declined, reason: " .. (reason or "unknown"))
      return
    end
    -- Stage changes if scope is provided
    if input.scope then
      local stage_cmd = { "git", "add", input.scope }
      if on_log then on_log("Staging files: " .. table.concat(stage_cmd, " ")) end
      local stage_result = vim.system(stage_cmd, { text = true }):wait()
      if stage_result.code ~= 0 then
        on_complete(false, "Failed to stage files: " .. stage_result.stderr)
        return
      end
    end

    -- Construct git commit command
    local cmd_parts = { "git", "commit" }
    -- Only add -S flag if GPG is available
    if has_gpg then table.insert(cmd_parts, "-S") end
    for _, line in ipairs(commit_msg_lines) do
      table.insert(cmd_parts, "-m")
      table.insert(cmd_parts, line)
    end
    local cmd = table.concat(cmd_parts, " ")

    -- Execute git commit
    if on_log then on_log("Running command: " .. cmd) end
    local result = vim.system(cmd_parts, { text = true }):wait()

    if result.code ~= 0 then
      on_complete(false, "Failed to commit: " .. result.stderr)
      return
    end

    on_complete(true, nil)
  end, nil, opts.session_ctx, "git_commit")
end

---@type AvanteLLMToolFunc<{ query: string }>
function M.rag_search(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  if not on_complete then return nil, "on_complete not provided" end
  if not Config.rag_service.enabled then return nil, "Rag service is not enabled" end
  if not input.query then return nil, "No query provided" end
  if on_log then on_log("query: " .. input.query) end
  local root = Utils.get_project_root()
  local uri = "file://" .. root
  if uri:sub(-1) ~= "/" then uri = uri .. "/" end
  local RagService = require("avante.rag_service")
  RagService.retrieve(
    uri,
    input.query,
    vim.schedule_wrap(function(resp, err)
      if err then
        on_complete(nil, err)
        return
      end
      on_complete(vim.json.encode(resp), nil)
    end)
  )
end

---@type AvanteLLMToolFunc<{ code: string, path: string, container_image?: string }>
function M.python(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return nil, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return nil, "Path not found: " .. abs_path end
  if on_log then on_log("cwd: " .. abs_path) end
  if on_log then on_log("code:\n" .. input.code) end
  local container_image = input.container_image or "python:3.14-slim-bookworm"
  if not on_complete then return nil, "on_complete not provided" end
  Helpers.confirm(
    "Are you sure you want to run the following python code in the `"
      .. container_image
      .. "` container, in the directory: `"
      .. abs_path
      .. "`?\n"
      .. input.code,
    function(ok, reason)
      if not ok then
        on_complete(nil, "User declined, reason: " .. (reason or "unknown"))
        return
      end
      if vim.fn.executable("docker") == 0 then
        on_complete(nil, "Python tool via docker is not available to execute any code")
        return
      end

      local function handle_result(result) ---@param result vim.SystemCompleted
        if result.code ~= 0 then return nil, "Error: " .. (result.stderr or "Unknown error") end

        Utils.debug("output", result.stdout)
        return result.stdout, nil
      end
      vim.system(
        {
          "docker",
          "run",
          "--rm",
          "-v",
          abs_path .. ":" .. abs_path,
          "-w",
          abs_path,
          container_image,
          "python",
          "-c",
          input.code,
        },
        {
          text = true,
          cwd = abs_path,
        },
        vim.schedule_wrap(function(result)
          if not on_complete then return end
          local output, err = handle_result(result)
          on_complete(output, err)
        end)
      )
    end,
    nil,
    opts.session_ctx,
    "python"
  )
end

---@param user_input string
---@param history_messages AvanteLLMMessage[]
---@return AvanteLLMTool[]
function M.get_tools(user_input, history_messages)
  local custom_tools = Config.custom_tools
  if type(custom_tools) == "function" then custom_tools = custom_tools() end
  ---@type AvanteLLMTool[]
  local unfiltered_tools = vim.list_extend(vim.list_extend({}, M._tools), custom_tools)
  return vim
    .iter(unfiltered_tools)
    :filter(function(tool) ---@param tool AvanteLLMTool
      -- Always disable tools that are explicitly disabled
      if vim.tbl_contains(Config.disabled_tools, tool.name) then return false end
      if tool.enabled == nil then
        return true
      else
        return tool.enabled({ user_input = user_input, history_messages = history_messages })
      end
    end)
    :totable()
end

function M.get_tool_names()
  local custom_tools = Config.custom_tools
  if type(custom_tools) == "function" then custom_tools = custom_tools() end
  ---@type AvanteLLMTool[]
  local unfiltered_tools = vim.list_extend(vim.list_extend({}, M._tools), custom_tools)
  local tool_names = {}
  for _, tool in ipairs(unfiltered_tools) do
    table.insert(tool_names, tool.name)
  end
  return tool_names
end

---@type AvanteLLMTool[]
M._tools = {
  require("avante.llm_tools.dispatch_agent"),
  require("avante.llm_tools.glob"),
  {
    name = "rag_search",
    enabled = function() return Config.rag_service.enabled and require("avante.rag_service").is_ready() end,
    description = "Use Retrieval-Augmented Generation (RAG) to search for relevant information from an external knowledge base or documents. This tool retrieves relevant context from a large dataset and integrates it into the response generation process, improving accuracy and relevance. Use it when answering questions that require factual knowledge beyond what the model has been trained on.",
    param = {
      type = "table",
      fields = {
        {
          name = "query",
          description = "Query to search",
          type = "string",
        },
      },
      usage = {
        query = "Query to search",
      },
    },
    returns = {
      {
        name = "result",
        description = "Result of the search",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the search was not successful",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "run_python",
    description = "Run python code in current project scope. Can't use it to read files or modify files.",
    param = {
      type = "table",
      fields = {
        {
          name = "code",
          description = "Python code to run",
          type = "string",
        },
        {
          name = "path",
          description = "Relative path to the project directory, as cwd",
          type = "string",
        },
      },
      usage = {
        code = "Python code to run",
        path = "Relative path to the project directory, as cwd",
      },
    },
    returns = {
      {
        name = "result",
        description = "Python output",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the python code failed",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "git_diff",
    description = "Get git diff for generating commit message in current project scope",
    param = {
      type = "table",
      fields = {
        {
          name = "scope",
          description = "Scope for the git diff (e.g. specific files or directories)",
          type = "string",
        },
      },
      usage = {
        scope = "Scope for the git diff (e.g. specific files or directories)",
      },
    },
    returns = {
      {
        name = "result",
        description = "Git diff output to be used for generating commit message",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the diff generation failed",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "git_commit",
    description = "Commit changes with the given commit message in current project scope",
    param = {
      type = "table",
      fields = {
        {
          name = "message",
          description = "Commit message to use",
          type = "string",
        },
        {
          name = "scope",
          description = "Scope for staging files (e.g. specific files or directories)",
          type = "string",
          optional = true,
        },
      },
      usage = {
        message = "Commit message to use",
        scope = "Scope for staging files (e.g. specific files or directories)",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the commit was successful, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the commit failed",
        type = "string",
        optional = true,
      },
    },
  },
  require("avante.llm_tools.ls"),
  require("avante.llm_tools.grep"),
  require("avante.llm_tools.delete_tool_use_messages"),
  require("avante.llm_tools.read_todos"),
  require("avante.llm_tools.write_todos"),
  {
    name = "read_file_toplevel_symbols",
    description = [[Read the top-level symbols of a file in current project scope.

This tool is useful for understanding the structure of a file and extracting information about its contents. It can be used to extract information about functions, types, constants, and other symbols that are defined at the top level of a file.


<example>

Given the following file:
a.py:
```python
a = 1

class A:
  pass

def foo():
    return "bar"

def baz():
    return "qux"
```

The top-level symbols of "a.py":
[
  "a",
  "A",
  "foo",
  "baz"
]

Then you can use the "read_definitions" tool to retrieve the source code definitions of these symbols.

</example>]],
    param = {
      type = "table",
      fields = {
        {
          name = "path",
          description = "Relative path to the file in current project scope",
          type = "string",
        },
      },
      usage = {
        path = "Relative path to the file in current project scope",
      },
    },
    returns = {
      {
        name = "definitions",
        description = "Top-level symbols of the file",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the file was not read successfully",
        type = "string",
        optional = true,
      },
    },
  },
  require("avante.llm_tools.str_replace"),
  require("avante.llm_tools.view"),
  require("avante.llm_tools.write_to_file"),
  require("avante.llm_tools.insert"),
  require("avante.llm_tools.undo_edit"),
  {
    name = "read_global_file",
    description = "Read the contents of a file in the global scope. If the file content is already in the context, do not use this tool.",
    enabled = function(opts)
      if opts.user_input:match("@read_global_file") then return true end
      for _, message in ipairs(opts.history_messages) do
        if message.role == "user" then
          local content = message.content
          if type(content) == "string" and content:match("@read_global_file") then return true end
          if type(content) == "table" then
            for _, item in ipairs(content) do
              if type(item) == "string" and item:match("@read_global_file") then return true end
            end
          end
        end
      end
      return false
    end,
    param = {
      type = "table",
      fields = {
        {
          name = "abs_path",
          description = "Absolute path to the file in global scope",
          type = "string",
        },
      },
      usage = {
        abs_path = "Absolute path to the file in global scope",
      },
    },
    returns = {
      {
        name = "content",
        description = "Contents of the file",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the file was not read successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "write_global_file",
    description = "Write to a file in the global scope",
    enabled = function(opts)
      if opts.user_input:match("@write_global_file") then return true end
      for _, message in ipairs(opts.history_messages) do
        if message.role == "user" then
          local content = message.content
          if type(content) == "string" and content:match("@write_global_file") then return true end
          if type(content) == "table" then
            for _, item in ipairs(content) do
              if type(item) == "string" and item:match("@write_global_file") then return true end
            end
          end
        end
      end
      return false
    end,
    param = {
      type = "table",
      fields = {
        {
          name = "abs_path",
          description = "Absolute path to the file in global scope",
          type = "string",
        },
        {
          name = "content",
          description = "Content to write to the file",
          type = "string",
        },
      },
      usage = {
        abs_path = "The path to the file in the current project scope",
        content = "The content to write to the file",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was written successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not written successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "move_path",
    description = [[Moves or rename a file or directory in the project, and returns confirmation that the move succeeded.
If the source and destination directories are the same, but the filename is different, this performs a rename. Otherwise, it performs a move.

This tool should be used when it's desirable to move or rename a file or directory without changing its contents at all.]],
    param = {
      type = "table",
      fields = {
        {
          name = "source_path",
          description = [[The source path of the file or directory to move/rename.

<example>
If the project has the following files:

- directory1/a/something.txt
- directory2/a/things.txt
- directory3/a/other.txt

You can move the first file by providing a source_path of "directory1/a/something.txt"
</example>]],
          type = "string",
        },
        {
          name = "destination_path",
          description = [[The destination path where the file or directory should be moved/renamed to. If the paths are the same except for the filename, then this will be a rename.

<example>
To move "directory1/a/something.txt" to "directory2/b/renamed.txt", provide a destination_path of "directory2/b/renamed.txt"
</example>]],
          type = "string",
        },
      },
      usage = {
        source_path = "The source path of the file or directory to move/rename",
        destination_path = "The destination path where the file or directory should be moved/renamed to",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was renamed successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not renamed successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "copy_path",
    description = [[Copies a file or directory from the project to a new location, and returns confirmation that the copy succeeded.

This tool should be used when it's desirable to copy a file or directory without changing its contents at all.]],
    param = {
      type = "table",
      fields = {
        {
          name = "source_path",
          description = [[The source path of the file or directory to copy.

<example>
If the project has the following files:

- directory1/a/something.txt
- directory2/a/things.txt
- directory3/a/other.txt

You can copy the first file by providing a source_path of "directory1/a/something.txt"
</example>]],
          type = "string",
        },
        {
          name = "destination_path",
          description = [[The destination path where the file or directory should be copied to.

<example>
To copy "directory1/a/something.txt" to "directory2/b/copied.txt", provide a destination_path of "directory2/b/copied.txt"
</example>]],
          type = "string",
        },
      },
      usage = {
        source_path = "The source path of the file or directory to copy",
        destination_path = "The destination path where the file or directory should be copied to",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was copied successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not copied successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "delete_path",
    description = "Deletes the file or directory (and the directory's contents, recursively) at the specified path in the project, and returns confirmation of the deletion.",
    param = {
      type = "table",
      fields = {
        {
          name = "path",
          description = [[The path of the file or directory to delete.
<example>
If the project has the following files:

- directory1/a/something.txt
- directory2/a/things.txt
- directory3/a/other.txt

You can delete the first file by providing a path of "directory1/a/something.txt"
</example>
          ]],
          type = "string",
        },
      },
      usage = {
        path = "Relative path to the file or directory in the current project scope",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was deleted successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not deleted successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "create_dir",
    description = "Create a new directory in current project scope",
    param = {
      type = "table",
      fields = {
        {
          name = "path",
          description = "Relative path to the project directory",
          type = "string",
        },
      },
      usage = {
        path = "Relative path to the project directory",
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the directory was created successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the directory was not created successfully",
        type = "string",
        optional = true,
      },
    },
  },
  require("avante.llm_tools.think"),
  require("avante.llm_tools.get_diagnostics"),
  require("avante.llm_tools.bash"),
  require("avante.llm_tools.attempt_completion"),
  require("avante.llm_tools.edit_file"),
  {
    name = "web_search",
    description = "Search the web",
    param = {
      type = "table",
      fields = {
        {
          name = "query",
          description = "Query to search",
          type = "string",
        },
      },
      usage = {
        query = "Query to search",
      },
    },
    returns = {
      {
        name = "result",
        description = "Result of the search",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the search was not successful",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "fetch",
    description = "Fetch markdown from a url",
    param = {
      type = "table",
      fields = {
        {
          name = "url",
          description = "Url to fetch markdown from",
          type = "string",
        },
      },
      usage = {
        url = "Url to fetch markdown from",
      },
    },
    returns = {
      {
        name = "result",
        description = "Result of the fetch",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the fetch was not successful",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "read_definitions",
    description = "Retrieves the complete source code definitions of any symbol (function, type, constant, etc.) from your codebase.",
    param = {
      type = "table",
      fields = {
        {
          name = "symbol_name",
          description = "The name of the symbol to retrieve the definition for",
          type = "string",
        },
        {
          name = "show_line_numbers",
          description = "Whether to show line numbers in the definitions",
          type = "boolean",
          default = false,
        },
      },
      usage = {
        symbol_name = "The name of the symbol to retrieve the definition for, example: fibonacci",
        show_line_numbers = "true or false",
      },
    },
    returns = {
      {
        name = "definitions",
        description = "The source code definitions of the symbol",
        type = "string[]",
      },
      {
        name = "error",
        description = "Error message if the definition retrieval failed",
        type = "string",
        optional = true,
      },
    },
    func = function(input, opts)
      local on_log = opts.on_log
      local on_complete = opts.on_complete
      local symbol_name = input.symbol_name
      local show_line_numbers = input.show_line_numbers
      if on_log then on_log("symbol_name: " .. vim.inspect(symbol_name)) end
      if on_log then on_log("show_line_numbers: " .. vim.inspect(show_line_numbers)) end
      if not symbol_name then return nil, "No symbol name provided" end
      local sidebar = require("avante").get()
      if not sidebar then return nil, "No sidebar" end
      local bufnr = sidebar.code.bufnr
      if not bufnr then return nil, "No bufnr" end
      if not vim.api.nvim_buf_is_valid(bufnr) then return nil, "Invalid bufnr" end
      if on_log then on_log("bufnr: " .. vim.inspect(bufnr)) end
      Utils.lsp.read_definitions(bufnr, symbol_name, show_line_numbers, function(definitions, error)
        local encoded_defs = vim.json.encode(definitions)
        on_complete(encoded_defs, error)
      end)
      return nil, nil
    end,
  },
}

--- compatibility alias for old calls & tests
M.run_python = M.python

---@class avante.ProcessToolUseOpts
---@field session_ctx table
---@field on_log? fun(tool_id: string, tool_name: string, log: string, state: AvanteLLMToolUseState): nil
---@field set_tool_use_store? fun(tool_id: string, key: string, value: any): nil
---@field on_complete? fun(result: string | nil, error: string | nil): nil

---@param tools AvanteLLMTool[]
---@param tool_use AvanteLLMToolUse
---@return string | nil result
---@return string | nil error
function M.process_tool_use(tools, tool_use, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  -- Check if execution is already cancelled
  if Helpers.is_cancelled then
    Utils.debug("Tool execution cancelled before starting: " .. tool_use.name)
    if on_complete then
      on_complete(nil, Helpers.CANCEL_TOKEN)
      return
    end
    return nil, Helpers.CANCEL_TOKEN
  end

  local func
  if tool_use.name == "str_replace_editor" then
    func = M.str_replace_editor
  elseif tool_use.name == "str_replace_based_edit_tool" then
    func = M.str_replace_based_edit_tool
  else
    ---@type AvanteLLMTool?
    local tool = vim.iter(tools):find(function(tool) return tool.name == tool_use.name end) ---@param tool AvanteLLMTool
    if tool == nil then return nil, "This tool is not provided: " .. vim.inspect(tool_use.name) end
    func = tool.func or M[tool.name]
  end
  local input_json = tool_use.input
  if not func then return nil, "Tool not found: " .. tool_use.name end
  if on_log then on_log(tool_use.id, tool_use.name, "running tool", "running") end

  -- Set up a timer to periodically check for cancellation
  local cancel_timer
  if on_complete then
    cancel_timer = vim.uv.new_timer()
    if cancel_timer then
      cancel_timer:start(
        100,
        100,
        vim.schedule_wrap(function()
          if Helpers.is_cancelled then
            Utils.debug("Tool execution cancelled during execution: " .. tool_use.name)
            if cancel_timer and not cancel_timer:is_closing() then
              cancel_timer:stop()
              cancel_timer:close()
            end
            Helpers.is_cancelled = false
            on_complete(nil, Helpers.CANCEL_TOKEN)
          end
        end)
      )
    end
  end

  ---@param result string | nil | boolean
  ---@param err string | nil
  local function handle_result(result, err)
    -- Stop the cancellation timer if it exists
    if cancel_timer and not cancel_timer:is_closing() then
      cancel_timer:stop()
      cancel_timer:close()
    end

    -- Check for cancellation one more time before processing result
    if Helpers.is_cancelled then
      if on_log then on_log(tool_use.id, tool_use.name, "cancelled during result handling", "failed") end
      return nil, Helpers.CANCEL_TOKEN
    end

    if err ~= nil then
      if on_log then on_log(tool_use.id, tool_use.name, "Error: " .. err, "failed") end
    else
      if on_log then on_log(tool_use.id, tool_use.name, "tool finished", "succeeded") end
    end
    local result_str ---@type string?
    if type(result) == "string" then
      result_str = result
    elseif result ~= nil then
      result_str = vim.json.encode(result)
    end
    return result_str, err
  end

  local result, err = func(input_json, {
    session_ctx = opts.session_ctx or {},
    on_log = function(log)
      -- Check for cancellation during logging
      if Helpers.is_cancelled then return end
      if on_log then on_log(tool_use.id, tool_use.name, log, "running") end
    end,
    set_store = function(key, value)
      if opts.set_tool_use_store then opts.set_tool_use_store(tool_use.id, key, value) end
    end,
    on_complete = function(result, err)
      -- Check for cancellation before completing
      if Helpers.is_cancelled then
        Helpers.is_cancelled = false
        if on_complete then on_complete(nil, Helpers.CANCEL_TOKEN) end
        return
      end

      result, err = handle_result(result, err)
      if on_complete == nil then
        Utils.error("asynchronous tool " .. tool_use.name .. " result not handled")
        return
      end
      on_complete(result, err)
    end,
    streaming = opts.streaming,
    tool_use_id = opts.tool_use_id,
  })

  -- Result and error being nil means that the tool was executed asynchronously
  if result == nil and err == nil and on_complete then return end
  return handle_result(result, err)
end

---@param tool_use AvanteLLMToolUse
---@return string
function M.stringify_tool_use(tool_use)
  local s = string.format("`%s`", tool_use.name)
  return s
end

return M
