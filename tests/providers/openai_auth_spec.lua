---@diagnostic disable: duplicate-set-field
local Config = require("avante.config")
local Providers = require("avante.providers")
local Path = require("plenary.path")
Config.setup({})

local scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
local function parse_form(value)
  local params = {}
  for pair in (value:match("%?(.*)$") or value):gmatch("[^&]+") do
    local key, item = pair:match("([^=]+)=?(.*)")
    params[vim.uri_decode(key)] = vim.uri_decode(item)
  end
  return params
end

describe("OpenAI sign-in lifecycle", function()
  local auth, store, curl, callback, opened_url, response, posts, server_stopped
  local data_dir, originals
  local modules = {
    "avante.auth.providers.openai",
    "avante.auth.store",
    "avante.auth.oauth_server",
    "avante.auth.oidc",
    "avante.tokenizers",
  }

  local function credentials()
    return {
      access_token = "old-access",
      refresh_token = "old+refresh&token",
      expires_at = os.time() - 1,
      client_id = "oaiapp_test",
      scopes = { "chatgpt.tokens.use.direct" },
      subject = "user-1",
      id_token = "valid-id",
    }
  end

  before_each(function()
    data_dir = vim.fn.tempname()
    originals = {
      stdpath = vim.fn.stdpath,
      open = vim.ui.open,
      notify = vim.notify,
      provider = Config.provider,
      openai = rawget(Providers, "openai"),
      modules = {},
    }
    for _, name in ipairs(modules) do
      originals.modules[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    vim.fn.stdpath = function(what) return what == "data" and data_dir or originals.stdpath(what) end
    vim.notify = function() end
    vim.ui.open = function(url)
      opened_url = url
      return {}
    end
    Config.provider = "openai"
    Providers.openai = { auth_type = "chatgpt" }
    package.loaded["avante.tokenizers"] = { setup = function() end }
    server_stopped, opened_url, callback, posts = false, nil, nil, {}
    package.loaded["avante.auth.oauth_server"] = {
      start = function() return { redirect_uri = "http://127.0.0.1:12345/auth/callback" } end,
      stop = function() server_stopped = true end,
      wait_for_callback = function(state, success) callback = { state = state, success = success } end,
    }
    package.loaded["avante.auth.oidc"] = {
      check_available = function() return true end,
      validate = function(id)
        if id == "valid-id" then return { sub = "user-1" } end
        return nil, "Invalid identity"
      end,
    }
    curl = require("plenary.curl")
    originals.post = curl.post
    response = {
      access_token = "new-access",
      refresh_token = "new-refresh",
      expires_in = 3600,
      id_token = "valid-id",
      scope = scope,
    }
    curl.post = function(url, opts)
      table.insert(posts, { url = url, body = parse_form(opts.body) })
      return { status = 200, body = vim.json.encode(response) }
    end
    store = require("avante.auth.store")
    auth = require("avante.auth.providers.openai")
  end)

  after_each(function()
    auth.cleanup()
    store.cleanup()
    curl.post = originals.post
    vim.fn.stdpath, vim.ui.open, vim.notify = originals.stdpath, originals.open, originals.notify
    Config.provider, Providers.openai = originals.provider, originals.openai
    for _, name in ipairs(modules) do
      package.loaded[name] = originals.modules[name]
    end
    vim.fn.delete(data_dir, "rf")
  end)

  it("keeps setup explicit and rejects old device-flow credentials", function()
    auth.setup({ tokenizer_id = "gpt-4o" })
    assert.equals("", Providers.openai.api_key_name)
    assert.is_nil(opened_url)
    store.update("openai", { access_token = "legacy", refresh_token = "legacy", expires_at = os.time() + 3600 })
    auth.setup({})
    assert.is_nil(store.read().openai)
    assert.is_nil(opened_url)
    Providers.openai.auth_type = "api"
    auth.setup({})
    assert.equals("OPENAI_API_KEY", Providers.openai.api_key_name)
    assert.equals(
      "Bearer api-key",
      auth.get_headers(
        { auth_type = "api", api_key_name = "OPENAI_API_KEY" },
        { parse_api_key = function() return "api-key" end }
      ).Authorization
    )
  end)

  it("recovers from malformed credentials and rejects incomplete saved identities", function()
    assert.is_true(store.update("openai", 42))
    auth.authenticate()
    assert.equals("dynamic_agent_client", parse_form(opened_url).client_id)

    local invalid_client = credentials()
    invalid_client.client_id = 42
    assert.is_true(store.update("openai", invalid_client))
    auth.authenticate()
    assert.equals("dynamic_agent_client", parse_form(opened_url).client_id)

    for _, field in ipairs({ "subject", "id_token" }) do
      local token = credentials()
      token[field] = nil
      assert.is_true(store.update("openai", token))
      auth.setup({})
      assert.is_nil(auth.get_token())
      assert.is_nil(store.read().openai)
    end
  end)

  it("registers, stores, and reauthorizes the same installation and identity", function()
    assert.is_true(store.update("claude", { access_token = "other-provider" }))
    auth.authenticate()
    local first = parse_form(opened_url)
    assert.equals("dynamic_agent_client", first.client_id)
    assert.equals("Avante", first.agent_name_hint)
    assert.equals(scope, first.scope)
    assert.equals("https://api.openai.com/v1", first.resource)
    assert.equals("S256", first.code_challenge_method)
    assert.equals(callback.state, first.state)
    callback.success("code+with&symbols", { client_id = "oaiapp_test" })
    assert.equals("https://auth.openai.com/api/accounts/oauth/token", posts[1].url)
    assert.equals("authorization_code", posts[1].body.grant_type)
    assert.equals("oaiapp_test", posts[1].body.client_id)
    assert.equals("code+with&symbols", posts[1].body.code)
    assert.equals(first.redirect_uri, posts[1].body.redirect_uri)
    assert.equals(first.code_challenge, require("avante.auth.pkce").generate_challenge(posts[1].body.code_verifier))
    assert.equals("user-1", store.read().openai.subject)
    assert.equals("other-provider", store.read().claude.access_token)
    if vim.fn.has("unix") == 1 then assert.equals(384, bit.band(vim.uv.fs_stat(store.path()).mode, 511)) end
    assert.equals("Bearer new-access", auth.get_headers({ auth_type = "chatgpt" }, {}).Authorization)

    auth.authenticate()
    local returning = parse_form(opened_url)
    assert.equals(first.ext_agent_host_id, returning.ext_agent_host_id)
    assert.equals("oaiapp_test", returning.client_id)
    assert.equals("valid-id", returning.id_token_hint)
    assert.is_nil(returning.agent_name_hint)
    assert.not_equals(first.state, returning.state)
    assert.not_equals(first.nonce, returning.nonce)
    callback.success("returning-code", {})
    assert.equals("oaiapp_test", posts[2].body.client_id)
  end)

  it("leaves credentials untouched when sign-in is incomplete or unauthorized", function()
    for _, change in ipairs({
      function() response.scope = "openid profile" end,
      function() response.id_token = "invalid-id" end,
      function() response.access_token = nil end,
      function() response.refresh_token = nil end,
    }) do
      store.write_all({})
      auth.state.openai_token = nil
      response = {
        access_token = "new-access",
        refresh_token = "new-refresh",
        expires_in = 3600,
        id_token = "valid-id",
        scope = scope,
      }
      change()
      auth.authenticate()
      callback.success("code", { client_id = "oaiapp_test" })
      assert.is_nil(auth.get_token())
      assert.is_nil(store.read().openai)
    end
    auth.authenticate()
    local count = #posts
    callback.success("code", {})
    assert.equals(count, #posts)
    assert.is_nil(auth.get_token())
  end)

  it("rejects a changed registration or identity during reauthorization", function()
    auth.state.openai_token = credentials()
    auth.authenticate()
    callback.success("code", { client_id = "oaiapp_other" })
    assert.equals(0, #posts)
    package.loaded["avante.auth.oidc"].validate = function() return { sub = "different-user" } end
    auth.authenticate()
    callback.success("code", {})
    assert.equals("old-access", auth.get_token().access_token)
  end)

  it("closes the listener when the browser cannot open", function()
    vim.ui.open = function() return nil, "No browser launcher" end
    auth.authenticate()
    assert.is_true(server_stopped)
    assert.equals(0, #posts)
    assert.is_nil(auth.get_token())
  end)

  it("stops before sign-in when signature verification is unavailable", function()
    local token = credentials()
    assert.is_true(store.update("openai", token))
    auth.state.openai_token = token
    package.loaded["avante.auth.oidc"].check_available = function() return false, "OpenSSL is unavailable" end
    auth.authenticate()
    assert.is_true(server_stopped)
    assert.is_nil(callback)
    assert.is_nil(opened_url)
    assert.equals(0, #posts)
    assert.equals("old-access", store.read().openai.access_token)
  end)

  it("rotates both tokens and reloads another process's completed refresh", function()
    auth._is_setup = true
    auth.state.openai_token = credentials()
    assert.is_true(store.update("openai", credentials()))
    assert.is_true(auth.refresh_token(false))
    assert.equals("refresh_token", posts[1].body.grant_type)
    assert.equals("oaiapp_test", posts[1].body.client_id)
    assert.equals("old+refresh&token", posts[1].body.refresh_token)
    assert.equals("https://api.openai.com/v1", posts[1].body.resource)
    assert.equals("new-refresh", store.read().openai.refresh_token)
    assert.equals("user-1", store.read().openai.subject)
    auth.state.openai_token = credentials()
    assert.is_false(auth.refresh_token(false))
    assert.equals(1, #posts)
    assert.equals("new-access", auth.get_token().access_token)
  end)

  it("preserves credentials and releases the refresh lock after failure", function()
    auth.state.openai_token = credentials()
    assert.is_true(store.update("openai", credentials()))
    -- A Neovim process that exited must not leave refresh permanently blocked.
    local owner = vim.system({ vim.v.progpath, "--version" })
    owner:wait()
    Path:new(data_dir .. "/avante/openai-refresh.lock"):write(tostring(owner.pid), "w")
    response.refresh_token = nil
    assert.is_false(auth.refresh_token(false))
    assert.equals("old-access", auth.get_token().access_token)
    local successful_post = curl.post
    curl.post = function() error("network unavailable") end
    assert.is_false(auth.refresh_token(false))
    curl.post = successful_post
    response.refresh_token = "rotated"
    assert.is_true(auth.refresh_token(false))
    assert.equals("rotated", store.read().openai.refresh_token)
  end)

  it("serializes refreshes from independent auth instances", function()
    local complete
    curl.post = function(_, opts)
      complete = opts.callback
      return {}
    end
    auth.state.openai_token = credentials()
    assert.is_true(auth.refresh_token(true))
    -- Holding the refresh lock must still allow writes for other providers.
    assert.is_true(store.update("claude", { access_token = "other-provider" }))
    package.loaded["avante.auth.providers.openai"] = nil
    local other = require("avante.auth.providers.openai")
    other.state.openai_token = credentials()
    assert.is_false(other.refresh_token(false))
    complete({ status = 200, body = vim.json.encode(response) })
    assert.is_true(vim.wait(1000, function() return not auth._refresh_in_flight end))
    assert.is_false(other.refresh_token(false))
    assert.equals("new-access", other.get_token().access_token)
    assert.equals("other-provider", store.read().claude.access_token)
    other.cleanup()
  end)

  it("watches successive atomic credential replacements", function()
    local observed
    local unwatch = store.watch(function(data) observed = data and data.openai end)
    store.update("openai", { access_token = "first" })
    assert.is_true(vim.wait(1000, function() return observed and observed.access_token == "first" end))
    store.update("openai", { access_token = "second" })
    assert.is_true(vim.wait(1000, function() return observed and observed.access_token == "second" end))
    unwatch()
  end)
end)
