--Taken from https://github.com/jackMort/ChatGPT.nvim/blob/main/lua/chatgpt/flows/chat/tokens.lua
local Tokenizer = require("avante.tokenizers")

---@class avante.utils.tokens
local Tokens = {}

---@type table<[string], number>
local cost_per_token = {
  davinci = 0.000002,
}

--- Calculate the number of tokens in a given text.
---@param content AvanteLLMMessageContent The text to calculate the number of tokens in.
---@return integer The number of tokens in the given text.
function Tokens.calculate_tokens(content)
  local text = ""

  if type(content) == "string" then
    text = content
  elseif type(content) == "table" then
    for _, item in ipairs(content) do
      if type(item) == "string" then
        text = text .. item
      elseif type(item) == "table" and item.type == "text" then
        text = text .. item.text
      elseif type(item) == "table" and item.type == "image" then
        text = text .. item.source.data
      elseif type(item) == "table" and item.type == "tool_result" then
        if type(item.content) == "string" then text = text .. item.content end
      end
    end
  end

  if Tokenizer.available() then return Tokenizer.count(text) end

  local tokens = 0
  local position = 1
  while true do
    local first, last = text:find("[^ \n]+", position)
    if not first then break end
    tokens = tokens + 1
    position = last + 1
  end
  return tokens
end

--- Calculate the cost of a given text in dollars.
-- @param text The text to calculate the cost of.
-- @param model The model to use to calculate the cost.
-- @return The cost of the given text in dollars.
function Tokens.calculate_usage_in_dollars(text, model)
  local tokens = Tokens.calculate_tokens(text)
  return Tokens.usage_in_dollars(tokens, model)
end

--- Calculate the cost of a given number of tokens in dollars.
-- @param tokens The number of tokens to calculate the cost of.
-- @param model The model to use to calculate the cost.
-- @return The cost of the given number of tokens in dollars.
function Tokens.usage_in_dollars(tokens, model) return tokens * cost_per_token[model or "davinci"] end

return Tokens
