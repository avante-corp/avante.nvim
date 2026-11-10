---@mod avante-rag-service avante RAG service
---@brief [[
---
--- The Retrieval-Augmented Generation (RAG) vante service provides additional project context for AI responses.
--- It is a python chromadb-based server supports several providers like openai, ollama and so on.
--- When enabled, avante will automatically launch the service on your current project (It is disabled by default).
--- The service will scan in the background your project such that you can query it later.
---
--- You can list the provider by running `avante-rag-service --help`.
--- The service config
--->
---   vim.g.avante = {
---     rag_service = {
---       enabled = false,
---       url = "http://localhost:20250",
---       runner = "docker",
---       llm = {
---         provider = "openai",
---         endpoint = "https://api.openai.com/v1",
---         api_key = "OPENAI_API_KEY",
---         model = "gpt-4o-mini",
---         extra = nil,
---       },
---       embed = {
---         provider = "openai",
---         endpoint = "https://api.openai.com/v1",
---         api_key = "OPENAI_API_KEY",
---         model = "text-embedding-3-large",
---         extra = nil,
---       },
---     },
---   })
---<
---
--- The RAG service lives in py/rag-service and be run via `uv run`.
--- `nix build .#ragService` will also give you the "avante-rag-service" executable.
--- Set `runner = "native"` to use the native runner, which expects `avante-rag-service` in `PATH`.
---
--- `runner` also accepts a function receiving the merged RagService configuration.
--- Start the service asynchronously at the configured `url` and return; Avante polls readiness.
--- API key fields remain environment-variable names; custom runners validate their own credentials.
--- Custom runners use local file URIs. Stopping uses the existing process lookup for
--- `/tmp/avante-rag-service`, so include that data path in the process arguments.
--->
---   require("avante").setup({
---     rag_service = {
---       runner = function(config)
---         local port = require("avante.rag_service").get_rag_service_port()
---         vim.system({ "avante-rag-service", "/tmp/avante-rag-service", "--port", tostring(port),
---           "--llm-provider", config.llm.provider, "--embed-provider", config.embed.provider },
---           { detach = true })
---       end,
---     },
---   })
---<
---
--- You can change the list of ignored files in the "$XDG_CONFIG_HOME/avante/rag-ignore" file.
---
--- OUTDATED DOCKER SPECIFIC COMMENTS:
--- there was a docker build that is now outdated. It could be fixed if someone needs it
--- Docker mounts the home directory read-only into the service container.
--- `host_mount`, `image`, and `docker_extra_args` are deprecated; remove them from your config.
--- Existing values remain supported during the deprecation period.
--- After changing RAG configuration, remove the old container so the new configuration is used:
--->
---   docker rm -fv avante-rag-service
---<
--- `url` is the HTTP(S) base URL used for requests. Its port is used when launching the service.
--- Without an explicit port, HTTP uses 80 and HTTPS uses 443.
---@brief ]]

local curl = require("plenary.curl")
local Path = require("plenary.path")
local Config = require("avante.config")
local Utils = require("avante.utils")

local M = {}

local rag_exec = "avante-rag-service"

---Starts the rag service if not already running
--- and loads the current project into it
---@see launch_rag_service
function M.run_rag_service()
  local started_at = os.time()
  local add_resource_with_delay
  local function add_resource()
    if not M.is_ready() then
      local elapsed = os.time() - started_at
      if elapsed > 1000 * 60 * 15 then
        Utils.warn("Rag Service is not ready, giving up")
        return
      end
      add_resource_with_delay()
      return
    end
    vim.defer_fn(function()
      Utils.info("Adding project root to Rag Service ...")
      local uri = "file://" .. Utils.get_project_root()
      if uri:sub(-1) ~= "/" then uri = uri .. "/" end
      M.add_resource(uri)
    end, 5000)
  end
  add_resource_with_delay = function()
    vim.defer_fn(function() add_resource() end, 5000)
  end
  vim.schedule(function()
    Utils.info("Starting Rag Service ...")
    M.launch_rag_service()
    add_resource_with_delay()
  end)
