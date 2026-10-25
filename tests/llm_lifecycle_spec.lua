local Config = require("avante.config")
local Llm = require("avante.llm")
local LLMTools = require("avante.llm_tools")
local Utils = require("avante.utils")

describe("non-ACP LLM lifecycle", function()
  local stubs = {}
  local saved_config

  local function add_stub(...)
    local value = stub(...)
    stubs[#stubs + 1] = value
    return value
  end

  local function stream_opts(on_stop)
    return {
      provider = {},
      session_ctx = {},
      get_history_messages = function() return {} end,
      on_chunk = function() end,
      on_stop = on_stop,
    }
  end

  before_each(function()
    saved_config = {
      acp_providers = Config.acp_providers,
      mode = Config.mode,
      dual_boost = Config.dual_boost,
    }
    Config.acp_providers = {}
    Config.mode = "legacy"
    add_stub(Llm, "generate_prompts").returns({ messages = {} })
  end)

  after_each(function()
    for _, value in ipairs(stubs) do
      value:revert()
    end
    stubs = {}
    Config.acp_providers = saved_config.acp_providers
    Config.mode = saved_config.mode
    Config.dual_boost = saved_config.dual_boost
  end)

  it("reports cancellation once", function()
    local stops = 0
    add_stub(Llm, "request").invokes(function(opts)
      opts.handler_opts.on_stop({ reason = "cancelled" })
      opts.handler_opts.on_stop({ reason = "cancelled" })
    end)

    Llm._stream(stream_opts(function() stops = stops + 1 end))

    assert.same(1, stops)
  end)

  it("keeps concurrent rate-limit timers independent", function()
    local timers = {}
    add_stub(vim.uv, "new_timer").invokes(function()
      local timer = {
        stopped = false,
        start = function(self, _, _, callback) self.callback = callback end,
        stop = function(self) self.stopped = true end,
        close = function() end,
      }
      timers[#timers + 1] = timer
      return timer
    end)
    add_stub(Utils, "info")
    add_stub(Llm, "request").invokes(
      function(opts) opts.handler_opts.on_stop({ reason = "rate_limit", retry_after = 10 }) end
    )

    Llm._stream(stream_opts(function() end))
    Llm._stream(stream_opts(function() end))

    assert.same(2, #timers)
    assert.is_false(timers[1].stopped)
    assert.is_false(timers[2].stopped)
  end)

  it("does not restart after cancellation", function()
    local requests = 0
    local stops = 0
    add_stub(Llm, "request").invokes(function() requests = requests + 1 end)
    local opts = stream_opts(function() stops = stops + 1 end)

    Llm._stream(opts)
    Llm.cancel_inflight_request()
    Llm._stream(opts)

    assert.same(1, requests)
    assert.same(1, stops)
  end)

  it("isolates cached routes between dual-boost providers", function()
    local streams = {}
    Config.dual_boost = { timeout = 1000, prompt = "{{provider1_output}}{{provider2_output}}" }
    add_stub(vim.uv, "new_timer").returns({
      start = function() end,
      stop = function() end,
      close = function() end,
      is_closing = function() return false end,
    })
    add_stub(Llm, "_stream").invokes(function(opts) streams[#streams + 1] = opts end)
    local session_ctx = { resolved_api_route = "responses" }

    Llm._dual_boost_stream({ on_stop = function() end, session_ctx = session_ctx }, {}, {})

    assert.is_not.equal(session_ctx, streams[1].session_ctx)
    assert.is_not.equal(streams[1].session_ctx, streams[2].session_ctx)
    assert.is_nil(streams[1].session_ctx.resolved_api_route)
    assert.is_nil(streams[2].session_ctx.resolved_api_route)
    assert.same("responses", session_ctx.resolved_api_route)
  end)

  describe("dual boost cleanup", function()
    local timer, requests, stops

    before_each(function()
      requests, stops = {}, {}
      Config.dual_boost = { timeout = 1000, prompt = "{{provider1_output}}{{provider2_output}}" }
      timer = {
        closed = false,
        start = function(self, _, _, callback) self.callback = callback end,
        stop = function() end,
        close = function(self) self.closed = true end,
        is_closing = function(self) return self.closed end,
      }
      add_stub(vim.uv, "new_timer").returns(timer)
      add_stub(vim, "schedule_wrap").invokes(function(callback) return callback end)
      add_stub(Utils, "error")
      add_stub(Utils, "warn")
      add_stub(Utils, "info")
      add_stub(Llm, "request").invokes(function(opts)
        local request = { handler = opts.handler_opts, cancelled = 0 }
        requests[#requests + 1] = request
        return {
          cancel = function()
            request.cancelled = request.cancelled + 1
            request.handler.on_stop({ reason = "cancelled" })
          end,
        }
      end)
    end)

    after_each(function() Llm.cancel_inflight_request() end)

    local function start()
      Llm._dual_boost_stream(stream_opts(function(result) stops[#stops + 1] = result end), {}, {})
    end

    it("closes the timer on success and merges only once", function()
      start()
      requests[1].handler.on_stop({ reason = "complete" })
      requests[2].handler.on_stop({ reason = "complete" })
      requests[2].handler.on_stop({ reason = "complete" })
      timer.callback()

      assert.is_true(timer.closed)
      assert.same(3, #requests)
      assert.same(0, requests[1].cancelled)
      assert.same(0, requests[2].cancelled)
      assert.same({}, stops)
    end)

    it("cancels the other stream and closes the timer on cancellation", function()
      start()
      requests[1].handler.on_stop({ reason = "cancelled" })
      requests[2].handler.on_stop({ reason = "complete" })
      timer.callback()

      assert.is_true(timer.closed)
      assert.same(1, requests[2].cancelled)
      assert.same({ { reason = "cancelled" } }, stops)
      assert.same(2, #requests)
    end)

    it("terminates on timeout, cancels the pending stream and ignores late completion", function()
      start()
      requests[1].handler.on_stop({ reason = "complete" })
      timer.callback()
      requests[2].handler.on_stop({ reason = "complete" })

      assert.is_true(timer.closed)
      assert.same(1, requests[2].cancelled)
      assert.same(1, #stops)
      assert.same("error", stops[1].reason)
      assert.matches("timeout", stops[1].error)
      assert.same(2, #requests)
    end)

    it("cancels the other stream when a provider fails", function()
      start()
      requests[1].handler.on_stop({ reason = "error", error = "provider failed" })

      assert.is_true(timer.closed)
      assert.same(1, requests[2].cancelled)
      assert.same({ { reason = "error", error = "provider failed" } }, stops)
    end)

    it("cancels the current request after a rate-limit retry", function()
      start()
      local retry_timer = vim.tbl_extend("force", timer, { closed = false })
      vim.uv.new_timer.returns(retry_timer)
      requests[2].handler.on_stop({ reason = "rate_limit", retry_after = 0 })
      retry_timer.callback()
      assert.same(3, #requests)

      timer.callback()
      retry_timer.callback()

      assert.is_true(timer.closed)
      assert.is_true(retry_timer.closed)
      assert.same(1, requests[1].cancelled)
      assert.same(0, requests[2].cancelled)
      assert.same(1, requests[3].cancelled)
      assert.same(1, #stops)
      assert.same(3, #requests)
    end)

    it("releases the first stream if starting the second stream throws", function()
      local calls = 0
      Llm.generate_prompts.invokes(function()
        calls = calls + 1
        if calls == 2 then error("startup failed") end
        return { messages = {} }
      end)
      start()

      assert.is_true(timer.closed)
      assert.same(1, requests[1].cancelled)
      assert.same(1, #stops)
      assert.same("error", stops[1].reason)
      assert.matches("startup failed", stops[1].error, nil, true)
    end)
  end)

  it("does not start a tool after its request was cancelled", function()
    local called = false
    local _, err = LLMTools.process_tool_use({
      {
        name = "test_tool",
        func = function()
          called = true
          return "done"
        end,
      },
    }, { name = "test_tool", id = "tool-1", input = {} }, {
      session_ctx = {},
      is_cancelled = function() return true end,
    })

    assert.is_false(called)
    assert.same(require("avante.llm_tools.helpers").CANCEL_TOKEN, err)
  end)

  it("uses each history UUID as the tool runtime key across streaming and completion", function()
    local history = {}
    local captured = {}
    add_stub(Llm, "generate_prompts").returns({
      messages = {},
      tools = { { name = "replace_in_file", support_streaming = true } },
    })
    add_stub(LLMTools, "process_tool_use").invokes(function(_, _, opts)
      captured[#captured + 1] = { key = opts.tool_use_id, streaming = opts.streaming == true }
      return "done"
    end)
    add_stub(Llm, "request").invokes(function(opts)
      if #history > 0 then return end
      for index = 1, 2 do
        history[index] = require("avante.history.message"):new("assistant", {
          type = "tool_use",
          name = "replace_in_file",
          id = "",
          input = { path = "test" },
        }, { state = "generating", turn_id = "turn" })
        opts.handler_opts.on_stop({ reason = "tool_use", streaming_tool_use = true })
        history[index].message.content[1].id = "call-" .. index
        history[index].state = "generated"
      end
      opts.handler_opts.on_stop({ reason = "tool_use" })
    end)
    local opts = stream_opts(function() end)
    opts.get_history_messages = function() return history end

    Llm._stream(opts)

    assert.same({
      { key = history[1].uuid, streaming = true },
      { key = history[2].uuid, streaming = true },
      { key = history[1].uuid, streaming = false },
      { key = history[2].uuid, streaming = false },
    }, captured)
  end)

  it("completes an asynchronous tool only once when cancellation races its result", function()
    local cancelled = false
    local completions = 0
    local tool_complete
    local timer_callback
    add_stub(vim.uv, "new_timer").returns({
      start = function(_, _, _, callback) timer_callback = callback end,
      stop = function() end,
      close = function() end,
      is_closing = function() return false end,
    })

    LLMTools.process_tool_use({
      {
        name = "test_tool",
        func = function(_, opts)
          tool_complete = opts.on_complete
          return nil, nil
        end,
      },
    }, { name = "test_tool", id = "tool-1", input = {} }, {
      session_ctx = {},
      on_complete = function() completions = completions + 1 end,
      is_cancelled = function() return cancelled end,
    })

    cancelled = true
    timer_callback()
    tool_complete("late result")

    assert.same(1, completions)
  end)
end)
