---@mod avante-copilot-auth GitHub Copilot subscriptions
---
---@brief [[
---Copilot defaults to `auth_type = "subscription"`; API-key authentication is
---unsupported. Set `provider = "copilot"`, rebuild the native libraries, and run
---`:Avante copilot login`. Rig displays a GitHub device-code URL and code, saves
---credentials privately in `stdpath("data")/avante/copilot/`, and resolves or
---refreshes the session before inference and account model listing. The normal
---cancel action stops pending authentication or requests.
---
---No copilot.lua or copilot.vim plugin is required. Existing plugin credentials
---and the old `avante/github-copilot.json` cache are not imported: sign in once
---with the new command. Missing credentials require an explicit login.
---
---`:Avante copilot logout` removes local credentials only. Revoke authorization
---separately in GitHub account settings when needed. Other clients' credentials
---remain untouched. Custom endpoints (including GHE authentication hosts), API
---keys, headers, provider-level proxies and insecure TLS are unsupported.
---@brief ]]

local M = {}

M.api_key_name = ""
M.tokenizer_id = "gpt-4o"

---@param timeout? integer
---@return AvanteProviderModelList
function M:list_models(timeout) return require("avante.libs.rig_client").copilot_models(timeout) end

return M