end

---Return vim.g.avante.rag_service.url without trailing slashes, defaulting to http://localhost:20250.
---@return string
function M.get_rag_service_url()
  local config = (vim.g.avante or {}).rag_service or {}
  local url = config.url or "http://localhost:20250"
  return (url:gsub("/+$", ""))
end

---Return the URL port, or the standard HTTP/HTTPS port when omitted.
---@return integer
function M.get_rag_service_port()
  local url = M.get_rag_service_url()
  local scheme, authority = url:match("^([%a][%w+.-]*)://([^/?#]+)")
  scheme = scheme and scheme:lower()
  if not authority or (scheme ~= "http" and scheme ~= "https") then error("rag_service.url must be an HTTP(S) URL") end
  authority = authority:gsub("^.*@", "")
  local host, suffix
  if authority:sub(1, 1) == "[" then
    host, suffix = authority:match("^(%[[^%]]+%])(.*)$")
  else
    host, suffix = authority:match("^([^:]+)(.*)$")
  end
  if not host or not suffix then error("rag_service.url must contain a valid host") end
  if suffix == "" then return scheme == "https" and 443 or 80 end
  local port = tonumber(suffix:match("^:(%d+)$"))
  if not port or port < 1 or port > 65535 then error("rag_service.url port must be an integer between 1 and 65535") end
  return port
end

function M.get_data_path()
  local p = Path:new(vim.fn.stdpath("data")):joinpath("avante/rag_service")
  if not p:exists() then p:mkdir({ parents = true }) end
  return p
end

function M.get_rag_service_runner() return (Config.rag_service and Config.rag_service.runner) or "docker" end

---@param model avante.Config.RagServiceModel
---@return string api_key
---@return string extra
local function model_options(model)
  local api_key = ""
  if model.api_key and model.api_key ~= "" then
    api_key = os.getenv(model.api_key) or ""
    if api_key == "" then error(string.format("cannot launch avante rag service, %s is not set", model.api_key)) end
  end
  local extra = model.extra and string.format("%q", vim.json.encode(model.extra)) or "{}"
  return api_key, extra
end

---@class avante.RagServiceDockerOptions
---@field host_mount? string Host path mounted read-only at /host.
---@field docker_extra_args? string Extra arguments passed to docker run.

local function get_current_image()
  local cmd = { "docker", "inspect", "--format", "{{.Config.Image}}", rag_exec }
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 or result.stdout == "" then return nil end
  return result.stdout
end

