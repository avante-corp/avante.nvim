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
---       host_mount = os.getenv("HOME"),
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
---       docker_extra_args = "",
---     },
---   })
---<
---
--- The RAG service lives in py/rag-service and be run via `uv run`.
--- `nix build .#ragService` will also give you the "avante-rag-service" executable.
---
--- You can change the list of ignored files in the "$XDG_CONFIG_HOME/avante/rag-ignore" file.
---
--- OUTDATED DOCKER SPECIFIC COMMENTS:
--- there was a docker build that is now outdated. It could be fixed if someone needs it
--- The `host_mount` path is mounted read-only into the service container.
--- After changing RAG configuration, remove the old container so the new configuration is used:
--->
---   docker rm -fv avante-rag-service
---<
---Communication port is (for now) hardcoded to localhost:20250
---@brief ]]

local curl = require("plenary.curl")
local Path = require("plenary.path")
local Config = require("avante.config")
local Utils = require("avante.utils")

local M = {}

local container_name = "avante-rag-service"
local service_path = "/tmp/" .. container_name

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
    M.launch_rag_service(add_resource_with_delay)
  end)
end

---@brief Return the docker image full name
---It is OUTDATED. If you need to use the docker image plea
function M.get_rag_service_image()
  if Config.rag_service and Config.rag_service.image then
    return Config.rag_service.image
  else
    return "quay.io/yetoneful/avante-rag-service:0.0.11"
  end
end

function M.get_rag_service_port() return 20250 end

function M.get_rag_service_url() return string.format("http://localhost:%d", M.get_rag_service_port()) end

function M.get_data_path()
  local p = Path:new(vim.fn.stdpath("data")):joinpath("avante/rag_service")
  if not p:exists() then p:mkdir({ parents = true }) end
  return p
end

function M.get_current_image()
  local cmd = { "docker", "inspect", "--format", "{{.Config.Image}}", container_name }
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 or result.stdout == "" then return nil end
  return result.stdout
end

function M.get_rag_service_runner() return (Config.rag_service and Config.rag_service.runner) or "docker" end

---Attempts to start the service regardless of its current status.
---Wrap it with `M.is_ready` to check beforehand it's already started or call
---Call `M.run_rag_service` that does it for you
---@see M.run_rag_service
---@param cb fun() called after the service started
function M.launch_rag_service(cb)
  --- If Config.rag_service.llm.api_key is nil or empty, llm_api_key will be an empty string.
  local llm_api_key = ""
  if
    Config.rag_service
    and Config.rag_service.llm
    and Config.rag_service.llm.api_key
    and Config.rag_service.llm.api_key ~= ""
  then
    llm_api_key = os.getenv(Config.rag_service.llm.api_key) or ""
    if llm_api_key == nil or llm_api_key == "" then
      error(string.format("cannot launch avante rag service, %s is not set", Config.rag_service.llm.api_key))
      return
    end
  end

  --- If Config.rag_service.embed.api_key is nil or empty, embed_api_key will be an empty string.
  local embed_api_key = ""
  if
    Config.rag_service
    and Config.rag_service.embed
    and Config.rag_service.embed.api_key
    and Config.rag_service.embed.api_key ~= ""
  then
    embed_api_key = os.getenv(Config.rag_service.embed.api_key) or ""
    if embed_api_key == nil or embed_api_key == "" then
      error(string.format("cannot launch avante rag service, %s is not set", Config.rag_service.embed.api_key))
      return
    end
  end

  local embed_extra = "{}" -- Default to empty JSON object string
  if Config.rag_service and Config.rag_service.embed and Config.rag_service.embed.extra then
    embed_extra = string.format("%q", vim.json.encode(Config.rag_service.embed.extra))
  end

  local llm_extra = "{}" -- Default to empty JSON object string
  if Config.rag_service and Config.rag_service.llm and Config.rag_service.llm.extra then
    llm_extra = string.format("%q", vim.json.encode(Config.rag_service.llm.extra))
  end

  local port = M.get_rag_service_port()

  if M.get_rag_service_runner() == "docker" then
    local image = M.get_rag_service_image()
    local data_path = M.get_data_path()
    local cmd = { "docker", "inspect", "--format", "{{.State.Status}}", container_name }
    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then Utils.debug(string.format("cmd: %s execution error", table.concat(cmd, " "))) end
    if result.stdout == "" then
      Utils.debug(string.format("container %s not found, starting...", container_name))
    elseif result.stdout == "running" then
      Utils.debug(string.format("container %s already running", container_name))
      local current_image = M.get_current_image()
      if current_image == image then
        cb()
        return
      end
      Utils.debug(
        string.format(
          "container %s is running with different image: %s != %s, stopping...",
          container_name,
          current_image,
          image
        )
      )
      M.stop_rag_service()
    end
    if result.stdout ~= "running" then
      Utils.info(string.format("container %s already started but not running, stopping...", container_name))
      M.stop_rag_service()
    end
    local cmd_ = string.format(
      "docker run --platform=linux/amd64 -d -p 0.0.0.0:%d:%d --name %s -v %s:/data -v %s:/host:ro -e ALLOW_RESET=TRUE -e DATA_DIR=/data -e RAG_EMBED_PROVIDER=%s -e RAG_EMBED_ENDPOINT=%s -e RAG_EMBED_API_KEY=%s -e RAG_EMBED_MODEL=%s -e RAG_EMBED_EXTRA=%s -e RAG_LLM_PROVIDER=%s -e RAG_LLM_ENDPOINT=%s -e RAG_LLM_API_KEY=%s -e RAG_LLM_MODEL=%s -e RAG_LLM_EXTRA=%s %s %s",
      M.get_rag_service_port(),
      M.get_rag_service_port(),
      container_name,
      data_path,
      Config.rag_service.host_mount,
      Config.rag_service.embed.provider,
      Config.rag_service.embed.endpoint,
      embed_api_key,
      Config.rag_service.embed.model,
      embed_extra,
      Config.rag_service.llm.provider,
      Config.rag_service.llm.endpoint,
      llm_api_key,
      Config.rag_service.llm.model,
      llm_extra,
      Config.rag_service.docker_extra_args,
      image
    )
    vim.fn.jobstart(cmd_, {
      detach = true,
      on_exit = function(_, exit_code)
        if exit_code ~= 0 then
          Utils.error(string.format("container %s failed to start, exit code: %d", container_name, exit_code))
        else
          Utils.debug(string.format("container %s started", container_name))
          cb()
        end
      end,
    })
  elseif M.get_rag_service_runner() == "nix" then
    -- Check if service is already running
    -- check if there is a process having "service_path" in its invokation
    Utils.debug(string.format("launching %s with nix...", container_name))

    -- can be launched beforehand via "uv run"
    local args = {
      "avante-rag-service",
      service_path,
      "--port",
      port,
      "--embed-provider",
      Config.rag_service.embed.provider,
      "--embed-extra",
      embed_extra,
      "--llm-provider",
      Config.rag_service.llm.provider,
      "--llm-model",
      Config.rag_service.llm.model,
    }
    Utils.info("Starting rag service with: " .. table.concat(args, " "))
    local ok, job_or_err = pcall(vim.system, args, {
      detach = true,
      env = {
        DATA_DIR = service_path,
        RAG_EMBED_ENDPOINT = Config.rag_service.embed.endpoint,
        RAG_EMBED_API_KEY = embed_api_key,
        RAG_EMBED_MODEL = Config.rag_service.embed.model,
        RAG_LLM_ENDPOINT = Config.rag_service.llm.endpoint,
        RAG_LLM_API_KEY = llm_api_key,
        RAG_LLM_EXTRA = llm_extra,
      },
    }, function(res)
      if res.code ~= 0 then
        Utils.error(string.format("service %s failed to start, exit code: %d", container_name, res.code))
      else
        Utils.info(string.format("RAG service %s started successfully", container_name))
        cb()
      end
    end)
    if not ok then
      Utils.error(
        "Could not launch 'avante-rag-service', you can install it via nix profile add github:avante-corp/avante.nvim#ragService. Error:\n"
          .. job_or_err
      )
    end
  end
