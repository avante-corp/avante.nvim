local Config = require("avante.config")
local Copilot = require("avante.providers.copilot")
local RigClient = require("avante.libs.rig_client")
local curl = require("plenary.curl")
local Path = require("plenary.path")

describe("Copilot request authentication", function()
  local saved_state, saved_login, saved_native
  local curl_stub, write_stub
  local auth_options, native_input, native_cancelled
  local stops, request

  local function token()
    return {
      token = "session-token",
      expires_at = os.time() + 3600,
      endpoints = { api = "https://session.example.test" },
    }
  end

  local function start()
    request = RigClient.start(
      vim.tbl_extend("force", Copilot, { _name = "private_copilot", _protocol = "copilot", model = "test-model" }),
      { system_prompt = "system", messages = { { role = "user", content = "hello" } } },
      { on_stop = function(result) stops[#stops + 1] = result end }
    )
    return request
  end

  local function wait_for_stop()
    assert.is_true(vim.wait(200, function() return #stops > 0 end, 1), "request did not stop")
  end

  before_each(function()
    if not Config.providers then Config.setup({}) end
    saved_state, saved_login, saved_native = Copilot.state, vim.g.avante_login, package.loaded.avante_llm
    Copilot.state = { oauth_token = "oauth-token" }
    auth_options, native_input, native_cancelled, request = nil, nil, false, nil
    stops = {}
    write_stub = stub(Path, "write")
    curl_stub = stub(curl, "get", function(_, opts)
      assert.is_function(opts.callback, "authentication must not use synchronous curl")
      auth_options = opts
      return {}
    end)
    package.loaded.avante_llm = {
      api_version = 2,
      start = function(input)
        native_input = input
        return {
          poll = function()
            if native_cancelled then return { { type = "cancelled" } } end
            return { { type = "done", reason = "complete", usage = {} } }
          end,
          cancel = function() native_cancelled = true end,
        }
      end,
    }
  end)

  after_each(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteLLMEscape" })
    if request then vim.wait(200, function() return #stops > 0 end, 1) end
    curl_stub:revert()
    write_stub:revert()
    Copilot.state, vim.g.avante_login, package.loaded.avante_llm = saved_state, saved_login, saved_native
  end)

  it("starts immediately with a cached valid token", function()
    Copilot.state.github_token = token()
    start()
    assert.is_nil(auth_options)
    assert.same("session-token", native_input.provider.apiKey)
    wait_for_stop()
    assert.same("complete", stops[1].reason)
  end)

  it("keeps Neovim responsive while refreshing an expired token", function()
    Copilot.state.github_token = vim.tbl_extend("force", token(), { expires_at = os.time() - 1 })
    start()
    assert.same({}, stops)
    assert.is_nil(native_input)
    local scheduled = false
    vim.schedule(function() scheduled = true end)
    assert.is_true(vim.wait(200, function() return scheduled end, 1))

    local response = { status = 200, body = vim.json.encode(token()) }
    local timer = vim.uv.new_timer()
    timer:start(0, 0, function()
      timer:stop()
      timer:close()
      auth_options.callback(response)
    end)
    wait_for_stop()
    assert.same("session-token", native_input.provider.apiKey)
    assert.same("https://session.example.test", native_input.provider.baseUrl)
    assert.same("complete", stops[1].reason)
  end)

  for _, cancel_with_escape in ipairs({ false, true }) do
    it("ignores late authentication after " .. (cancel_with_escape and "Escape" or "handle cancellation"), function()
      start()
      assert.is_table(auth_options)
      if cancel_with_escape then
        vim.api.nvim_exec_autocmds("User", { pattern = "AvanteLLMEscape" })
      else
        request:cancel()
      end
      assert.same({ { reason = "cancelled" } }, stops)

      auth_options.callback({ status = 200, body = vim.json.encode(token()) })
      assert.is_true(vim.wait(200, function() return Copilot.state.github_token ~= nil end, 1))
      request:cancel()
      assert.is_nil(native_input)
      assert.same({ { reason = "cancelled" } }, stops)
    end)
  end

  it("forwards cancellation to the native request after authentication", function()
    start()
    assert.is_table(auth_options)
    local native_start = package.loaded.avante_llm.start
    package.loaded.avante_llm.start = function(input)
      local native = native_start(input)
      vim.schedule(function() request:cancel() end)
      return native
    end
    auth_options.callback({ status = 200, body = vim.json.encode(token()) })
    wait_for_stop()
    assert.is_true(native_cancelled)
    assert.same("cancelled", stops[1].reason)
  end)

  it("reports HTTP authentication failures without exposing the response body", function()
    start()
    assert.is_table(auth_options)
    auth_options.callback({ status = 401, body = "private response" })
    wait_for_stop()
    assert.same("error", stops[1].reason)
    assert.matches("401", stops[1].error)
    assert.is_nil(stops[1].error:find("private response", 1, true))
    assert.is_nil(native_input)
  end)

  it("reports transport failures instead of leaving the request waiting", function()
    start()
    assert.is_table(auth_options)
    auth_options.on_error({ exit = 6, message = "Could not resolve host" })
    wait_for_stop()
    assert.same("error", stops[1].reason)
    assert.is_nil(native_input)
  end)

  for _, body in ipairs({
    "not json",
    "null",
    "{}",
    '{"token":"","expires_at":9999999999}',
    '{"token":"expired-token","expires_at":1}',
  }) do
    it("rejects invalid token responses: " .. body, function()
      start()
      assert.is_table(auth_options)
      auth_options.callback({ status = 200, body = body })
      wait_for_stop()
      assert.same("error", stops[1].reason)
      assert.is_nil(Copilot.state.github_token)
      assert.is_nil(native_input)
    end)
  end

  it("reports failures to start authentication", function()
    curl_stub:revert()
    curl_stub = stub(curl, "get", function() error("curl unavailable") end)
    start()
    wait_for_stop()
    assert.same("error", stops[1].reason)
    assert.matches("curl unavailable", stops[1].error)
    assert.is_nil(native_input)
  end)

  it("reports token cache write failures", function()
    write_stub:revert()
    write_stub = stub(Path, "write", function() error("cache is not writable") end)
    start()
    assert.is_table(auth_options)
    auth_options.callback({ status = 200, body = vim.json.encode(token()) })
    wait_for_stop()
    assert.same("error", stops[1].reason)
    assert.matches("cache is not writable", stops[1].error)
    assert.is_nil(native_input)
  end)
end)
