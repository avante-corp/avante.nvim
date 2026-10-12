local curl = require("plenary.curl")
local oidc = require("avante.auth.oidc")

local function base64url(value) return vim.base64.encode(value):gsub("+", "-"):gsub("/", "_"):gsub("=", "") end

local function token(header, claims)
  return base64url(vim.json.encode(header)) .. "." .. base64url(vim.json.encode(claims)) .. "." .. base64url("sig")
end

describe("OpenAI ID-token verification", function()
  local original_get, original_system, claims, header, verify_result

  before_each(function()
    original_get, original_system = curl.get, vim.system
    verify_result = { code = 0, signal = 0 }
    vim.system = function(cmd, opts)
      assert.equals("openssl", cmd[1])
      assert.is_true(vim.tbl_contains(cmd, "-verify"))
      return {
        wait = function(_, timeout)
          assert.equals(10000, timeout)
          assert.equals(base64url(vim.json.encode(header)) .. "." .. base64url(vim.json.encode(claims)), opts.stdin)
          return verify_result
        end,
      }
    end
    curl.get = function(url, opts)
      assert.equals("https://auth.openai.com/.well-known/jwks.json", url)
      assert.equals(10000, opts.timeout)
      return {
        status = 200,
        body = vim.json.encode({
          keys = {
            { kid = "test-key", kty = "RSA", use = "sig", alg = "RS256", n = base64url("n"), e = "AQAB" },
          },
        }),
      }
    end
    header = { alg = "RS256", kid = "test-key" }
    claims = {
      iss = "https://auth.openai.com",
      aud = "oaiapp_test",
      sub = "user-1",
      nonce = "test-nonce",
      exp = os.time() + 3600,
    }
  end)

  after_each(function()
    curl.get, vim.system = original_get, original_system
  end)

  it("accepts an identity when signature verification succeeds", function()
    local identity, err = oidc.validate(token(header, claims), "oaiapp_test", "test-nonce")
    assert.is_nil(err)
    assert.equals("user-1", identity.sub)
  end)

  it("rejects untrusted signatures and mismatched identity claims", function()
    for _, result in ipairs({ { code = 1, signal = 0 }, { code = 0, signal = 11 } }) do
      verify_result = result
      assert.is_nil(oidc.validate(token(header, claims), "oaiapp_test", "test-nonce"))
    end
    vim.system = function() error("could not spawn OpenSSL") end
    assert.is_nil(oidc.validate(token(header, claims), "oaiapp_test", "test-nonce"))
    verify_result = { code = 0, signal = 0 }
    vim.system = function()
      return { wait = function() return verify_result end }
    end

    local original_claims, original_header = vim.deepcopy(claims), vim.deepcopy(header)
    for _, change in ipairs({
      function() claims.iss = "https://other.example" end,
      function() claims.aud = "another-client" end,
      function() claims.nonce = "another-attempt" end,
      function() claims.exp = os.time() - 1 end,
      function() header.alg = "none" end,
    }) do
      claims, header = vim.deepcopy(original_claims), vim.deepcopy(original_header)
      change()
      assert.is_nil(oidc.validate(token(header, claims), "oaiapp_test", "test-nonce"))
    end
  end)
end)

describe("OpenAI crypto availability", function()
  it("reports a missing OpenSSL executable without spawning it", function()
    local original_executable, original_system = vim.fn.executable, vim.system
    vim.system = function() error("tests must not spawn OpenSSL") end
    local ok, err = pcall(function()
      vim.fn.executable = function(name)
        assert.equals("openssl", name)
        return 0
      end
      local available, message = oidc.check_available()
      assert.is_false(available)
      assert.matches("OpenSSL", message)
      vim.fn.executable = function() return 1 end
      assert.is_true(oidc.check_available())
    end)
    vim.fn.executable, vim.system = original_executable, original_system
    assert.is_true(ok, err)
  end)
end)
