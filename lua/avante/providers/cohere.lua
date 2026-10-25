---@mod avante-providers-cohere Cohere provider
local Providers = require("avante.providers")

local M = {}

M.api_key_name = "CO_API_KEY"
M.tokenizer_id = "https://storage.googleapis.com/cohere-public/tokenizers/command-r-08-2024.json"

function M.setup()
  Providers.env.parse_envvar(M)
  require("avante.tokenizers").setup(M.tokenizer_id, false)
  vim.g.avante_login = true
end

return M
