---Drop-in replacement for plenary.curl's `get` and `post` that keeps `headers`, a string `body` and
---`auth` off curl's command line, where any user of the machine can read them (e.g. with `ps`).
---They are written to files only the current user can read, which curl loads with `-H @file`,
---`--data-binary @file` and `--config file`, and the files are removed once curl exits.
local curl = require("plenary.curl")

---@class avante.utils.curl
local M = {}

---@param content string
---@param suffix string
---@return string path
local function write_private_file(content, suffix)
  local path = vim.fn.tempname() .. suffix
  -- Created with mode 0600 (384 in decimal) so others can never read it; "x" fails if it exists
  local fd = assert(vim.uv.fs_open(path, "wx", 384))
  local ok, err = vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
  assert(ok, err)
  return path
end

---Writes headers to a private file in the format of curl's `-H @file`.
---The caller must delete the file once curl has exited.
---@param headers table<string, string>
---@return string path
function M.write_headers_file(headers)
  local lines = {}
  for name, value in pairs(headers) do
    table.insert(lines, name .. ": " .. value .. "\n")
  end
  return write_private_file(table.concat(lines), "-request-headers.txt")
end

---Besides plenary.curl's result, returns a function that removes the private files right away, for
---callers that stop waiting for the request. Otherwise they are removed once curl exits.
---@param method "get" | "post"
---@param url string
---@param opts? table plenary.curl options
---@return any result
---@return fun() cleanup
local function request(method, url, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  local raw = {} ---@type string[]
  local files = {} ---@type string[]
  local function cleanup()
    for _, file in ipairs(files) do
      os.remove(file)
    end
  end

  if opts.headers and next(opts.headers) then
    -- Send the same header names as plenary.curl would, e.g. content_type -> Content-Type
    local headers = {}
    for name, value in pairs(opts.headers) do
      headers[(" " .. name:gsub("_", "-")):gsub("%W%l", string.upper):sub(2)] = value
    end
    table.insert(files, M.write_headers_file(headers))
    vim.list_extend(raw, { "-H", "@" .. files[#files] })
    opts.headers = nil
  end

  -- plenary.curl passes a string body with --data-raw, unless it is the path of a file
  local body_stat = type(opts.body) == "string" and vim.uv.fs_stat(opts.body)
  if type(opts.body) == "string" and not (body_stat and body_stat.type == "file") then
    table.insert(files, write_private_file(opts.body, "-request-body.txt"))
    vim.list_extend(raw, { "--data-binary", "@" .. files[#files] })
    opts.body = nil
  end

  if type(opts.auth) == "string" then
    -- --user has no @file form, but curl reads it from a config file the same way
    local config = string.format('user = "%s"\n', (opts.auth:gsub('[\\"]', "\\%0")))
    table.insert(files, write_private_file(config, "-curl-config.txt"))
    vim.list_extend(raw, { "--config", files[#files] })
    opts.auth = nil
  end

  if #files == 0 then return curl[method](url, opts), cleanup end

  opts.raw = vim.list_extend(raw, opts.raw or {})

  -- A started async request always ends in `callback` or `on_error`, also when its job is shut down
  local async = opts.callback ~= nil or opts.stream ~= nil
  if async then
    local callback, on_error = opts.callback, opts.on_error
    opts.callback = function(...)
      cleanup()
      if callback then return callback(...) end
    end
    opts.on_error = function(err)
      cleanup()
      if on_error then return on_error(err) end
      error(err.message)
    end
  end

  local ok, result = pcall(curl[method], url, opts)
  if not ok or not async then cleanup() end
  if not ok then error(result, 0) end
  return result, cleanup
end

---@param url string
---@param opts? table plenary.curl options
function M.get(url, opts) return request("get", url, opts) end

---@param url string
---@param opts? table plenary.curl options
function M.post(url, opts) return request("post", url, opts) end

return M
