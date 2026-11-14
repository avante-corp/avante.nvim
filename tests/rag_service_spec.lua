local mock = require("luassert.mock")
local stub = require("luassert.stub")

describe("RagService", function()
  local RagService
  local Config_mock
  local stubs
  local previous_avante

  local function replace(target, key, implementation)
    local value = stub(target, key, implementation)
    table.insert(stubs, value)
    return value
  end

  before_each(function()
    previous_avante = vim.g.avante
    vim.g.avante = nil
    stubs = {}
    -- Load the module before each test
    RagService = require("avante.rag_service")

    -- Setup common mocks
    Config_mock = mock(require("avante.config"), true)
    Config_mock.rag_service = { host_mount = "/home/user" }
  end)

  after_each(function()
    vim.g.avante = previous_avante
    for i = #stubs, 1, -1 do
      stubs[i]:revert()
    end
    -- Clean up after each test
    package.loaded["avante.rag_service"] = nil
    mock.revert(Config_mock)
  end)

  describe("retrieval failures", function()
    local stub = require("luassert.stub")
    local curl
    before_each(function()
      curl = require("avante.utils.curl")
      stub(curl, "post")
    end)
    after_each(function() curl.post:revert() end)

    it("forwards transport errors to the caller", function()
      curl.post.invokes(function(_, opts) opts.on_error({ message = "connection refused" }) end)
      local callback = stub.new()
      RagService.retrieve("file:///home/user/", "question", callback)
      assert.stub(callback).was_called_with(nil, "connection refused")
    end)

    it("forwards HTTP errors and rejects malformed responses", function()
      for _, response in ipairs({
        { status = 503, body = "unavailable" },
        { status = 200, body = "not json" },
        { status = 200, body = "{}" },
      }) do
        curl.post.invokes(function(_, opts) opts.callback(response) end)
        local callback = stub.new()
        RagService.retrieve("file:///home/user/", "question", callback)
        assert.stub(callback).was_called_with(nil, response.status == 503 and "unavailable" or "Invalid RAG response")
      end
    end)
  end)

  describe("health checks", function()
    local stub = require("luassert.stub")
    after_each(function() vim.system:revert() end)

    it("requires HTTP 200 and a successful curl exit", function()
      local result = { code = 0, stdout = "200" }
      stub(vim, "system", function(args)
        assert.is_true(vim.tbl_contains(args, "--max-time"))
        return { wait = function() return result end }
      end)
      assert.is_true(RagService.is_ready())
      result = { code = 0, stdout = "503" }
      assert.is_false(RagService.is_ready())
      result = { code = 7, stdout = "000" }
      assert.is_false(RagService.is_ready())
    end)
  end)

  describe("URI conversion functions", function()
    it("should convert URIs between host and container formats", function()
      -- Test both directions of conversion
      local host_uri = "file:///home/user/project/file.txt"
      local container_uri = "file:///host/project/file.txt"

      -- Host to container
      local result1 = RagService.to_container_uri(host_uri)
      assert.equals(container_uri, result1)

      -- Container to host
      local result2 = RagService.to_local_uri(container_uri)
      assert.equals(host_uri, result2)
    end)
  end)

  describe("service URL", function()
    it("reads the global URL on each call rather than the merged config", function()
      Config_mock.rag_service.url = "http://localhost:7070"
      vim.g.avante = { rag_service = { url = "https://rag.example:8443/" } }
      assert.equals("https://rag.example:8443", RagService.get_rag_service_url())
      assert.equals(8443, RagService.get_rag_service_port())
      vim.g.avante = { rag_service = { url = "http://localhost:9090" } }
      assert.equals(9090, RagService.get_rag_service_port())
    end)

    it("uses the default when global RAG configuration is absent", function()
      for _, config in ipairs({ {}, { rag_service = {} } }) do
        vim.g.avante = config
        assert.equals("http://localhost:20250", RagService.get_rag_service_url())
        assert.equals(20250, RagService.get_rag_service_port())
      end
    end)

    it("preserves the default address and port", function()
      assert.equals("http://localhost:20250", RagService.get_rag_service_url())
      assert.equals(20250, RagService.get_rag_service_port())
    end)

    for _, case in ipairs({
      { "http://rag.example:8080", 8080 },
      { "https://rag.example:8443/base/", 8443 },
      { "http://rag.example", 80 },
      { "https://rag.example/base:9000", 443 },
      { "http://[::1]:9090", 9090 },
      { "https://[::1]/", 443 },
    }) do
      it("parses the port from " .. case[1], function()
        vim.g.avante = { rag_service = { url = case[1] } }
        assert.equals(case[2], RagService.get_rag_service_port())
        assert.equals(case[1]:gsub("/+$", ""), RagService.get_rag_service_url())
      end)
    end

    for _, url in ipairs({
      "localhost:20250",
      "ftp://host:21",
      "http://host:bad",
      "http://host:0",
      "http://host:65536",
    }) do
      it("rejects an invalid launch URL: " .. url, function()
        vim.g.avante = { rag_service = { url = url } }
        assert.has_error(function() RagService.get_rag_service_port() end)
      end)
    end

    it("uses the configured URL for health and resource requests", function()
      vim.g.avante = { rag_service = { url = "https://rag.example:8443/base/" } }
      local system = replace(vim, "system", function()
        return { wait = function() return { code = 0 } end }
      end)
      local get = replace(
        require("avante.utils.curl"),
        "get",
        function() return { status = 200, body = '{"resources":[],"total_count":0}' } end
      )
      RagService.is_ready()
      assert.stub(system).was_called_with({
        "curl",
        "-s",
        "--max-time",
        "2",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "https://rag.example:8443/base/api/health",
      }, { text = true })
      RagService.get_resources()
      assert.stub(get).was_called_with("https://rag.example:8443/base/api/v1/resources", {
        headers = { ["Content-Type"] = "application/json" },
      })
    end)
  end)

  describe("built-in runners", function()
    local errors
    before_each(function()
      Config_mock.rag_service = {
        runner = "native",
        llm = { provider = "openai", endpoint = "https://llm", api_key = "", model = "llm-model" },
        embed = { provider = "ollama", endpoint = "http://embed", api_key = "", model = "embed-model" },
      }
      local utils = require("avante.utils")
      replace(utils, "info", function() end)
      replace(utils, "debug", function() end)
      errors = replace(utils, "error", function() end)
    end)

    it("dispatches through the exported starter functions", function()
      for _, runner in ipairs({ "docker", "native" }) do
        Config_mock.rag_service.runner = runner
        local start = replace(RagService, "start_" .. runner, function() end)
        RagService.launch_rag_service()
        assert.stub(start).was_called_with(Config_mock.rag_service)
      end
    end)

    it("reports native spawn and process failures", function()
      local system = replace(vim, "system", function() error("executable missing") end)
      RagService.launch_rag_service()
      assert.stub(errors).was_called(1)
      system:revert()
      replace(vim, "system", function(_, _, on_exit) on_exit({ code = 7 }) end)
      RagService.launch_rag_service()
      assert.stub(errors).was_called_with("service avante-rag-service failed to start, exit code: 7")
    end)

    for _, runner in ipairs({ "docker", "native" }) do
      for _, model in ipairs({ "llm", "embed" }) do
        it("rejects missing " .. model .. " credentials for " .. runner, function()
          Config_mock.rag_service.runner = runner
          Config_mock.rag_service[model].api_key = "MISSING_KEY"
          replace(os, "getenv", function() return nil end)
          local system = replace(vim, "system", function() end)
          assert.has_error(
            function() RagService.launch_rag_service() end,
            "cannot launch avante rag service, MISSING_KEY is not set"
          )
          assert.stub(system).was_not_called()
        end)
      end
    end

    it("rejects unsupported runners", function()
      Config_mock.rag_service.runner = "unknown"
      assert.has_error(function() RagService.launch_rag_service() end, "Unsupported RAG service runner: unknown")
    end)
  end)
end)