end

function M.stop_rag_service()
  if M.get_rag_service_runner() == "docker" then
    local cmd = { "docker", "inspect", "--format", "{{.State.Status}}", container_name }
    local result = vim.system(cmd, { text = true }):wait().stdout
    if result ~= "" then vim.system({ "docker", "rm", "-fv", container_name }):wait() end
  else
    local pid = vim.system({ "pgrep", "-f", service_path }, { text = true }):wait().stdout
    if pid ~= "" then
      vim.system({ "kill", "-9", pid }):wait()
      Utils.debug(string.format("Attempted to kill processes related to %s", service_path))
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
  if runner == "nix" then return uri end
  local scheme = M.get_scheme(uri)
  if scheme == "file" then
    local path = uri:match("^file://(.*)$")
    local host_dir = Config.rag_service.host_mount
    if path:sub(1, #host_dir) == host_dir then path = "/host" .. path:sub(#host_dir + 1) end
    uri = string.format("file://%s", path)
  end
  return uri
end

function M.to_local_uri(uri)
  local scheme = M.get_scheme(uri)
  local path = uri:match("^file:///host(.*)$")

  if scheme == "file" and path ~= nil then
    local host_dir = Config.rag_service.host_mount
    local full_path = vim.fs.abspath(vim.fs.joinpath(host_dir, path:sub(2)))
    uri = string.format("file://%s", full_path)
  end

  return uri
end

---Checks http code when contacting server's /api/health
---@return boolean
function M.is_ready()
  return vim
    .system(
      { "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", M.get_rag_service_url() .. "/api/health" },
      { text = true }
    )
    :wait().code == 0
end

---@class AvanteRagServiceAddResourceResponse
---@field status string
---@field message string

---Add resource to database
---@param uri string CAREFUL: it is trailing slash sensitive (e.g. "file:///toto/")
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

---@param base_uri string
---@param query string
---@param on_complete fun(resp: AvanteRagServiceRetrieveResponse | nil, error: string | nil): nil
function M.retrieve(base_uri, query, on_complete)
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
    callback = function(resp)
      if resp.status ~= 200 then
        Utils.error("failed to retrieve: " .. resp.body)
        on_complete(nil, resp.body)
        return
      end
      local jsn = vim.json.decode(resp.body)
      jsn.sources = vim
        .iter(jsn.sources)
        :map(function(source)
          local uri = M.to_local_uri(source.uri)
          return vim.tbl_deep_extend("force", source, { uri = uri })
        end)
        :totable()
      Utils.debug("Sucessfully retreived rag answer")
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
