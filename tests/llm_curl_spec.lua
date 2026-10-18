local stub = require("luassert.stub")

local SECRET = "sk-test-SECRET123"

describe("llm.curl", function()
  local llm = require("avante.llm")
  local plenary_curl = require("plenary.curl")
  local post, sent, headers_file, headers_mode, stopped

  local provider = {
    parse_curl_args = function()
      return {
        url = "https://api.example.com/v1/chat/completions",
        headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. SECRET },
        body = { model = "test" },
        rawArgs = { "--max-time", "60" },
      }
    end,
    is_disable_stream = function() return false end,
    parse_response = function() end,
  }

  local function request()
    llm.curl({
      provider = provider,
      prompt_opts = { system_prompt = "", messages = {} },
      handler_opts = {
        on_start = function() end,
        on_chunk = function() end,
        on_stop = function(opts) stopped = opts end,
      },
    })
  end

  local function headers_file_content()
    local file = assert(io.open(headers_file, "r"))
    local content = file:read("*a")
    file:close()
    return content
  end

  before_each(function()
    sent, headers_file, headers_mode, stopped = nil, nil, nil, nil
    post = stub(plenary_curl, "post", function(_, opts)
      sent = opts
      local i = vim.fn.index(opts.raw or {}, "-H")
      headers_file = i >= 0 and opts.raw[i + 2]:match("^@(.+)") or nil
      local stat = headers_file and vim.uv.fs_stat(headers_file)
      headers_mode = stat and bit.band(stat.mode, 511)
      return {} -- the job
    end)
  end)

  after_each(function()
    post:revert()
    vim.api.nvim_clear_autocmds({ group = "avante_llm" })
  end)

  it("never puts the request headers on curl's command line", function()
    request()
    assert.is_nil(sent.headers)
    assert.is_nil(vim.inspect(sent):find(SECRET, 1, true))
    assert.same({ "-H", "@" .. headers_file, "--max-time", "60" }, sent.raw)
    assert.equals(tonumber("600", 8), headers_mode)
    assert.truthy(headers_file_content():find("Authorization: Bearer " .. SECRET .. "\n", 1, true))
  end)

  it("removes the headers file once the request completes", function()
    request()
    assert.equals(tonumber("600", 8), headers_mode)
    sent.callback({ status = 200, headers = {}, body = "" })
    assert.is_nil(vim.uv.fs_stat(headers_file))
  end)

  it("removes the headers file when the request fails", function()
    request()
    assert.equals(tonumber("600", 8), headers_mode)
    sent.on_error({ exit = 7, message = "Failed to connect" })
    assert.is_nil(vim.uv.fs_stat(headers_file))
    assert.equals("error", stopped.reason)
  end)

  it("removes the headers file when the request is cancelled", function()
    request()
    assert.equals(tonumber("600", 8), headers_mode)
    vim.api.nvim_exec_autocmds("User", { pattern = llm.CANCEL_PATTERN })
    assert.is_nil(vim.uv.fs_stat(headers_file))
    vim.wait(1000, function() return stopped ~= nil end)
    assert.equals("cancelled", stopped.reason)
  end)
end)
