local stub = require("luassert.stub")
local Config = require("avante.config")
local Providers = require("avante.providers")
local Utils = require("avante.utils")
local Llm = require("avante.llm")
local EditFile = require("avante.llm_tools.edit_file")
local Helpers = require("avante.llm_tools.helpers")
local StrReplace = require("avante.llm_tools.str_replace")

describe("Fast Apply", function()
  local stubs
  local handlers
  local result
  local replacement
  local input
  local loaded_native

  before_each(function()
    Config.setup({})
    loaded_native = package.loaded.avante_llm
    handlers, result, replacement = nil, nil, nil
    input = { path = "test.lua", instructions = "update", code_edit = "new code" }
    stubs = {
      stub(Providers.morph, "is_env_set", function() return true end),
      stub(Providers.morph, "parse_api_key", function() return "fastapply-test-secret" end),
      stub(Helpers, "is_ignored", function() return false end),
      stub(Utils, "read_file_from_buf_or_disk", function() return { "old code", "" } end),
      stub(Llm, "request", function(opts) handlers = opts.handler_opts end),
      stub(StrReplace, "func", function(args, opts)
        replacement = args
        opts.on_complete(true)
      end),
      stub(vim, "system", function() error("Fast Apply must use the shared LLM transport") end),
    }
  end)

  after_each(function()
    for _, item in ipairs(stubs) do
      item:revert()
    end
    package.loaded.avante_llm = loaded_native
  end)

  local function start()
    EditFile.func(input, { on_complete = function(ok, err) result = { ok = ok, error = err } end })
    assert.is_true(vim.wait(1000, function() return handlers ~= nil or result ~= nil end), "request did not start")
    assert.is_not_nil(handlers)
  end

  it("collects the shared LLM stream before applying the complete replacement", function()
    start()
    handlers.on_chunk("new ")
    assert.is_nil(replacement)
    handlers.on_chunk("code")
    handlers.on_stop({ reason = "complete" })
    assert.same({ path = Helpers.get_abs_path("test.lua"), old_str = "old code", new_str = "new code" }, replacement)
    assert.is_true(result.ok)
  end)

  it("keeps reading and applying to the original project after an asynchronous project switch", function()
    local project_root = "/original-project"
    local read_path, applied_path
    stubs[#stubs + 1] = stub(Utils, "get_project_root", function() return project_root end)
    Utils.read_file_from_buf_or_disk:revert()
    stubs[#stubs + 1] = stub(Utils, "read_file_from_buf_or_disk", function(path)
      read_path = path
      return { "old code" }
    end)
    StrReplace.func:revert()
    stubs[#stubs + 1] = stub(StrReplace, "func", function(args, opts)
      applied_path = Helpers.get_abs_path(args.path)
      opts.on_complete(true)
    end)

    start()
    project_root = "/other-project"
    handlers.on_chunk("new code")
    handlers.on_stop({ reason = "complete" })

    assert.equals("/original-project/test.lua", applied_path)
    assert.equals("/original-project/test.lua", read_path)
    assert.is_true(result.ok)
  end)

  for _, reason in ipairs({ "error", "cancelled", "max_tokens", "tool_use" }) do
    it("does not apply a partial replacement after " .. reason, function()
      start()
      handlers.on_chunk("partial")
      handlers.on_stop({ reason = reason, error = reason == "error" and "connection refused" or nil })
      assert.is_nil(replacement)
      assert.is_false(result.ok)
      assert.is_string(result.error)
    end)
  end

  it("rejects empty completions", function()
    start()
    handlers.on_stop({ reason = "complete" })
    assert.is_nil(replacement)
    assert.is_false(result.ok)
  end)

  it("does not apply a queued completion after cancellation", function()
    Llm.request:revert()
    local cancelled = false
    local pending = {
      { type = "content_start", kind = "text", index = 0 },
      { type = "content_delta", kind = "text", index = 0, text = "new code" },
      { type = "content_end", index = 0, order = 0, content = "new code" },
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
          cancel = function() cancelled = true end,
        }
      end,
    }

    EditFile.func(input, { on_complete = function(ok, err) result = { ok = ok, error = err } end })
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteLLMEscape" })
    assert.is_true(vim.wait(100, function() return result ~= nil end, 1))

    assert.is_true(cancelled)
    assert.is_nil(replacement)
    assert.is_false(result.ok)
    assert.same("Fast Apply stopped: cancelled", result.error)
  end)

  it("propagates synchronous replacement errors to the tool callback", function()
    StrReplace.func:revert()
    stubs[#stubs + 1] = stub(StrReplace, "func", function() return false, "No permission to access path" end)
    start()
    handlers.on_chunk("new code")
    handlers.on_stop({ reason = "complete" })
    assert.is_false(result.ok)
    assert.same("No permission to access path", result.error)
  end)

  it("reports read failures without sending incomplete file contents", function()
    Utils.read_file_from_buf_or_disk:revert()
    stubs[#stubs + 1] = stub(
      Utils,
      "read_file_from_buf_or_disk",
      function() return {}, "permission denied", "EACCES" end
    )
    EditFile.func(input, { on_complete = function(ok, err) result = { ok = ok, error = err } end })
    assert.is_true(vim.wait(1000, function() return result ~= nil end))
    assert.is_nil(handlers)
    assert.is_false(result.ok)
    assert.matches("permission denied", result.error, nil, true)
  end)
end)
