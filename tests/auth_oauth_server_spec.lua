local server = require("avante.auth.oauth_server")

describe("OAuth loopback callback", function()
  local listener, outcome
  local function request(query)
    local response, done = "", false
    local client = vim.uv.new_tcp()
    client:connect("127.0.0.1", listener.port, function(err)
      assert.is_nil(err)
      client:write("GET /auth/callback?" .. query .. " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      client:read_start(function(_, chunk)
        if chunk then
          response = response .. chunk
        else
          client:close()
          done = true
        end
      end)
    end)
    assert.is_true(vim.wait(1000, function() return done end))
    return response
  end

  before_each(function()
    outcome = nil
    listener = assert(server.start())
    server.wait_for_callback(
      "expected-state",
      function(code, params) outcome = { code = code, params = params } end,
      function(err) outcome = { error = err } end
    )
  end)
  after_each(function() server.stop() end)

  it("delivers a verified callback once", function()
    assert.is_true(request("state=expected-state&code=auth-code&client_id=oaiapp_test"):find("200 OK", 1, true) ~= nil)
    assert.equals("auth-code", outcome.code)
    assert.equals("oaiapp_test", outcome.params.client_id)
    assert.is_true(request("state=expected-state&code=reused"):find("400 Bad Request", 1, true) ~= nil)
    assert.equals("auth-code", outcome.code)
  end)

  it("delivers state, denial, and missing-code failures without losing the callback", function()
    for _, query in ipairs({
      "state=wrong&code=code",
      "state=expected-state&error=access_denied",
      "state=expected-state",
    }) do
      if outcome then
        outcome = nil
        server.wait_for_callback(
          "expected-state",
          function() error("Unexpected success") end,
          function(err) outcome = { error = err } end
        )
      end
      assert.is_true(request(query):find("400 Bad Request", 1, true) ~= nil)
      assert.is_string(outcome.error)
    end
  end)

  it("uses another loopback port when the preferred port is busy", function()
    server.stop()
    local occupied = vim.uv.new_tcp()
    local bound = occupied:bind("127.0.0.1", 1455)
    if bound then occupied:listen(1, function() end) end
    listener = assert(server.start())
    occupied:close()
    assert.not_equals(1455, listener.port)
    assert.equals("http://127.0.0.1:" .. listener.port .. "/auth/callback", listener.redirect_uri)
  end)
end)
