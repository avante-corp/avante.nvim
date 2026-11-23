local M = {}

---Let user enter freeform value
---@param input avante.ui.Input
function M.show(input)
  local opts = {
    prompt = input.title,
    default = input.default,
    completion = input.completion,
  }

  -- Note: Native vim.ui.input doesn't support concealing
  -- For password input, users should use the snacks provider
  if input.conceal then
    vim.notify_once(
      "Native input provider doesn't support concealed input. Consider using 'snacks' provider for password input.",
      vim.log.levels.WARN
    )
  end

  vim.ui.input(opts, input.on_submit)
end

return M
