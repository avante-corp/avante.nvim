local Utils = require("avante.utils")

---@class AvanteTokenizer
---@field from_pretrained fun(model: string): nil
---@field encode fun(string): integer[]
local tokenizers = nil

---@type "gpt-4o" | string
local current_model = "gpt-4o"

local M = {}

---@param model "gpt-4o" | string
---@return AvanteTokenizer|nil
function M._init_tokenizers_lib(model)
  if tokenizers ~= nil then return tokenizers end

  local ok, core = pcall(require, "avante_tokenizers")
  if not ok then return nil end

  ---@cast core AvanteTokenizer
  tokenizers = core

  core.from_pretrained(model)

  return tokenizers
end

---@param model "gpt-4o" | string
---@param warning? boolean
function M.setup(model, warning)
  current_model = model
  warning = warning or true
  vim.defer_fn(function() M._init_tokenizers_lib(model) end, 1000)

  if warning then
    local HF_TOKEN = os.getenv("HF_TOKEN")
    if HF_TOKEN == nil and model ~= "gpt-4o" then
      Utils.warn(
        "Please set HF_TOKEN environment variable to use HuggingFace tokenizer if " .. model .. " is gated",
        { once = true }
      )
    end
  end
end

---@return boolean
function M.available() return M._init_tokenizers_lib(current_model) ~= nil end

---@param prompt string
---@return integer[]?
function M.encode(prompt)
  if not M.available() then return nil end
  if not prompt or prompt == "" then return nil end
  if type(prompt) ~= "string" then error("Prompt is not type string", 2) end

  local success, result = pcall(tokenizers.encode, prompt)
  -- Some output like terminal command output might not be utf-8 encoded, which will cause an error here
  if not success then
    Utils.warn("Failed to encode prompt: " .. result)
    return nil
  end
  return result
end

---@param prompt string
---@return integer
function M.count(prompt)
  if not M.available() then return math.ceil(#prompt * 0.5) end

  local tokens = M.encode(prompt)
  if not tokens then return 0 end
  return #tokens
end

return M
