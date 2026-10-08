local M = {}

local issuer = "https://auth.openai.com"

local function decode_base64url(value)
  if type(value) ~= "string" or value:find("[^%w_-]") then return nil end
  local padded = value:gsub("-", "+"):gsub("_", "/")
  padded = padded .. string.rep("=", (4 - #padded % 4) % 4)
  local ok, decoded = pcall(vim.base64.decode, padded)
  if ok then return decoded end
end

local function decode_json(value)
  local ok, decoded = pcall(vim.json.decode, value or "")
  if ok and type(decoded) == "table" then return decoded end
end

-- OpenAI publishes RS256 keys. Encode the RSA modulus and exponent as a
-- PKCS#1 public key so OpenSSL handles the signature verification.
local function der(tag, bytes)
  local length = #bytes
  local encoded_length = ""
  if length < 128 then
    encoded_length = string.char(length)
  else
    while length > 0 do
      encoded_length = string.char(length % 256) .. encoded_length
      length = math.floor(length / 256)
    end
    encoded_length = string.char(128 + #encoded_length) .. encoded_length
  end
  return string.char(tag) .. encoded_length .. bytes
end

local function integer(bytes)
  if bytes:byte(1) >= 128 then bytes = "\0" .. bytes end
  return der(2, bytes)
end

local function verify_signature(key, signature, message)
  local modulus, exponent = decode_base64url(key.n), decode_base64url(key.e)
  if not modulus or modulus == "" or not exponent or exponent == "" then return false end
  local encoded = vim.base64.encode(der(48, integer(modulus) .. integer(exponent)))
  local pem = "-----BEGIN RSA PUBLIC KEY-----\n" .. encoded .. "\n-----END RSA PUBLIC KEY-----\n"
  local key_path, signature_path = vim.fn.tempname(), vim.fn.tempname()
  local ok, result = pcall(function()
    require("plenary.path"):new(key_path):write(pem, "w")
    require("plenary.path"):new(signature_path):write(signature, "w")
    return vim
      .system({ "openssl", "dgst", "-sha256", "-verify", key_path, "-signature", signature_path }, { stdin = message })
      :wait(10000)
  end)
  os.remove(key_path)
  os.remove(signature_path)
  return ok and result.code == 0 and result.signal == 0
end

---Neovim has hashing and randomness, but no built-in RSA signature verifier.
---Check a fixed, public test vector before opening the browser. Running OpenSSL
---as a bounded subprocess keeps library/version failures outside Neovim.
---@return boolean available
---@return string|nil error
function M.check_available()
  local err = "OpenAI sign-in requires a working OpenSSL executable with RSA/SHA-256 support on PATH"
  if vim.fn.executable("openssl") ~= 1 then return false, err end
  return true
end

---@param id_token string
---@param client_id string
---@param nonce string
---@return table|nil identity
---@return string|nil error
function M.validate(id_token, client_id, nonce)
  if type(id_token) ~= "string" then return nil, "Missing ID token" end
  local header_part, claims_part, signature_part = id_token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
  local header = decode_json(decode_base64url(header_part))
  local claims = decode_json(decode_base64url(claims_part))
  local signature = decode_base64url(signature_part)
  if not header or header.alg ~= "RS256" or type(header.kid) ~= "string" or not claims or not signature then
    return nil, "Invalid ID token"
  end
  local audience_matches = claims.aud == client_id
    or (type(claims.aud) == "table" and vim.tbl_contains(claims.aud, client_id))
  if
    claims.iss ~= issuer
    or not audience_matches
    or claims.nonce ~= nonce
    or type(claims.exp) ~= "number"
    or claims.exp <= os.time()
    or type(claims.sub) ~= "string"
    or claims.sub == ""
  then
    return nil, "ID token identity, expiry, or nonce did not match"
  end
  local ok, response = pcall(require("plenary.curl").get, issuer .. "/.well-known/jwks.json", { timeout = 10000 })
  local jwks = ok and type(response) == "table" and response.status == 200 and decode_json(response.body)
  if not jwks or type(jwks.keys) ~= "table" then return nil, "Could not fetch OpenAI signing keys" end
  for _, key in ipairs(jwks.keys) do
    if key.kid == header.kid and key.kty == "RSA" and key.use == "sig" and key.alg == "RS256" then
      if verify_signature(key, signature, header_part .. "." .. claims_part) then return claims end
      break
    end
  end
  return nil, "ID token signature verification failed"
end

return M
