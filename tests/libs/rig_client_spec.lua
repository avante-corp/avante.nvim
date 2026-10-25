local RigClient = require("avante.libs.rig_client")

describe("Rig client adapter", function()
  local function provider(name, inherited, overrides)
    return vim.tbl_extend("force", {
      _name = name,
      _protocol = inherited,
      model = "test-model",
      endpoint = "https://example.test/v1",
      parse_api_key = function() return "token" end,
    }, overrides or {})
  end

  it("passes semantic messages and custom parameters instead of a protocol body", function()
    local request = RigClient._build_request(
      provider("deepseek", "openai", {
        extra_request_body = { reasoning_context = { mode = "preserve" } },
        use_response_api = true,
      }),
      {
        system_prompt = "system",
        messages = { { role = "user", content = "hello" } },
      }
    )

    assert.same("deepseek", request.provider.name)
    assert.same("openai", request.provider.protocol)
    assert.same("responses", request.provider.route)
    assert.same("system", request.prompt.systemPrompt)
    assert.same({ { role = "user", content = "hello" } }, request.prompt.messages)
    assert.same({ reasoning_context = { mode = "preserve" } }, request.prompt.additionalParams)
    assert.is_nil(request.url)
    assert.is_nil(request.body)
  end)

  it("resolves a dynamic Responses route once per request", function()
    local calls = 0
    local request = RigClient._build_request(
      provider("openai", "openai", {
        dialect = "openai",
        use_response_api = function()
          calls = calls + 1
          return true
        end,
      }),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
    )

    assert.same("responses", request.provider.route)
    assert.same(1, calls)
  end)

  it("passes an inherited protocol with an explicit Rig dialect", function()
    local request = RigClient._build_request(
      provider("private_gateway", "openai", {
        dialect = "mistral",
        extra_request_body = { reasoning_context = "carry" },
      }),
      {
        system_prompt = "system",
        messages = { { role = "user", content = "hello" } },
      }
    )

    assert.same("private_gateway", request.provider.name)
    assert.same("openai", request.provider.protocol)
    assert.same("mistral", request.provider.dialect)
    assert.same("https://example.test/v1", request.provider.baseUrl)
    assert.same("carry", request.prompt.additionalParams.reasoning_context)
  end)

  describe("extra_headers callbacks", function()
    local loaded_native
    local header_queries

    before_each(function()
      loaded_native = package.loaded.avante_llm
      header_queries = 0
      package.loaded.avante_llm = {
        api_version = 2,
        request_headers = function(input)
          header_queries = header_queries + 1
          return {
            Authorization = "Bearer " .. input.provider.apiKey,
            ["Content-Type"] = "application/json",
            Accept = "text/event-stream",
          }
        end,
      }
    end)

    after_each(function() package.loaded.avante_llm = loaded_native end)

    it("provides default request headers to extra_headers callbacks", function()
      local defaults
      local callbacks = 0
      local request = RigClient._build_request(
        provider("private_gateway", "openai", {
          api_key_name = "TEST_KEY",
          extra_headers = function(headers)
            callbacks = callbacks + 1
            defaults = vim.deepcopy(headers)
            headers["X-Gateway-Auth"] = headers.Authorization
            return headers
          end,
        }),
        { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
      )

      assert.same("Bearer token", defaults.Authorization)
      assert.same("application/json", defaults["Content-Type"])
      assert.same("text/event-stream", defaults.Accept)
      assert.same("Bearer token", request.provider.headers["X-Gateway-Auth"])
      assert.same(1, callbacks)
      assert.same(1, header_queries)
      assert.is_true(request.provider.replaceHeaders)
    end)

    it("keeps changes to default request headers made by extra_headers callbacks", function()
      local original_auth
      local request = RigClient._build_request(
        provider("private_gateway", "openai", {
          api_key_name = "TEST_KEY",
          extra_headers = function(headers)
            original_auth = headers.Authorization
            headers.Authorization = "Gateway token"
            return headers
          end,
        }),
        { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
      )

      assert.same("Bearer token", original_auth)
      assert.same("Gateway token", request.provider.headers.Authorization)
      assert.is_true(request.provider.replaceHeaders)
    end)

    it("allows extra_headers callbacks to return a whitelist without default authentication", function()
      local request = RigClient._build_request(
        provider("public_gateway", "openai", {
          api_key_name = "TEST_KEY",
          extra_headers = function(headers) return { ["Content-Type"] = headers["Content-Type"] } end,
        }),
        { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
      )

      assert.same({ ["Content-Type"] = "application/json" }, request.provider.headers)
      assert.is_true(request.provider.replaceHeaders)
    end)
  end)

  it("uses the protocol for Azure-specific configuration", function()
    local request = RigClient._build_request(
      provider("private_azure", "azure", {
        deployment = "test-deployment",
        api_version = "2025-01-01-preview",
        entra = true,
      }),
      {
        system_prompt = "system",
        messages = { { role = "user", content = "hello" } },
      }
    )

    assert.same("private_azure", request.provider.name)
    assert.same("azure", request.provider.protocol)
    assert.same("bearer", request.provider.auth)
    assert.same("test-model", request.provider.model)
    assert.same("test-deployment", request.provider.deployment)
  end)

  it("keeps Azure configurations that only name a deployment working", function()
    local azure = provider("azure", "azure", { deployment = "test-deployment" })
    azure.model = nil
    local request = RigClient._build_request(azure, {
      system_prompt = "system",
      messages = { { role = "user", content = "hello" } },
    })
    assert.same("test-deployment", request.provider.model)
    assert.same("test-deployment", request.provider.deployment)
  end)

  it("rejects Azure configuration without a deployment", function()
    assert.has_error(
      function()
        RigClient._build_request(provider("azure", "azure", { deployment = "" }), {
          system_prompt = "system",
          messages = {},
        })
      end,
      "Azure deployment is not set"
    )
  end)

  it("honors both Copilot route overrides", function()
    for _, use_responses in ipairs({ true, false }) do
      local request = RigClient._build_request(
        provider("copilot", "copilot", {
          model = use_responses and "gpt-5" or "gpt-5-codex",
          use_response_api = use_responses,
          get_session_token = function() return { token = "session-token" } end,
        }),
        { system_prompt = "system", messages = {} }
      )
      assert.same(use_responses and "responses" or "chat", request.provider.route)
    end
  end)

  it("reads Copilot tokens from the live module after the provider is copied", function()
    local Config = require("avante.config")
    if not Config.providers then Config.setup({}) end
    local Providers = require("avante.providers")
    local Copilot = require("avante.providers.copilot")
    local saved_provider, saved_state = rawget(Providers, "copilot"), Copilot.state
    Copilot.state = nil
    Providers.copilot = nil
    local copied = Providers.copilot
    local ok, err = pcall(function()
      for _, token in ipairs({ "first-session", "refreshed-session" }) do
        Copilot.state = {
          github_token = {
            token = token,
            expires_at = os.time() + 3600,
            endpoints = { api = "https://session.example.test" },
          },
        }
        local request = RigClient._build_request(copied, { system_prompt = "system", messages = {} })
        assert.same(token, request.provider.apiKey)
        assert.same("https://session.example.test", request.provider.baseUrl)
      end
    end)
    Providers.copilot, Copilot.state = saved_provider, saved_state
    assert.is_true(ok, err)
  end)

  it("converts Avante tools to Rig tool definitions", function()
    local request = RigClient._build_request(provider("openai", "openai"), {
      system_prompt = "system",
      messages = { { role = "user", content = "hello" } },
      tools = {
        {
          name = "read_file",
          get_description = function() return "Read a file" end,
          param = {
            fields = {
              { name = "path", type = "string", description = "Path", optional = false },
            },
          },
        },
      },
    })

    assert.same("read_file", request.prompt.tools[1].name)
    assert.same("Read a file", request.prompt.tools[1].description)
    assert.same("object", request.prompt.tools[1].parameters.type)
    assert.same({ "path" }, request.prompt.tools[1].parameters.required)
  end)

  it("uses Rig provider identities for SDK-backed providers", function()
    local bedrock = RigClient._build_request(
      provider("bedrock", "bedrock", {
        endpoint = nil,
        aws_region = "us-east-1",
        aws_profile = "work",
        parse_api_key = function() return nil end,
      }),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } }
    )

    assert.same("bedrock", bedrock.provider.name)
    assert.same("bedrock", bedrock.provider.protocol)
    assert.same("work", bedrock.provider.bedrock.profile)
    assert.same("us-east-1", bedrock.provider.bedrock.region)
  end)

  it("uses native tools for Ollama", function()
    local ollama = provider("ollama", "ollama", {
      parse_api_key = function() return nil end,
      keep_alive = "10m",
      extra_request_body = {
        options = { temperature = 0.75, keep_alive = "5m" },
      },
    })
    local request = RigClient._build_request(ollama, {
      system_prompt = "system",
      messages = { { role = "user", content = "hello" } },
      tools = {
        {
          name = "read_file",
          description = "Read a file",
          param = { fields = {} },
        },
      },
    })

    assert.same("system", request.prompt.systemPrompt)
    assert.is_string(request.prompt.turnId)
    assert.same("read_file", request.prompt.tools[1].name)
    assert.same("10m", request.prompt.additionalParams.keep_alive)
    assert.is_nil(request.prompt.additionalParams.options.keep_alive)
    assert.same("5m", ollama.extra_request_body.options.keep_alive)
  end)

  it("updates streaming tool calls from partial argument events", function()
    local loaded_native = package.loaded.avante_llm
    local first_poll = true
    package.loaded.avante_llm = {
      api_version = 2,
      start = function()
        return {
          poll = function()
            if not first_poll then return {} end
            first_poll = false
            return {
              { type = "content_start", kind = "tool_call", index = 0, name = "replace_in_file" },
              { type = "tool_call_delta", index = 0, arguments = { path = "README.md", the_diff = "partial" } },
              {
                type = "content_end",
                index = 0,
                order = 0,
                content = {
                  type = "tool_use",
                  id = "call-1",
                  name = "replace_in_file",
                  input = { path = "README.md", the_diff = "complete" },
                },
              },
              { type = "done", reason = "tool_use", usage = {} },
            }
          end,
          cancel = function() end,
        }
      end,
    }
    local messages = {}
    local stops = {}

    RigClient.start(
      provider("openai", "openai"),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      {
        on_messages_add = function(items) messages[#messages + 1] = items[1] end,
        on_stop = function(result) stops[#stops + 1] = result end,
      }
    )
    assert.is_true(vim.wait(100, function() return #stops == 2 end, 10))
    package.loaded.avante_llm = loaded_native

    assert.same("tool_use", stops[1].reason)
    assert.is_true(stops[1].streaming_tool_use)
    assert.same({ path = "README.md", the_diff = "partial" }, messages[2].message.content[1].input)
    assert.same("generating", messages[2].state)
    assert.same({ path = "README.md", the_diff = "complete" }, messages[4].message.content[1].input)
    assert.same("generated", messages[4].state)
    assert.same(messages[2].uuid, messages[4].uuid)
  end)

  it("does not finalize a truncated tool call", function()
    local loaded_native = package.loaded.avante_llm
    local first_poll = true
    package.loaded.avante_llm = {
      api_version = 2,
      start = function()
        return {
          poll = function()
            if not first_poll then return {} end
            first_poll = false
            return {
              { type = "content_start", kind = "tool_call", index = 0, name = "replace_in_file" },
              { type = "tool_call_delta", index = 0, arguments = { path = "README.md" } },
              { type = "done", reason = "length", usage = {} },
            }
          end,
          cancel = function() end,
        }
      end,
    }
    local messages = {}
    local stopped

    RigClient.start(
      provider("openai", "openai"),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      {
        on_messages_add = function(items) messages[#messages + 1] = items[1] end,
        on_stop = function(result)
          if not result.streaming_tool_use then stopped = result end
        end,
      }
    )
    assert.is_true(vim.wait(100, function() return stopped ~= nil end, 10))
    package.loaded.avante_llm = loaded_native

    assert.same("max_tokens", stopped.reason)
    assert.same(2, #messages)
    assert.same("generating", messages[2].state)
  end)

  it("keeps separate reasoning blocks and opaque native metadata in history", function()
    local loaded_native = package.loaded.avante_llm
    local events = {
      { type = "content_start", index = 0, kind = "reasoning" },
      { type = "content_delta", index = 0, kind = "reasoning", text = "first" },
      {
        type = "content_end",
        index = 0,
        order = 0,
        content = { type = "thinking", thinking = "first" },
        native = '{"item":{"type":"thinking","signature":"sig-1"},"fingerprint":"0000000000000001"}',
      },
      { type = "content_start", index = 1, kind = "reasoning" },
      { type = "content_delta", index = 1, kind = "reasoning", text = "second" },
      {
        type = "content_end",
        index = 1,
        order = 1,
        content = { type = "thinking", thinking = "second" },
        native = '{"item":{"type":"thinking","signature":"sig-2"},"fingerprint":"0000000000000002"}',
      },
      { type = "content_start", index = 2, kind = "text" },
      { type = "content_delta", index = 2, kind = "text", text = "answer" },
      {
        type = "content_end",
        index = 2,
        order = 2,
        content = "answer",
        native = '{"item":{"phase":"final_answer","thoughtSignature":"gemini-sig"},"fingerprint":"0000000000000003"}',
      },
      {
        type = "done",
        reason = "complete",
        usage = {},
        origin = { api = "anthropic.messages", provider = "anthropic", model = "test-model" },
      },
    }
    package.loaded.avante_llm = {
      api_version = 2,
      start = function()
        return {
          poll = function()
            local batch = events
            events = {}
            return batch
          end,
          cancel = function() end,
        }
      end,
    }
    local messages, order, chunks = {}, {}, {}
    local stopped
    RigClient.start(provider("claude", "claude"), { system_prompt = "system", messages = {} }, {
      on_messages_add = function(items)
        for _, item in ipairs(items) do
          if not messages[item.uuid] then order[#order + 1] = item.uuid end
          messages[item.uuid] = item
        end
      end,
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end,
      on_stop = function(result) stopped = result end,
    })
    local finished = vim.wait(100, function() return stopped ~= nil end, 10)
    package.loaded.avante_llm = loaded_native

    assert.is_true(finished)
    assert.same("complete", stopped.reason)
    assert.same(3, #order)
    assert.same("first", messages[order[1]].message.content[1].thinking)
    assert.same("second", messages[order[2]].message.content[1].thinking)
    assert.same("sig-1", vim.json.decode(messages[order[1]].message.native).item.signature)
    assert.same("sig-2", vim.json.decode(messages[order[2]].message.native).item.signature)
    assert.same("gemini-sig", vim.json.decode(messages[order[3]].message.native).item.thoughtSignature)
    assert.same("final_answer", vim.json.decode(messages[order[3]].message.native).item.phase)
    assert.same("anthropic.messages", messages[order[1]].message.origin.api)
    assert.same("<think>\nfirst\n</think>\n<think>\nsecond\n</think>\nanswer", table.concat(chunks))
  end)

  it("uses the stored response id only for supported Responses tool continuations", function()
    local messages = {
      {
        role = "assistant",
        content = { { type = "tool_use", id = "call-1", name = "lookup", input = {} } },
      },
      {
        role = "user",
        content = { { type = "tool_result", tool_use_id = "call-1", content = "answer" } },
      },
    }
    local session_ctx = { previous_response_id = "resp_1" }
    local enabled_provider = provider("openai", "openai", {
      use_response_api = true,
      support_previous_response_id = true,
      extra_request_body = { store = true },
    })
    local enabled =
      RigClient._build_request(enabled_provider, { system_prompt = "system", messages = messages }, session_ctx)
    local disabled = RigClient._build_request(
      provider("openai", "openai", { use_response_api = true, support_previous_response_id = false }),
      { system_prompt = "system", messages = messages },
      session_ctx
    )
    local stale = RigClient._build_request(enabled_provider, {
      system_prompt = "system",
      messages = {
        messages[1],
        messages[2],
        { role = "assistant", content = "finished" },
        { role = "user", content = "new question" },
      },
    }, session_ctx)

    assert.same("resp_1", enabled.prompt.additionalParams.previous_response_id)
    assert.same({ store = true }, enabled_provider.extra_request_body)
    assert.is_nil(disabled.prompt.additionalParams.previous_response_id)
    assert.is_nil(stale.prompt.additionalParams.previous_response_id)
  end)

  it("stores a Responses tool-call response id in the current session", function()
    local loaded_native = package.loaded.avante_llm
    local first_poll = true
    package.loaded.avante_llm = {
      api_version = 2,
      start = function()
        return {
          poll = function()
            if not first_poll then return {} end
            first_poll = false
            return {
              {
                type = "done",
                reason = "tool_use",
                usage = {},
                responseId = "resp_tool_1",
              },
            }
          end,
          cancel = function() end,
        }
      end,
    }
    local session_ctx = {}
    local stopped

    RigClient.start(
      provider("openai", "openai", { use_response_api = true, support_previous_response_id = true }),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      { on_stop = function(result) stopped = result end },
      nil,
      session_ctx
    )
    assert.is_true(vim.wait(100, function() return stopped ~= nil end, 10))
    package.loaded.avante_llm = loaded_native

    assert.same("tool_use", stopped.reason)
    assert.same("resp_tool_1", session_ctx.previous_response_id)
  end)

  it("reports an incompatible native API without hiding the version mismatch", function()
    local loaded_native = package.loaded.avante_llm
    package.loaded.avante_llm = { api_version = 3 }
    local stopped

    local request = RigClient.start(
      provider("openai", "openai"),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      { on_stop = function(result) stopped = result end }
    )
    package.loaded.avante_llm = loaded_native

    assert.is_nil(request)
    assert.same("error", stopped.reason)
    assert.matches("expected API 2, got 3", stopped.error, nil, true)
    assert.matches("rebuild or reinstall", stopped.error, nil, true)
  end)

  it("reports timer allocation failures after cancelling the native request", function()
    local loaded_native = package.loaded.avante_llm
    local cancelled = false
    package.loaded.avante_llm = {
      api_version = 2,
      start = function()
        return { cancel = function() cancelled = true end }
      end,
    }
    local timer_stub = stub(vim.uv or vim.loop, "new_timer").returns(nil)
    local stopped

    local request = RigClient.start(
      provider("openai", "openai"),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      { on_stop = function(result) stopped = result end }
    )
    timer_stub:revert()
    package.loaded.avante_llm = loaded_native

    assert.is_nil(request)
    assert.is_true(cancelled)
    assert.same("error", stopped.reason)
    assert.matches("timer", stopped.error, nil, true)
  end)

  describe("cancellation", function()
    local loaded_native
    local request
    local stopped
    local chunks
    local cancelled
    local pending

    before_each(function()
      loaded_native = package.loaded.avante_llm
      request, stopped, chunks, cancelled = nil, {}, {}, 0
      pending = {
        { type = "content_start", index = 0, kind = "text" },
        { type = "content_delta", index = 0, kind = "text", text = "queued output" },
        { type = "content_delta", index = 0, kind = "text", text = " after cancellation" },
        { type = "content_end", index = 0, order = 0, content = "queued output after cancellation" },
        { type = "done", reason = "complete", usage = {} },
      }
      package.loaded.avante_llm = {
        api_version = 2,
        start = function()
          return {
            poll = function()
              local events = pending
              pending = {}
              return events
            end,
            cancel = function() cancelled = cancelled + 1 end,
          }
        end,
      }
    end)

    after_each(function()
      if request then request:cancel() end
      vim.wait(50, function() return #stopped > 0 end, 1)
      package.loaded.avante_llm = loaded_native
    end)

    local function start(on_chunk, on_messages_add)
      request = RigClient.start(
        provider("openai", "openai"),
        { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
        {
          on_chunk = on_chunk or function(chunk) chunks[#chunks + 1] = chunk end,
          on_messages_add = on_messages_add,
          on_stop = function(result) stopped[#stopped + 1] = result end,
        }
      )
    end

    for _, escape in ipairs({ false, true }) do
      it("discards queued completion after " .. (escape and "Escape" or "handle cancellation"), function()
        start()
        if escape then
          vim.api.nvim_exec_autocmds("User", { pattern = "AvanteLLMEscape" })
        else
          request:cancel()
        end
        request:cancel()
        local immediate = vim.deepcopy(stopped)
        vim.wait(30, function() return false end, 1)

        assert.same({ { reason = "cancelled" } }, immediate)
        assert.same(immediate, stopped)
        assert.same({}, chunks)
        assert.same(1, cancelled)
      end)
    end

    it("discards the rest of a polled batch when a chunk callback cancels", function()
      start(function(chunk)
        chunks[#chunks + 1] = chunk
        request:cancel()
      end)
      assert.is_true(vim.wait(100, function() return #stopped > 0 end, 1))

      assert.same({ { reason = "cancelled" } }, stopped)
      assert.same({ "queued output" }, chunks)
      assert.same(1, cancelled)
    end)

    it("does not cancel a request that already completed", function()
      start()
      assert.is_true(vim.wait(100, function() return #stopped > 0 end, 1))
      request:cancel()

      assert.same("complete", stopped[1].reason)
      assert.same(1, #stopped)
      assert.same(0, cancelled)
    end)

    it("keeps completion terminal during final message callbacks", function()
      start(nil, function(messages)
        if messages[1].state == "generated" then request:cancel() end
      end)
      assert.is_true(vim.wait(100, function() return #stopped > 0 end, 1))

      assert.same("complete", stopped[1].reason)
      assert.same(1, #stopped)
      assert.same(0, cancelled)
    end)
  end)

  describe("callback failures", function()
    local loaded_native, timer_stub, schedule_stub, error_stub, request
    local timer, pending, stops, cancelled, polls

    before_each(function()
      loaded_native = package.loaded.avante_llm
      stops, cancelled, polls = {}, 0, 0
      pending = {
        { type = "content_start", index = 0, kind = "text" },
        { type = "content_delta", index = 0, kind = "text", text = "hello" },
        { type = "content_end", index = 0, order = 0, content = "hello" },
        { type = "done", reason = "complete" },
      }
      timer = {
        closed = false,
        start = function(self, _, _, callback) self.callback = callback end,
        stop = function() end,
        close = function(self) self.closed = true end,
        is_closing = function(self) return self.closed end,
      }
      timer_stub = stub(vim.uv, "new_timer").returns(timer)
      schedule_stub = stub(vim, "schedule_wrap").invokes(function(callback) return callback end)
      package.loaded.avante_llm = {
        api_version = 2,
        start = function()
          return {
            poll = function()
              polls = polls + 1
              local events = pending
              pending = {}
              return events
            end,
            cancel = function() cancelled = cancelled + 1 end,
          }
        end,
      }
    end)

    after_each(function()
      if request then pcall(request.cancel) end
      request = nil
      timer_stub:revert()
      schedule_stub:revert()
      if error_stub then
        error_stub:revert()
        error_stub = nil
      end
      package.loaded.avante_llm = loaded_native
    end)

    for _, state in ipairs({ "generating", "generated" }) do
      it("terminates and releases resources when a " .. state .. " message callback throws", function()
        request = RigClient.start(
          provider("openai", "openai"),
          { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
          {
            on_messages_add = function(messages)
              if messages[1].state == state then error("message callback failed") end
            end,
            on_stop = function(result) stops[#stops + 1] = result end,
          }
        )

        assert.is_true(pcall(timer.callback))
        timer.callback()
        request:cancel()

        assert.same(1, #stops)
        assert.same("error", stops[1].reason)
        assert.matches("message callback failed", stops[1].error, nil, true)
        assert.same(1, cancelled)
        assert.same(1, polls)
        assert.is_true(timer.closed)
        assert.same({}, vim.api.nvim_get_autocmds({ group = "avante_llm", pattern = "AvanteLLMEscape" }))
      end)
    end

    it("reports a throwing stop callback without notifying it twice", function()
      error_stub = stub(require("avante.utils"), "error")
      request = RigClient.start(
        provider("openai", "openai"),
        { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
        {
          on_stop = function(result)
            stops[#stops + 1] = result
            error("stop callback failed")
          end,
        }
      )

      assert.is_true(pcall(timer.callback))
      timer.callback()
      request:cancel()

      assert.same(1, #stops)
      assert.same("complete", stops[1].reason)
      assert.is_true(timer.closed)
      assert.stub(error_stub).was_called(1)
    end)
  end)
end)
