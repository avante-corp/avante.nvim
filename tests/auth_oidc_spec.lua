local curl = require("plenary.curl")
local oidc = require("avante.auth.oidc")
local function base64url(value) return vim.base64.encode(value):gsub("+", "-"):gsub("/", "_"):gsub("=", "") end

describe("OpenAI ID-token verification", function()
  local key_path, original_get, claims, header
  local function signed_token()
    local message = base64url(vim.json.encode(header)) .. "." .. base64url(vim.json.encode(claims))
    local signature = vim.system({ "openssl", "dgst", "-sha256", "-sign", key_path }, { stdin = message }):wait()
    assert.equals(0, signature.code)
    return message .. "." .. base64url(signature.stdout)
  end

  before_each(function()
    key_path = vim.fn.tempname()
    local key = vim.system({ "openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048" }):wait()
    assert.equals(0, key.code)
    local fd = assert(vim.uv.fs_open(key_path, "w", 384))
    vim.uv.fs_write(fd, key.stdout, 0)
    vim.uv.fs_close(fd)
    local modulus = vim.system({ "openssl", "rsa", "-in", key_path, "-noout", "-modulus" }):wait()
    local n = base64url(vim.text.hexdecode(vim.trim(modulus.stdout):match("Modulus=(.*)")))
    original_get = curl.get
    curl.get = function(url)
      assert.equals("https://auth.openai.com/.well-known/jwks.json", url)
      return {
        status = 200,
        body = vim.json.encode({
          keys = {
            { kid = "test-key", kty = "RSA", use = "sig", alg = "RS256", n = n, e = "AQAB" },
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
    curl.get = original_get
    os.remove(key_path)
  end)

  it("verifies a signed identity with OpenAI's published key", function()
    assert.is_true(oidc.check_available())
    local identity, err = oidc.validate(signed_token(), "oaiapp_test", "test-nonce")
    assert.is_nil(err)
    assert.equals("user-1", identity.sub)
  end)

  it("rejects untrusted signatures and mismatched identity claims", function()
    local valid = signed_token()
    local head, payload, signature = valid:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    assert.is_nil(oidc.validate(head .. "." .. payload .. "." .. signature:reverse(), "oaiapp_test", "test-nonce"))
    local original = vim.deepcopy(claims)
    for _, change in ipairs({
      function() claims.iss = "https://other.example" end,
      function() claims.aud = "another-client" end,
      function() claims.nonce = "another-attempt" end,
      function() claims.exp = os.time() - 1 end,
      function() header.alg = "none" end,
    }) do
      claims = vim.deepcopy(original)
      change()
      assert.is_nil(oidc.validate(signed_token(), "oaiapp_test", "test-nonce"))
    end
  end)
end)

describe("OpenAI crypto availability", function()
  it("reports missing or failing OpenSSL without raising an error", function()
    local original_executable, original_system = vim.fn.executable, vim.system
    local ok, err = pcall(function()
      vim.fn.executable = function() return 0 end
      assert.is_false(oidc.check_available())
      vim.fn.executable = function() return 1 end
      for _, run in ipairs({
        function() error("could not spawn OpenSSL") end,
        function()
          return { wait = function() return { code = 1 } end }
        end,
        function()
          return { wait = function() return { code = 0, signal = 11 } end }
        end,
      }) do
        vim.system = run
        local available, message = oidc.check_available()
        assert.is_false(available)
        assert.matches("OpenSSL", message)
      end
    end)
    vim.fn.executable, vim.system = original_executable, original_system
    assert.is_true(ok, err)
  end)
end)
