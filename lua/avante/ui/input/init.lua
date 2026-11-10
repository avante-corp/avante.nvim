local Utils = require("avante.utils")

---@class avante.ui.InputOption
---@field provider avante.InputProvider
---@field title string
---@field default string | nil
---@field completion string | nil
---@field provider_opts table | nil
---@field on_submit fun(result: string | nil)
---@field conceal boolean | nil -- Whether to conceal input (for passwords)

---@class avante.ui.Input
---@field provider avante.InputProvider
---@field title string
---@field default string | nil
---@field completion string | nil
---@field provider_opts table | nil
---@field on_submit fun(result: string | nil)
---@field conceal boolean | nil
local Input = {}
Input.__index = Input

---@param opts avante.ui.InputOption
---@return avante.ui.Input
function Input:new(opts)
  ---@type avante.ui.Input
  local input = {
    provider = opts.provider,
    title = opts.title,
    default = opts.default or "",
    completion = opts.completion,
    provider_opts = opts.provider_opts or {},
    on_submit = opts.on_submit,
    conceal = opts.conceal or false,
  }
  return setmetatable(input, Input)
end

function Input:open()
  if type(self.provider) == "function" then
    self.provider(self)
    return
  end

  local ok, provider = pcall(require, "avante.ui.input.providers." .. self.provider)
  if not ok then Utils.error("Unknown input provider: " .. self.provider) end
  provider.show(self)
end

return Input
