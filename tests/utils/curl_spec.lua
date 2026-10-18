local stub = require("luassert.stub")

local SECRET = "sk-test-SECRET123"
local URL = "https://api.example.com/v1/models"

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function exists(path) return vim.uv.fs_stat(path) ~= nil end

describe("avante.utils.curl", function()
  local Curl = require("avante.utils.curl")
  local plenary_curl = require("plenary.curl")
  local get, post
  ---@type { opts: table }[]
  local requests
  ---@type { path: string, mode: integer, content: string }[]
  local files

  -- Stands in for plenary.curl, recording the files handed to curl while they still exist
  local function fake_curl(result)
    return function(_, opts)
      table.insert(requests, { opts = opts })
      for i, arg in ipairs(opts.raw or {}) do
        local path = arg:match("^@(.+)") or (opts.raw[i - 1] == "--config" and arg)
        if path then
          local mode = bit.band(assert(vim.uv.fs_stat(path)).mode, 511)
          table.insert(files, { path = path, mode = mode, content = read_file(path) })
        end
      end
      return result
    end
  end

  before_each(function()
    requests, files = {}, {}
    get = stub(plenary_curl, "get", fake_curl({ status = 200 }))
    post = stub(plenary_curl, "post", fake_curl({ status = 200 }))
  end)

  after_each(function()
    get:revert()
    post:revert()
  end)

  it("sends the headers from a file only the user can read instead of the command line", function()
    local opts = {
      headers = { Authorization = "Bearer " .. SECRET, content_type = "application/json" },
      raw = { "--max-time", "5" },
    }
    assert.same({ status = 200 }, Curl.get(URL, opts))

    local sent = requests[1].opts
    assert.is_nil(sent.headers)
    assert.is_nil(vim.inspect(sent):find(SECRET, 1, true))
    assert.same({ "-H", "@" .. files[1].path, "--max-time", "5" }, sent.raw)
    assert.equals(tonumber("600", 8), files[1].mode)
    local lines = vim.split(files[1].content, "\n", { trimempty = true })
    table.sort(lines)
    -- Same header names as plenary.curl sends
    assert.same({ "Authorization: Bearer " .. SECRET, "Content-Type: application/json" }, lines)
    assert.is_false(exists(files[1].path))
    -- The caller's options are left alone
    assert.equals("application/json", opts.headers.content_type)
  end)

  it("removes the files once an async request completes", function()
    local job = {}
    post.invokes(fake_curl(job))
    local callback = stub.new()
    assert.equals(job, Curl.post(URL, { headers = { ["x-api-key"] = SECRET }, callback = callback }))
    assert.is_true(exists(files[1].path))

    requests[1].opts.callback({ status = 200 })
    assert.is_false(exists(files[1].path))
    assert.stub(callback).was_called_with({ status = 200 })
  end)

  it("removes the files once an async request fails", function()
    local on_error = stub.new()
    Curl.post(URL, { headers = { ["x-api-key"] = SECRET }, stream = function() end, on_error = on_error })
    assert.is_true(exists(files[1].path))

    requests[1].opts.on_error({ exit = 7, message = "curl failed" })
    assert.is_false(exists(files[1].path))
    assert.stub(on_error).was_called_with({ exit = 7, message = "curl failed" })
  end)

  it("still raises plenary.curl's error for failed async requests without on_error", function()
    Curl.get(URL, { headers = { Authorization = "token " .. SECRET }, callback = function() end })
    assert.has_error(function() requests[1].opts.on_error({ exit = 7, message = "curl failed" }) end, "curl failed")
    assert.is_false(exists(files[1].path))
  end)

  it("returns a function that removes the files right away", function()
    local _, cleanup = Curl.post(URL, { headers = { ["x-api-key"] = SECRET }, stream = function() end })
    assert.is_true(exists(files[1].path))
    cleanup()
    assert.is_false(exists(files[1].path))
  end)

  it("removes the files when curl cannot be started", function()
    post.invokes(function(...)
      fake_curl()(...)
      error("curl: Executable not found")
    end)
    assert.has_error(function()
      Curl.post(URL, { headers = { ["x-api-key"] = SECRET }, callback = function() end })
    end, "curl: Executable not found")
    assert.is_false(exists(files[1].path))
  end)

  it("sends a string body from a file only the user can read instead of the command line", function()
    local body = "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=" .. SECRET
    Curl.post(URL, { headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }, body = body })

    local sent = requests[1].opts
    assert.is_nil(sent.body)
    assert.is_nil(vim.inspect(sent):find(SECRET, 1, true))
    assert.same({ "-H", "@" .. files[1].path, "--data-binary", "@" .. files[2].path }, sent.raw)
    assert.equals(body, files[2].content)
    assert.equals(tonumber("600", 8), files[2].mode)
    assert.is_false(exists(files[2].path))
  end)

  it("leaves a body that is the path of a file to plenary.curl", function()
    local body_file = vim.fn.tempname()
    vim.fn.writefile({ "{}" }, body_file)
    Curl.post(URL, { body = body_file })
    assert.same({ body = body_file }, requests[1].opts)
    os.remove(body_file)
  end)

  it("passes auth through a curl config file instead of --user", function()
    Curl.post(URL, { auth = 'AKIDTEST:se"cr\\et-' .. SECRET, raw = { "--aws-sigv4", "aws:amz:us-east-1:bedrock" } })

    local sent = requests[1].opts
    assert.is_nil(sent.auth)
    assert.is_nil(vim.inspect(sent):find(SECRET, 1, true))
    assert.same({ "--config", files[1].path, "--aws-sigv4", "aws:amz:us-east-1:bedrock" }, sent.raw)
    assert.equals('user = "AKIDTEST:se\\"cr\\\\et-' .. SECRET .. '"\n', files[1].content)
    assert.equals(tonumber("600", 8), files[1].mode)
    assert.is_false(exists(files[1].path))
  end)

  it("hands requests without headers, body or auth to plenary.curl as they are", function()
    local opts = { timeout = 1000, raw = { "--max-time", "5" } }
    Curl.get(URL, opts)
    assert.same(opts, requests[1].opts)
  end)
end)