---Start the RAG service via Docker. Explicit options override deprecated config values.
---@param config avante.Config.RagService
---@param opts? avante.RagServiceDockerOptions Defaults to legacy config values, then HOME and no extra arguments.
function M.start_docker(config, opts)
  opts = opts or {}
  local llm_api_key, llm_extra = model_options(config.llm)
  local embed_api_key, embed_extra = model_options(config.embed)
  local image = rawget(config, "image") or "quay.io/yetoneful/avante-rag-service:0.0.11"
  local data_path = M.get_data_path()
  local cmd = { "docker", "inspect", "--format", "{{.State.Status}}", rag_exec }
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then Utils.debug(string.format("cmd: %s execution error", table.concat(cmd, " "))) end
  if result.stdout == "" then
    Utils.debug(string.format("container %s not found, starting...", rag_exec))
  elseif result.stdout == "running" then
    Utils.debug(string.format("container %s already running", rag_exec))
    local current_image = get_current_image()
    if current_image == image then return end
    Utils.debug(
      string.format(
        "container %s is running with different image: %s != %s, stopping...",
        rag_exec,
        current_image,
        image
      )
    )
    M.stop_rag_service()
  end
  if result.stdout ~= "running" then
    Utils.info(string.format("container %s already started but not running, stopping...", rag_exec))
    M.stop_rag_service()
  end
  local cmd_ = string.format(
    "docker run --platform=linux/amd64 -d -p 0.0.0.0:%d:%d --name %s -v %s:/data -v %s:/host:ro -e ALLOW_RESET=TRUE -e DATA_DIR=/data -e RAG_EMBED_PROVIDER=%s -e RAG_EMBED_ENDPOINT=%s -e RAG_EMBED_API_KEY=%s -e RAG_EMBED_MODEL=%s -e RAG_EMBED_EXTRA=%s -e RAG_LLM_PROVIDER=%s -e RAG_LLM_ENDPOINT=%s -e RAG_LLM_API_KEY=%s -e RAG_LLM_MODEL=%s -e RAG_LLM_EXTRA=%s %s %s",
    M.get_rag_service_port(),
    20250, -- The Docker image listens on its default internal port.
    rag_exec,
    data_path,
    opts.host_mount or rawget(config, "host_mount") or assert(os.getenv("HOME"), "HOME is not set"),
    config.embed.provider,
    config.embed.endpoint,
    embed_api_key,
    config.embed.model,
    embed_extra,
    config.llm.provider,
    config.llm.endpoint,
    llm_api_key,
    config.llm.model,
    llm_extra,
    opts.docker_extra_args or rawget(config, "docker_extra_args") or "",
    image
  )
  vim.fn.jobstart(cmd_, {
    detach = true,
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        Utils.error(string.format("container %s failed to start, exit code: %d", rag_exec, exit_code))
      else
        Utils.debug(string.format("container %s started", rag_exec))
      end
    end,
  })
end

---Start the RAG service using the avante-rag-service executable in PATH.
---@param config avante.Config.RagService
function M.start_native(config)
  local llm_api_key, llm_extra = model_options(config.llm)
  local embed_api_key, embed_extra = model_options(config.embed)
  Utils.debug(string.format("launching %s with native runner...", rag_exec))

  -- can be launched beforehand via "uv run"
  local args = {
    "avante-rag-service",
    "--port",
    M.get_rag_service_port(),
    "--embed-provider",
    config.embed.provider,
    "--embed-extra",
    embed_extra,
    "--llm-provider",
    config.llm.provider,
    "--llm-model",
    config.llm.model,
  }
  Utils.info("Starting rag service with: " .. table.concat(args, " "))
  local ok, job_or_err = pcall(vim.system, args, {
    detach = true,
    env = {
      RAG_EMBED_API_KEY = embed_api_key,
      RAG_LLM_API_KEY = llm_api_key,
      RAG_LLM_EXTRA = llm_extra,
    },
  }, function(res)
    if res.code ~= 0 then
      Utils.error(string.format("service %s failed to start, exit code: %d", rag_exec, res.code))
    else
      Utils.info(string.format("RAG service %s started successfully", rag_exec))
    end
  end)
  if not ok then
    Utils.error([[
      Could not launch 'avante-rag-service'. The native runner expects this executable in PATH.
      you can install it via "nix profile add github:avante-corp/avante.nvim#ragService" or with "uv".
      Error:\n]] .. job_or_err)
  end
end

---Attempts to start the service regardless of its current status.
---Call `M.run_rag_service` to also poll readiness and register the project.
---@see M.run_rag_service
function M.launch_rag_service()
  local runners = { docker = M.start_docker, native = M.start_native }
  local runner = M.get_rag_service_runner()
  local start = type(runner) == "function" and runner or runners[runner]
  if not start then error(string.format("Unsupported RAG service runner: %s", tostring(runner))) end
  start(Config.rag_service)
end

--- Stop the service. It is not reliable at the moment so you might need to kill
--- the process yourself
function M.stop_rag_service()
  if M.get_rag_service_runner() == "docker" then
    local cmd = { "docker", "inspect", "--format", "{{.State.Status}}", rag_exec }
    local result = vim.system(cmd, { text = true }):wait().stdout
    if result ~= "" then vim.system({ "docker", "rm", "-fv", rag_exec }):wait() end
  else
    -- TODO search process by port instead
    local pid = vim.system({ "pgrep", "-f", rag_exec }, { text = true }):wait().stdout
    if pid ~= "" then
      vim.system({ "kill", "-9", pid }):wait()
      Utils.debug(string.format("Attempted to kill processes related to %s", rag_exec))
    end
  end
