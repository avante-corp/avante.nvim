---Renders ACP form elicitations.
---
---This is how an agent asks the user a question mid-turn. claude-agent-acp
---maps its built-in `AskUserQuestion` tool onto `elicitation/create`, and
---*disables that tool entirely* unless the client advertises
---`elicitation.form` (see acp-agent.ts: `disallowedTools = elicitationSupport
---.form ? [] : ["AskUserQuestion"]`). So without this, the agent simply reports
---that no such tool is available.
---
---Schema shape produced by claude-agent-acp:
---  question_<n>          string with `oneOf` enum options   (single select)
---                        or array with `items.anyOf`        (multi select)
---  question_<n>_custom   free-text "Other", always optional
---
---The reply is `{action = "accept", content = { [field] = value }}`, or
---`decline` / `cancel`.

local Utils = require("avante.utils")

local M = {}

local CUSTOM_SUFFIX = "_custom"
local CUSTOM_LABEL = "Type my own answer…"
local SKIP_LABEL = "Skip this question"

---Options for a field, from either `oneOf` or `items.anyOf`.
---@param schema table
---@return table[] options, boolean multi_select
local function field_options(schema)
  if schema.oneOf then return schema.oneOf, false end
  if schema.items and schema.items.anyOf then return schema.items.anyOf, true end
  return {}, schema.type == "array"
end

---Question fields in a stable order, skipping the paired free-text fields.
---@param properties table
---@return string[]
local function ordered_question_fields(properties)
  local keys = {}
  for key, _ in pairs(properties or {}) do
    if not key:match(CUSTOM_SUFFIX .. "$") then table.insert(keys, key) end
  end
  -- Fields are named question_0, question_1, ... so numeric order is the
  -- author's intended order; pairs() would randomise it.
  table.sort(keys, function(a, b)
    local a_num = tonumber(a:match("(%d+)$"))
    local b_num = tonumber(b:match("(%d+)$"))
    if a_num and b_num then return a_num < b_num end
    return a < b
  end)
  return keys
end

---@param field string
---@param schema table
---@param message string
---@param has_custom boolean
---@param callback fun(value: any|nil, cancelled: boolean)
local function ask_one(field, schema, message, has_custom, callback)
  local options, multi_select = field_options(schema)

  local prompt = schema.description or schema.title or message or "Choose an option"

  local choices = {}
  for _, option in ipairs(options) do
    table.insert(choices, {
      label = option.title or option.const,
      value = option.const,
      description = option.description,
    })
  end
  if has_custom then table.insert(choices, { label = CUSTOM_LABEL, custom = true }) end
  table.insert(choices, { label = SKIP_LABEL, skip = true })

  if #choices == 0 then
    callback(nil, false)
    return
  end

  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(choice)
      if choice.description then return choice.label .. "  (" .. choice.description .. ")" end
      return choice.label
    end,
  }, function(choice)
    -- nil means the user pressed <Esc>: abandon the whole elicitation rather
    -- than silently answering nothing.
    if choice == nil then
      callback(nil, true)
      return
    end
    if choice.skip then
      callback(nil, false)
      return
    end
    if choice.custom then
      vim.ui.input({ prompt = (schema.title or "Answer") .. ": " }, function(text)
        if text == nil or text == "" then
          callback(nil, false)
          return
        end
        callback(text, false, true)
      end)
      return
    end
    callback(multi_select and { choice.value } or choice.value, false)
  end)
end

---Present an elicitation and reply.
---@param params table bridge `ui/elicitation` params
---@param reply fun(answer: table)
function M.prompt(params, reply)
  local mode = params.mode or {}
  local schema = mode.requestedSchema or mode.requested_schema or {}
  local properties = schema.properties or {}
  local fields = ordered_question_fields(properties)

  if #fields == 0 then
    -- A form we cannot render (url mode, empty schema). Declining is honest;
    -- the agent can then proceed without the answer.
    Utils.debug("Elicitation had no renderable fields; declining")
    reply({ action = "decline" })
    return
  end

  local content = {}
  local index = 1

  local function next_field()
    if index > #fields then
      if vim.tbl_isempty(content) then
        reply({ action = "decline" })
      else
        reply({ action = "accept", content = content })
      end
      return
    end

    local field = fields[index]
    index = index + 1
    local has_custom = properties[field .. CUSTOM_SUFFIX] ~= nil

    ask_one(field, properties[field], params.message, has_custom, function(value, cancelled, is_custom)
      if cancelled then
        reply({ action = "cancel" })
        return
      end
      if value ~= nil then
        if is_custom then
          content[field .. CUSTOM_SUFFIX] = value
        else
          content[field] = value
        end
      end
      -- Schedule so nested vim.ui.select calls do not stack inside one another.
      vim.schedule(next_field)
    end)
  end

  vim.schedule(next_field)
end

M._ordered_question_fields = ordered_question_fields
M._field_options = field_options

return M
