---@diagnostic disable: duplicate-set-field, need-check-nil
local test_util = require("avante.utils.test")
local pkce = require("avante.auth.pkce")

-- Mock data helpers
local function create_mock_token_data(expired)
  local now = os.time()
  local expires_at = expired and (now - 3600) or (now + 1800)
  return {
    access_token = "mock_access_token_123",
    refresh_token = "mock_refresh_token_456",
    expires_at = expires_at,
  }
end

local function create_mock_token_response()
  return {
    access_token = "mock_access_token_abcdef123456",
    refresh_token = "mock_refresh_token_xyz789",
    expires_in = 1800,
    token_type = "Bearer",
  }
end

local function wait_for_schedule() vim.wait(100) end

describe("claude provider", function()
  -- PKCE Implementation Tests
  describe("PKCE implementation", function()
    describe("generate_verifier", function()
      it("should return a non-empty string", function()
        local verifier, err = pkce.generate_verifier()
        assert.not_nil(verifier)
        assert.is_nil(err)
        assert.is_string(verifier)
        assert.is_true(#verifier > 0)
      end)

      it("should generate URL-safe base64 string (no +, /, or =)", function()
        local verifier, err = pkce.generate_verifier()
        assert.is_nil(err)
        assert.is_false(verifier:match("[+/=]") ~= nil, "Verifier should not contain +, /, or =")
      end)

      it("should generate verifier within valid length range (43-128 chars)", function()
        local verifier, err = pkce.generate_verifier()
        assert.is_nil(err)
        assert.is_true(#verifier >= 43 and #verifier <= 128, "Verifier length should be 43-128 characters")
      end)

      it("should generate different verifiers on multiple calls", function()
        local verifier1, err1 = pkce.generate_verifier()
        local verifier2, err2 = pkce.generate_verifier()
        assert.is_nil(err1)
        assert.is_nil(err2)
        assert.not_equal(verifier1, verifier2)
      end)
    end)

    describe("generate_challenge", function()
      it("should return a non-empty string", function()
        local verifier = "test_verifier_123456"
        local challenge, err = pkce.generate_challenge(verifier)
        assert.not_nil(challenge)
        assert.is_nil(err)
        assert.is_string(challenge)
        assert.is_true(#challenge > 0)
      end)

      it("should be deterministic (same verifier produces same challenge)", function()
        local verifier = "test_verifier_123456"
        local challenge1, err1 = pkce.generate_challenge(verifier)
        local challenge2, err2 = pkce.generate_challenge(verifier)
        assert.is_nil(err1)
        assert.is_nil(err2)
        assert.equals(challenge1, challenge2)
      end)

      it("should generate URL-safe base64 string (no +, /, or =)", function()
        local verifier = "test_verifier_123456"
        local challenge, err = pkce.generate_challenge(verifier)
        assert.is_nil(err)
        assert.is_false(challenge:match("[+/=]") ~= nil, "Challenge should not contain +, /, or =")
      end)

      it("should generate different challenges for different verifiers", function()
        local verifier1 = "test_verifier_1"
        local verifier2 = "test_verifier_2"
        local challenge1, err1 = pkce.generate_challenge(verifier1)
        local challenge2, err2 = pkce.generate_challenge(verifier2)
        assert.is_nil(err1)
        assert.is_nil(err2)
        assert.not_equal(challenge1, challenge2)
      end)

      it("should generate challenge of correct length for SHA256 (43 chars)", function()
        local verifier = "test_verifier_123456"
        local challenge, err = pkce.generate_challenge(verifier)
        assert.is_nil(err)
        assert.equals(43, #challenge)
      end)
    end)
  end)

  -- Token Storage Tests
  describe("Token storage and retrieval", function()
    local claude_provider
    local claude_auth

    before_each(function()
      -- Reload the provider module to get a fresh state
      package.loaded["avante.providers.claude"] = nil
      package.loaded["avante.auth.providers.claude"] = nil
      package.loaded["avante.auth.store"] = {
        update = function() end,
        read = function() return nil end,
        watch = function() end,
        path = function() return "" end,
      }
      claude_provider = require("avante.providers.claude")
      claude_auth = require("avante.auth.providers.claude")
    end)

    describe("store_tokens", function()
      it("should store tokens with correct structure in state", function()
        -- Initialize state
        claude_auth.state = { claude_token = nil }

        local mock_tokens = create_mock_token_response()
        local original_time = os.time()

        -- Mock file operations to avoid actual file I/O
        local original_open = io.open
        io.open = function(path, mode)
          return {
            write = function() end,
            close = function() end,
          }
        end

        -- Mock vim.fn.system to avoid actual chmod
        local original_system = vim.fn.system
        vim.fn.system = function() end

        claude_provider.store_tokens(mock_tokens)

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        -- Restore mocks
        io.open = original_open
        vim.fn.system = original_system

        assert.not_nil(claude_auth.state.claude_token)
        assert.equals(mock_tokens.access_token, claude_auth.state.claude_token.access_token)
        assert.equals(mock_tokens.refresh_token, claude_auth.state.claude_token.refresh_token)
        assert.is_number(claude_auth.state.claude_token.expires_at)
        -- expires_at should be approximately now + expires_in
        assert.is_true(claude_auth.state.claude_token.expires_at > original_time)
      end)

      it("should include all required fields", function()
        claude_auth.state = { claude_token = nil }

        local mock_tokens = create_mock_token_response()

        -- Mock file operations
        local original_open = io.open
        io.open = function(path, mode)
          return {
            write = function() end,
            close = function() end,
          }
        end
        local original_system = vim.fn.system
        vim.fn.system = function() end

        claude_provider.store_tokens(mock_tokens)

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        io.open = original_open
        vim.fn.system = original_system

        local token = claude_auth.state.claude_token
        assert.not_nil(token.access_token)
        assert.not_nil(token.refresh_token)
        assert.not_nil(token.expires_at)
      end)
    end)
  end)

  -- Authentication Flow Start Tests
  describe("Authentication flow initiation", function()
    local claude_provider
    local Config
    local captured_oauth_opts

    before_each(function()
      package.loaded["avante.providers.claude"] = nil
      package.loaded["avante.auth.providers.claude"] = nil
      package.loaded["avante.config"] = nil
      package.loaded["avante.ui.oauth"] = nil
      captured_oauth_opts = nil
      Config = require("avante.config")
      -- Set up minimal config
      Config.input = {
        provider = "native",
        provider_opts = {},
      }
      package.loaded["avante.ui.oauth"] = {
        show_auth_url = function(opts) captured_oauth_opts = opts end,
      }
      claude_provider = require("avante.providers.claude")
    end)

    describe("authenticate", function()
      it("should generate PKCE parameters", function()
        -- Mock vim.notify to prevent notifications
        local original_notify = vim.notify
        vim.notify = function() end

        -- Mock the Input module to prevent UI from actually opening
        package.loaded["avante.ui.input"] = {
          new = function()
            return {
              open = function() end,
            }
          end,
        }

        claude_provider.authenticate()

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        vim.notify = original_notify

        -- Verify URL was generated with PKCE parameters
        assert.not_nil(captured_oauth_opts)
        assert.is_true(captured_oauth_opts.auth_url:match("code_challenge=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("code_challenge_method=S256") ~= nil)
      end)

      it("should construct authorization URL with correct parameters", function()
        local original_notify = vim.notify
        vim.notify = function() end

        package.loaded["avante.ui.input"] = {
          new = function()
            return {
              open = function() end,
            }
          end,
        }

        claude_provider.authenticate()

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        vim.notify = original_notify

        -- Check for required OAuth parameters
        assert.not_nil(captured_oauth_opts)
        assert.is_true(captured_oauth_opts.auth_url:match("client_id=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("response_type=code") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("redirect_uri=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("scope=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("state=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("code_challenge=") ~= nil)
        assert.is_true(captured_oauth_opts.auth_url:match("code_challenge_method=S256") ~= nil)
      end)

      it("should use correct OAuth endpoint", function()
        local original_notify = vim.notify
        vim.notify = function() end

        package.loaded["avante.ui.input"] = {
          new = function()
            return {
              open = function() end,
            }
          end,
        }

        claude_provider.authenticate()

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        vim.notify = original_notify

        assert.not_nil(captured_oauth_opts)
        assert.is_true(captured_oauth_opts.auth_url:match("^https://claude.ai/oauth/authorize") ~= nil)
      end)

      it("should fallback to clipboard when vim.ui.open fails", function()
        -- Mock vim.ui.open to fail
        local original_open = vim.ui.open
        vim.ui.open = function(url) error("Browser open failed") end

        -- Mock clipboard operations
        local clipboard_content = nil
        local original_setreg = vim.fn.setreg
        vim.fn.setreg = function(reg, content) clipboard_content = content end

        local original_notify = vim.notify
        local notify_called = false
        vim.notify = function(msg, level) notify_called = true end

        package.loaded["avante.ui.input"] = {
          new = function()
            return {
              open = function() end,
            }
          end,
        }

        claude_provider.authenticate()

        -- Wait for vim.schedule callback to execute
        wait_for_schedule()

        assert.not_nil(captured_oauth_opts)
        captured_oauth_opts.on_open({
          auth_url = captured_oauth_opts.auth_url,
          close = function() end,
        })

        vim.ui.open = original_open
        vim.fn.setreg = original_setreg
        vim.notify = original_notify

        -- Should have copied URL to clipboard
        assert.not_nil(clipboard_content)
        assert.is_true(clipboard_content:match("^https://claude.ai/oauth/authorize") ~= nil)
        assert.is_true(notify_called)
      end)
    end)
  end)

  -- Token Refresh Logic Tests
  describe("Token refresh logic", function()
    local claude_provider
    local claude_auth
    local curl

    before_each(function()
      package.loaded["avante.providers.claude"] = nil
      package.loaded["avante.auth.providers.claude"] = nil
      package.loaded["plenary.curl"] = nil
      claude_provider = require("avante.providers.claude")
      claude_auth = require("avante.auth.providers.claude")
      curl = require("plenary.curl")
    end)

    describe("refresh_token", function()
      it("should exit early when no state exists", function()
        claude_auth.state = nil
        local result = claude_provider.refresh_token(false, false)
        assert.is_false(result)
      end)

      it("should exit early when no token exists in state", function()
        claude_auth.state = { claude_token = nil }
        local result = claude_provider.refresh_token(false, false)
        assert.is_false(result)
      end)

      it("should skip refresh when token is not expired and not forced", function()
        local non_expired_token = create_mock_token_data(false)
        claude_auth.state = { claude_token = non_expired_token }

        local result = claude_provider.refresh_token(false, false)
        assert.is_false(result)
      end)

      it("should proceed when forced even if token not expired", function()
        local non_expired_token = create_mock_token_data(false)
        claude_auth.state = { claude_token = non_expired_token }

        -- Mock curl.post
        local original_post = curl.post
        local post_called = false
        curl.post = function(url, opts)
          post_called = true
          return {
            status = 200,
            body = vim.json.encode(create_mock_token_response()),
          }
        end

        -- Mock file operations
        local original_open = io.open
        io.open = function(path, mode)
          return {
            write = function() end,
            close = function() end,
          }
        end
        local original_system = vim.fn.system
        vim.fn.system = function() end

        claude_provider.refresh_token(false, true)

        -- Wait for any vim.schedule callbacks to complete
        wait_for_schedule()

        curl.post = original_post
        io.open = original_open
        vim.fn.system = original_system

        assert.is_true(post_called)
      end)

      it("should make POST request with correct structure", function()
        local expired_token = create_mock_token_data(true)
        claude_auth.state = { claude_token = expired_token }

        local captured_url = nil
        local captured_body = nil
        local captured_headers = nil

        -- Mock curl.post
        local original_post = curl.post
        curl.post = function(url, opts)
          captured_url = url
          if opts.body then captured_body = vim.json.decode(opts.body) end
          captured_headers = opts.headers
          return {
            status = 200,
            body = vim.json.encode(create_mock_token_response()),
          }
        end

        -- Mock file operations
        local original_open = io.open
        io.open = function(path, mode)
          return {
            write = function() end,
            close = function() end,
          }
        end
        local original_system = vim.fn.system
        vim.fn.system = function() end

        claude_provider.refresh_token(false, false)

        -- Wait for any vim.schedule callbacks to complete
        wait_for_schedule()

        curl.post = original_post
        io.open = original_open
        vim.fn.system = original_system

        -- Verify request structure
        assert.is_true(captured_url:match("oauth/token") ~= nil)
        assert.not_nil(captured_body)
        assert.equals("refresh_token", captured_body.grant_type)
        assert.not_nil(captured_body.client_id)
        assert.equals(expired_token.refresh_token, captured_body.refresh_token)
        assert.not_nil(captured_headers)
        assert.equals("application/json", captured_headers["Content-Type"])
      end)

      it("should handle successful refresh response", function()
        local expired_token = create_mock_token_data(true)
        claude_auth.state = { claude_token = expired_token }

        local mock_response = create_mock_token_response()

        -- Mock curl.post
        local original_post = curl.post
        curl.post = function(url, opts)
          return {
            status = 200,
            body = vim.json.encode(mock_response),
          }
        end

        -- Mock file operations
        local original_open = io.open
        io.open = function(path, mode)
          return {
            write = function() end,
            close = function() end,
          }
        end
        local original_system = vim.fn.system
        vim.fn.system = function() end

        claude_provider.refresh_token(false, false)

        -- Wait for any vim.schedule callbacks to complete
        wait_for_schedule()

        curl.post = original_post
        io.open = original_open
        vim.fn.system = original_system

        -- Verify token was updated in state
        assert.equals(mock_response.access_token, claude_auth.state.claude_token.access_token)
        assert.equals(mock_response.refresh_token, claude_auth.state.claude_token.refresh_token)
      end)

      it("should handle error response (status >= 400)", function()
        local expired_token = create_mock_token_data(true)
        claude_auth.state = { claude_token = expired_token }

        -- Mock curl.post to return error
        local original_post = curl.post
        local original_notify = vim.notify
        curl.post = function(url, opts)
          return {
            status = 401,
            body = vim.json.encode({ error = "invalid_grant" }),
          }
        end

        -- Mock vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.ERROR then
            assert.matches('[401]Failed to refresh access token: {"error":"invalid_grant"}', msg, nil, true)
          end
        end
        local result = claude_provider.refresh_token(false, false)

        -- Wait for any vim.schedule callbacks to complete
        wait_for_schedule()

        -- Should not crash and return gracefully
        -- State should remain unchanged
        assert.equals(expired_token.access_token, claude_auth.state.claude_token.access_token)

        curl.post = original_post
        vim.notify = original_notify
      end)
    end)
  end)

  -- Lockfile Management Tests
  describe("Lockfile management", function()
    -- Note: These tests are more integration-style as the functions are local to the module
    -- We test the observable behavior rather than the internal functions directly

    it("should handle lockfile scenarios through setup", function()
      -- This is a basic smoke test that the lockfile logic doesn't crash
      -- More detailed testing would require exposing the internal functions or using integration tests
      local claude_provider = require("avante.providers.claude")

      -- Just verify the module loaded without errors
      assert.not_nil(claude_provider)
      assert.is_function(claude_provider.setup)
    end)
  end)

  -- Provider Setup Tests
  describe("Provider setup", function()
    local claude_provider
    local Config

    before_each(function()
      package.loaded["avante.providers.claude"] = nil
      package.loaded["avante.auth.providers.claude"] = nil
      package.loaded["avante.config"] = nil
      package.loaded["avante.auth.store"] = {
        update = function() end,
        read = function() return nil end,
        watch = function() end,
        path = function() return "" end,
      }
      Config = require("avante.config")
      claude_provider = require("avante.providers.claude")
    end)

    describe("API mode setup", function()
      it("should set correct api_key_name for API auth", function()
        -- Mock the provider config
        local P = require("avante.providers")
        local original_parse = P.parse_config
        P.parse_config = function() return { auth_type = "api" }, {} end

        -- Mock tokenizer setup
        package.loaded["avante.tokenizers"] = {
          setup = function() end,
        }

        Config.provider = "claude"
        P["claude"] = { auth_type = "api" }

        claude_provider.setup()
        local ClaudeAuth = require("avante.auth.providers.claude")

        P.parse_config = original_parse

        -- In API mode, should have set the api_key_name
        assert.not_nil(claude_provider.api_key_name)
        assert.is_true(ClaudeAuth._is_setup)
      end)
    end)

    describe("Max mode setup", function()
      it("should initialize state when nil", function()
        -- Mock everything to prevent actual setup
        local P = require("avante.providers")
        P.parse_config = function() return { auth_type = "max" }, {} end

        package.loaded["avante.tokenizers"] = {
          setup = function() end,
        }

        -- Mock Input
        package.loaded["avante.ui.input"] = {
          new = function()
            return {
              open = function() end,
            }
          end,
        }

        -- Mock vim.notify
        local original_notify = vim.notify
        vim.notify = function() end

        Config.provider = "claude"
        P["claude"] = { auth_type = "max" }
        local ClaudeAuth = require("avante.auth.providers.claude")
        ClaudeAuth.state = nil
        ClaudeAuth.authenticate = function() end

        -- This will trigger authenticate since no token file exists
        -- We're just checking it doesn't crash
        pcall(function() claude_provider.setup() end)

        -- Wait for any vim.schedule callbacks to complete
        wait_for_schedule()

        vim.notify = original_notify

        -- State should have been initialized
        assert.not_nil(ClaudeAuth.state)
      end)
    end)
  end)

  describe("Auth provider headers", function()
    local claude_auth
    local curl

    before_each(function()
      package.loaded["avante.auth.providers.claude"] = nil
      package.loaded["plenary.curl"] = nil
      package.loaded["avante.auth.store"] = {
        update = function() end,
        read = function() return nil end,
        watch = function() end,
        path = function() return "" end,
      }
      claude_auth = require("avante.auth.providers.claude")
      curl = require("plenary.curl")
    end)

    it("returns API key headers in API mode", function()
      local headers = claude_auth.get_headers({ auth_type = "api", api_key_name = "ANTHROPIC_API_KEY" }, {
        parse_api_key = function() return "api-key" end,
      })

      assert.equals("api-key", headers["x-api-key"])
      assert.equals("prompt-caching-2024-07-31", headers["anthropic-beta"])
    end)

    it("returns OAuth headers in max mode", function()
      claude_auth.state = { claude_token = create_mock_token_data(false) }

      local headers = claude_auth.get_headers({ auth_type = "max" }, {
        parse_api_key = function() return nil end,
      })

      assert.equals("Bearer mock_access_token_123", headers.authorization)
      assert.equals("claude-cli/2.1.2 (external, cli)", headers["user-agent"])
      assert.is_true(headers["anthropic-beta"]:match("oauth%-2025%-04%-20") ~= nil)
    end)

    it("refreshes expired OAuth tokens before returning headers", function()
      claude_auth.state = { claude_token = create_mock_token_data(true) }

      local original_post = curl.post
      curl.post = function()
        return {
          status = 200,
          body = vim.json.encode(create_mock_token_response()),
        }
      end

      local headers = claude_auth.get_headers({ auth_type = "max" }, {
        parse_api_key = function() return nil end,
      })

      curl.post = original_post

      assert.equals("Bearer mock_access_token_abcdef123456", headers.authorization)
    end)
  end)
end)