end

--- http or https
function M.get_scheme(uri)
  local scheme = uri:match("^(%w+)://")
  if scheme == nil then return "unknown" end
  return scheme
end

---Transforms URI when used with docker
function M.to_container_uri(uri)
  local runner = M.get_rag_service_runner()
  if runner ~= "docker" then return uri end
  local scheme = M.get_scheme(uri)
  if scheme == "file" then
    local path = uri:match("^file://(.*)$")
    local host_dir = rawget(Config.rag_service or {}, "host_mount") or assert(os.getenv("HOME"), "HOME is not set")
    if path:sub(1, #host_dir) == host_dir then path = "/host" .. path:sub(#host_dir + 1) end
    uri = string.format("file://%s", path)
  end
  return uri
end

---Transforms URI when used with docker
function M.to_local_uri(uri)
  if M.get_rag_service_runner() ~= "docker" then return uri end
  local scheme = M.get_scheme(uri)
  local path = uri:match("^file:///host(.*)$")

  if scheme == "file" and path ~= nil then
    local host_dir = rawget(Config.rag_service or {}, "host_mount") or assert(os.getenv("HOME"), "HOME is not set")
    local full_path = vim.fs.abspath(vim.fs.joinpath(host_dir, path:sub(2)))
    uri = string.format("file://%s", full_path)
  end

  return uri
end

---Checks http code when contacting server's /api/health
---@return boolean
function M.is_ready()
  local result = vim
    .system({
      "curl",
      "-s",
      "--max-time",
      "2",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      M.get_rag_service_url() .. "/api/health",
    }, { text = true })
    :wait()
  return result.code == 0 and vim.trim(result.stdout or "") == "200"
end

---@class AvanteRagServiceAddResourceResponse
---@field status string
---@field message string

---Add resource to database
---@param uri string CAREFUL: it is trailing slash sensitive (e.g. "file:///toto/")
---@return nil
function M.add_resource(uri)
  uri = M.to_container_uri(uri)
  local resource_name = uri:match("([^/]+)/$")
  local resources_resp = M.get_resources()
  if resources_resp == nil then
    Utils.error("Failed to get resources")
    return nil
  end
  local already_added = false
  for _, resource in ipairs(resources_resp.resources) do
    if resource.uri == uri then
      already_added = true
      resource_name = resource.name
      break
    end
  end
  if not already_added then
    local names_map = {}
    for _, resource in ipairs(resources_resp.resources) do
      names_map[resource.name] = true
    end
    if names_map[resource_name] then
      for i = 1, 100 do
        local resource_name_ = string.format("%s-%d", resource_name, i)
        if not names_map[resource_name_] then
          resource_name = resource_name_
          break
        end
      end
      if names_map[resource_name] then
        Utils.error(string.format("Failed to add resource, name conflict: %s", resource_name))
        return nil
      end
    end
  end
  local payload = vim.json.encode({ name = resource_name, uri = uri })
  local url = M.get_rag_service_url() .. "/api/v1/add_resource"

  Utils.debug("Sending payload to " .. url .. ": %s", payload)
  local cmd = {
    "curl",
    "-X",
    "POST",
    url,
    "-H",
    "Content-Type: application/json",
    "-d",
    payload,
  }
  vim.system(cmd, { text = true }, function(output)
    if output.code == 0 then
      Utils.debug(string.format("Added resource: %s", uri))
    else
      Utils.error(string.format("Failed to add resource: %s; output: %s", uri, output.stderr))
    end
  end)
end

function M.remove_resource(uri)
  uri = M.to_container_uri(uri)
  local resp = curl.post(M.get_rag_service_url() .. "/api/v1/remove_resource", {
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = vim.json.encode({
      uri = uri,
    }),
  })
  if resp.status ~= 200 then
    Utils.error("failed to remove resource: " .. resp.body)
    return
  end
  return vim.json.decode(resp.body)
end

---@class AvanteRagServiceRetrieveSource
---@field uri string
---@field content string

---@class AvanteRagServiceRetrieveResponse
---@field response string
---@field sources AvanteRagServiceRetrieveSource[]

---@param base_uri string e.g. "file:///home/USER/plugins/avante.nvim/"
---@param query string Your question e.g., "What's the average life expectancy in Ireland ?"
---@param on_complete fun(resp: AvanteRagServiceRetrieveResponse | nil, error: string | nil): nil
function M.retrieve(base_uri, query, on_complete)
  -- TODO make timeout configurable
  base_uri = M.to_container_uri(base_uri)
  curl.post(M.get_rag_service_url() .. "/api/v1/retrieve", {
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = vim.json.encode({
      base_uri = base_uri,
      query = query,
      top_k = 10,
    }),
    timeout = 100000,
    on_error = function(err) on_complete(nil, err.message) end,
    callback = function(resp)
      if resp.status ~= 200 then
        on_complete(nil, resp.body)
        return
      end
      local ok, jsn = pcall(vim.json.decode, resp.body)
      if not ok or type(jsn) ~= "table" or type(jsn.response) ~= "string" or type(jsn.sources) ~= "table" then
        on_complete(nil, "Invalid RAG response")
        return
      end
      jsn.sources = vim
        .iter(jsn.sources)
        :map(function(source)
          local uri = M.to_local_uri(source.uri)
          return vim.tbl_deep_extend("force", source, { uri = uri })
        end)
        :totable()
      Utils.debug("Successfully retrieved rag answer")
      on_complete(jsn, nil)
    end,
  })
end

---@class AvanteRagServiceIndexingStatusSummary
---@field indexing integer
---@field completed integer
---@field failed integer

---@class AvanteRagServiceIndexingStatusResponse
---@field uri string
---@field is_watched boolean
---@field total_files integer
---@field status_summary AvanteRagServiceIndexingStatusSummary

---@param uri string e.g. "file:///home/USER/my-documentation"
---@return AvanteRagServiceIndexingStatusResponse | nil
function M.indexing_status(uri)
  uri = M.to_container_uri(uri)
  local url = M.get_rag_service_url() .. "/api/v1/indexing_status"
  local resp = curl.post(url, {
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = vim.json.encode({
      uri = uri,
    }),
  })
  Utils.debug("Asked indexing status at " .. url)
  if resp.status ~= 200 then
    Utils.error("Failed to get indexing status: " .. resp.body)
    return
  end
  local jsn = vim.json.decode(resp.body)
  jsn.uri = M.to_local_uri(jsn.uri)
  return jsn
end

---@class AvanteRagServiceResource
---@field name string
---@field uri string
---@field type string
---@field status string
---@field indexing_status string
---@field created_at string
---@field indexing_started_at string | nil
---@field last_indexed_at string | nil

---@class AvanteRagServiceResourceListResponse
---@field resources AvanteRagServiceResource[]
---@field total_count number

---@return AvanteRagServiceResourceListResponse | nil
function M.get_resources()
  local resp = curl.get(M.get_rag_service_url() .. "/api/v1/resources", {
    headers = {
      ["Content-Type"] = "application/json",
    },
  })
  if resp.status ~= 200 then
    Utils.error("Failed to get resources: " .. resp.body)
    return
  end
  local jsn = vim.json.decode(resp.body)
  jsn.resources = vim
    .iter(jsn.resources)
    :map(function(resource)
      local uri = M.to_local_uri(resource.uri)
      return vim.tbl_deep_extend("force", resource, { uri = uri })
    end)
    :totable()
  return jsn
end

return M
