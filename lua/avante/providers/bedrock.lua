---@mod avante-providers-bedrock Bedrock provider
---@brief [[
---Bedrock can use `BEDROCK_KEYS` or the AWS default credentials chain:
---<
---   export BEDROCK_KEYS=aws_access_key_id,aws_secret_access_key,aws_region[,aws_session_token]
--->
---
--- The `aws_session_token` is optional and only needed for temporary AWS
--- credentials. If `BEDROCK_KEYS` is not set, Bedrock falls back to the AWS
--- default credentials chain (env vars, `~/.aws/credentials`, IAM role, SSO,
--- etc.), in which case set `aws_region` and optionally `aws_profile` in the
--- bedrock provider config.
---
--- Or a Bedrock API key / bearer token: export `AWS_BEARER_TOKEN_BEDROCK`
--- (or set `BEDROCK_KEYS` to the token value without any commas). In this
--- mode `aws_region` must be set in the bedrock provider config, e.g.:
---<
---   export AWS_BEARER_TOKEN_BEDROCK=your-bedrock-api-key
---   require("avante").setup({
---     providers = {
---       bedrock = {
---         model = "us.anthropic.claude-sonnet-4-6",
---         aws_region = "us-east-1",
---       },
---     },
---   })
--->
---See https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html.
---@brief ]]

---@class AvanteBedrockProviderFunctor
local M = {}

M.api_key_name = "BEDROCK_KEYS"

function M.setup() return true end

function M.is_env_set() return true end

return M
