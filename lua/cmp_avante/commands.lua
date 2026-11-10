local api = vim.api

---@class CommandsSource : cmp.Source
local CommandsSource = {}
CommandsSource.__index = CommandsSource

---@return CommandsSource
function CommandsSource:new()
  local instance = setmetatable({}, CommandsSource)

  return instance
end

function CommandsSource:is_available() return vim.bo.filetype == "AvanteInput" end

function CommandsSource.get_position_encoding_kind() return "utf-8" end

function CommandsSource:get_trigger_characters() return { "/" } end

function CommandsSource:get_keyword_pattern() return [[\%(@\|#\|/\)\k*]] end

---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: lsp.CompletionResponse|nil)
---@return nil
function CommandsSource:complete(params, callback)
  ---@type string?
  local trigger_character
  if params.completion_context.triggerKind == 1 then
    trigger_character = string.match(params.context.cursor_before_line, "%s*(/)%S*$")
  elseif params.completion_context.triggerKind == 2 then
    trigger_character = params.completion_context.triggerCharacter
  end
  if not trigger_character or trigger_character ~= "/" then return callback({ items = {}, isIncomplete = false }) end
  local Utils = require("avante.utils")
  local kind = require("cmp").lsp.CompletionItemKind.Variable
  local commands = Utils.get_commands()

  local items = {}

  for _, command in ipairs(commands) do
    table.insert(items, {
      label = "/" .. command.name,
      kind = kind,
      detail = command.details,
      data = {
        name = command.name,
      },
    })
  end

  callback({
    items = items,
    isIncomplete = false,
  })
end

function CommandsSource:execute(item, callback)
  local Utils = require("avante.utils")
  local commands = Utils.get_commands()
  local command = vim.iter(commands):find(function(command) return command.name == item.data.name end)

  if not command then
    callback()
    return
  end

  local sidebar = require("avante").get()
  if not command.callback then
    if sidebar then sidebar:submit_input() end
    callback()
    return
  end

  command.callback(sidebar, nil, function()
    local bufnr = sidebar.containers.input.bufnr ---@type integer
    local content = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        local lines = vim.split(content:gsub(item.label, ""), "\n") ---@type string[]
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      end
    end, 100)
    callback()
  end)
end

return CommandsSource
