local stub = require("luassert.stub")
local Curl = require("avante.utils.curl")

local SECRET = "sk-test-SECRET123"
local URL = "https://api.example.com/v1/models"

describe("avante.utils.curl", function()
  local system, args, options, on_exit, result, files

  before_each(function()
    files = {}
    result = { code = 0, signal = 0, stdout = "{}\n200", stderr = "" }
    system = stub(vim, "system", function(command, opts, callback)
      args, options, on_exit = command, opts, callback
      for i, arg in ipairs(args) do
        local path = arg:match("^@(.+)") or (args[i - 1] == "--config" and arg)
        if path and path ~= "-" then
          local file = assert(io.open(path, "r"))
          files[#files + 1] = {
            path = path,
            content = file:read("*a"),
            mode = bit.band(assert(vim.uv.fs_stat(path)).mode, 511),
          }
          file:close()
        end
      end
      return { wait = function() return result end }
    end)
  end)

  after_each(function()
    system:revert()
    for _, file in ipairs(files) do
      assert.is_nil(vim.uv.fs_stat(file.path))
    end
  end)

  it("keeps credentials and body off argv and preserves request options", function()
    local opts = {
      headers = { Authorization = "Bearer " .. SECRET },
      auth = 'user:se"cr\\et-' .. SECRET,
      body = '{"key":"' .. SECRET .. '"}',
      proxy = "http://localhost:8080",
      insecure = true,
      timeout = 1000,
    }
    local original = vim.deepcopy(opts)
    assert.same({ status = 200, body = "{}", exit = 0 }, Curl.post(URL, opts))
    assert.is_nil(table.concat(args, " "):find(SECRET, 1, true))
    assert.equals("Authorization: Bearer " .. SECRET, files[1].content)
    assert.equals('user = "user:se\\"cr\\\\et-' .. SECRET .. '"\n', files[2].content)
    for _, file in ipairs(files) do
      assert.equals(384, file.mode)
    end
    assert.equals(opts.body, options.stdin)
    assert.equals(opts.timeout, options.timeout)
    assert.is_true(vim.tbl_contains(args, opts.proxy))
    assert.is_true(vim.tbl_contains(args, "--insecure"))
    assert.is_true(vim.tbl_contains(args, "@-"))
    assert.same(original, opts)
  end)

  it("returns HTTP errors and empty responses without treating them as transport errors", function()
    result.stdout = "unavailable\n503"
    assert.same({ status = 503, body = "unavailable", exit = 0 }, Curl.get(URL))
    result.stdout = "\n204"
    assert.same({ status = 204, body = "", exit = 0 }, Curl.get(URL))
  end)

  it("completes async callbacks and cleans up private files", function()
    local callback = stub.new()
    local job = Curl.get(URL, { headers = { Authorization = SECRET }, callback = callback })
    assert.is_not_nil(vim.uv.fs_stat(files[1].path))
    on_exit(result)
    job:wait(100)
    assert.stub(callback).was_called_with({ status = 200, body = "{}", exit = 0 })
  end)

  it("reports async transport errors, including termination by a signal", function()
    local on_error = stub.new()
    Curl.get(URL, { headers = { Authorization = SECRET }, callback = function() end, on_error = on_error })
    on_exit({ code = 7, signal = 0, stderr = "connection refused" })
    assert.stub(on_error).was_called_with({ message = "connection refused", stderr = "connection refused", exit = 7 })
    Curl.get(URL, { callback = function() end, on_error = on_error })
    on_exit({ code = 0, signal = 15 })
    assert.equals(143, on_error.calls[2].vals[1].exit)
  end)

  it("raises unhandled transport errors and rejects malformed output", function()
    result = { code = 28, signal = 0, stderr = "request timed out" }
    assert.has_error(function() Curl.get(URL, { headers = { Authorization = SECRET } }) end, "request timed out")
    result = { code = 0, signal = 0, stdout = "invalid" }
    assert.has_error(function() Curl.get(URL) end, "Invalid HTTP response")
    Curl.get(URL, { callback = function() end })
    assert.has_error(function() on_exit({ code = 7, signal = 0, stderr = "curl failed" }) end, "curl failed")
  end)

  it("cleans up when curl cannot start", function()
    system.invokes(function(command)
      for i, arg in ipairs(command) do
        if arg == "--config" then files[1] = { path = command[i + 1] } end
      end
      error("curl: Executable not found", 0)
    end)
    assert.has_error(function() Curl.get(URL, { auth = SECRET }) end, "curl: Executable not found")
    assert.is_not_nil(files[1])
  end)

  it("raises when waiting times out and allows explicit cleanup", function()
    local job, cleanup = Curl.get(URL, { headers = { Authorization = SECRET }, callback = function() end })
    assert.has_error(function() job:wait(1) end, "curl request timed out")
    cleanup()
    assert.is_nil(vim.uv.fs_stat(files[1].path))
    on_exit(result)
  end)
end)

it("waits for a real curl process to finish its callback", function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "{}" }, path)
  local response
  local job = Curl.get("file://" .. path, {
    callback = function(value) response = value end,
  })
  local ok, err = pcall(job.wait, job, 1000)
  os.remove(path)
  assert.is_true(ok, err)
  assert.same({ status = 0, body = "{}", exit = 0 }, response)
end)
