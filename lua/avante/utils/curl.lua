---@mod avante-utils-curl Curl wrapper
---@brief [[
---
--- HTTP GET/POST requests using curl. Headers and auth are read from private files,
--- and the request body is sent through stdin, keeping secrets off the command line.
--- Temporary files are removed when the process exits.
---
---@brief ]]

---@class avante.utils.curl.Response
---@field status integer
---@field body string
---@field exit integer

---@class avante.utils.curl.Error
---@field message string
---@field stderr string
---@field exit integer

---@class avante.utils.curl.Job: vim.SystemObj
---@field wait fun(self: avante.utils.curl.Job, timeout?: integer): avante.utils.curl.Job

---@class avante.utils.curl.Options
---@field headers? table<string, string>
---@field body? string
---@field auth? string
---@field timeout? integer
---@field proxy? string
---@field insecure? boolean
---@field callback? fun(response: avante.utils.curl.Response)
---@field on_error? fun(err: avante.utils.curl.Error)

local M = {}

---@param method "GET"|"POST"
---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|avante.utils.curl.Job
---@return fun() cleanup
local function request(method, url, opts)
  opts = opts or {}
  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
    "--request",
    method,
    "--write-out",
    "\n%{http_code}",
    "--url",
    url,
  }
  local files = {} ---@type string[]
  local function cleanup()
    for _, path in ipairs(files) do
      os.remove(path)
    end
  end

  ---@param content string
  ---@return string
  local function private_file(content)
    local path = vim.fn.tempname()
    local fd, err = vim.uv.fs_open(path, "wx", 384) -- 0600, created exclusively
    if not fd then
      cleanup()
      error(err, 0)
    end
    table.insert(files, path)
    local written, write_err = vim.uv.fs_write(fd, content)
    vim.uv.fs_close(fd)
    if not written then
      cleanup()
      error(write_err, 0)
    end
    return path
  end

  if opts.headers and next(opts.headers) then
    local headers = {}
    for name, value in pairs(opts.headers) do
      table.insert(headers, name:gsub("_", "-") .. ": " .. value)
    end
    vim.list_extend(args, { "--header", "@" .. private_file(table.concat(headers, "\n")) })
  end
  if opts.auth then
    local auth = opts.auth:gsub('[\\"]', "\\%0")
    vim.list_extend(args, { "--config", private_file('user = "' .. auth .. '"\n') })
  end
  if opts.body then vim.list_extend(args, { "--data-binary", "@-" }) end
  if opts.proxy then vim.list_extend(args, { "--proxy", opts.proxy }) end
  if opts.insecure then table.insert(args, "--insecure") end
  if package.config:sub(1, 1) ~= "\\" then table.insert(args, "--compressed") end

  local completed = false
  ---@param result vim.SystemCompleted
  ---@return avante.utils.curl.Response
  local function finish(result)
    cleanup()
    completed = true
    ---@type string|nil, string|nil
    local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)$")
    local exit = result.code
    if exit == 0 and result.signal ~= 0 then exit = 128 + result.signal end
    local invalid_response = exit == 0 and not status
    if invalid_response then exit = 1 end
    local response = { status = tonumber(status) or 0, body = (body or ""):gsub("\n$", ""), exit = exit }
    if exit ~= 0 then
      local stderr = result.stderr or ""
      local message = stderr ~= "" and stderr
        or (invalid_response and "Invalid HTTP response" or ("curl exited with code " .. exit))
      local err = { message = message, stderr = stderr, exit = exit }
      if not opts.on_error then error(message, 0) end
      opts.on_error(err)
    elseif opts.callback then
      opts.callback(response)
    end
    return response
  end

  local ok, job = pcall(
    vim.system,
    args,
    { text = true, stdin = opts.body, timeout = opts.timeout },
    opts.callback and finish or nil
  )
  if not ok then
    cleanup()
    error(job, 0)
  end
  if opts.callback then
    ---@cast job avante.utils.curl.Job
    -- Keep callbacks complete before Job:wait() returns, and raise on timeout.
    job.wait = function(self, timeout)
      if not vim.wait(timeout or 5000, function() return completed end, 10, true) then
        error("curl request timed out", 0)
      end
      return self
    end
    return job, cleanup
  end
  return finish(job:wait(opts.timeout or 10000)), cleanup
end

---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|avante.utils.curl.Job
---@return fun() cleanup
function M.get(url, opts) return request("GET", url, opts) end

---@param url string
---@param opts? avante.utils.curl.Options
---@return avante.utils.curl.Response|avante.utils.curl.Job
---@return fun() cleanup
function M.post(url, opts) return request("POST", url, opts) end

return M
