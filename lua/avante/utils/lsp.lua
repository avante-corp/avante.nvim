---@class avante.utils.lsp
local M = {}

local LspMethod = vim.lsp.protocol.Methods

---@alias vim.lsp.Client.filter {id?: number, bufnr?: number, name?: string, method?: string, filter?:fun(client: vim.lsp.Client):boolean}

---@param opts? vim.lsp.Client.filter
---@return vim.lsp.Client[]
function M.get_clients(opts)
  ---@type vim.lsp.Client[]
  local ret = vim.lsp.get_clients(opts)
  return (opts and opts.filter) and vim.tbl_filter(opts.filter, ret) or ret
end

--- return function or variable or class
---@param node TSNode?
---@return TSNode?
local function get_ts_node_parent(node)
  if not node then return nil end
  local type = node:type()
  if
    type:match("function")
    or type:match("method")
    or type:match("variable")
    or type:match("class")
    or type:match("type")
    or type:match("parameter")
    or type:match("field")
    or type:match("property")
    or type:match("enum")
    or type:match("assignment")
    or type:match("struct")
    or type:match("declaration")
  then
    return node
  end
  return get_ts_node_parent(node:parent())
end

---@param location lsp.Location
---@return string[]
local function get_full_definition(location)
  local uri = location.uri
  local filepath = uri:gsub("^file://", "")
  local full_lines = vim.fn.readfile(filepath)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, full_lines)
  local filetype = vim.filetype.match({ filename = filepath, buf = buf }) or ""

  --- use tree-sitter to get the full definition
  local lang = vim.treesitter.language.get_lang(filetype)
  local parser = vim.treesitter.get_parser(buf, lang)
  if not parser then
    vim.api.nvim_buf_delete(buf, { force = true })
    return {}
  end
  local tree = parser:parse()[1]
  local root = tree:root()
  local node = root:named_descendant_for_range(
    location.range.start.line,
    location.range.start.character,
    location.range.start.line,
    location.range.start.character
  )
  if not node then
    vim.api.nvim_buf_delete(buf, { force = true })
    return {}
  end
  local parent = get_ts_node_parent(node)
  if not parent then parent = node end
  local text = vim.treesitter.get_node_text(parent, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return vim.split(text, "\n")
end

---@param bufnr number
---@param symbol_name string
---@param show_line_numbers boolean
---@param on_complete fun(definitions: avante.lsp.Definition[] | nil, error: string | nil)
function M.read_definitions(bufnr, symbol_name, show_line_numbers, on_complete)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    on_complete(nil, "No LSP client found")
    return
  end
  local supports_workspace_symbol = false
  for _, client in ipairs(clients) do
    if client:supports_method(LspMethod.workspace_symbol) then
      supports_workspace_symbol = true
      break
    end
  end
  if not supports_workspace_symbol then
    on_complete(nil, "Cannot read definitions.")
    return
  end
  local params = { query = symbol_name }
  vim.lsp.buf_request_all(bufnr, LspMethod.workspace_symbol, params, function(results)
    if not results or #results == 0 then
      on_complete(nil, "No results")
      return
    end
    ---@type avante.lsp.Definition[]
    local res = {}
    for _, result in ipairs(results) do
      if result.err then
        on_complete(nil, result.err.message)
        return
      end
      ---@diagnostic disable-next-line: undefined-field
      if result.error then
        ---@diagnostic disable-next-line: undefined-field
        on_complete(nil, result.error.message)
        return
      end
      if not result.result then goto continue end
      ---@type lsp.SymbolInformation[]
      local symbols = result.result
      ---@type lsp.SymbolInformation[]
      local definitions = vim.tbl_filter(
        ---@param d lsp.SymbolInformation
        ---@return boolean
        function(d) return d.name == symbol_name end,
        symbols
      )
      if #definitions == 0 then
        on_complete(nil, "No definition found")
        return
      end
      for _, definition in ipairs(definitions) do
        local lines = get_full_definition(definition.location)
        if show_line_numbers then
          local start_line = definition.location.range.start.line
          local new_lines = {}
          for i, line_ in ipairs(lines) do
            table.insert(new_lines, tostring(start_line + i) .. ": " .. line_)
          end
          lines = new_lines
        end
        local uri = definition.location.uri
        table.insert(res, { content = table.concat(lines, "\n"), uri = uri })
      end
      ::continue::
    end
    on_complete(res, nil)
  end)
end

local severity = {
  [1] = "ERROR",
  [2] = "WARNING",
  [3] = "INFORMATION",
  [4] = "HINT",
}

---@class AvanteDiagnostic
---@field content string
---@field start_line number
---@field end_line number
---@field severity string
---@field source string

---@param bufnr integer
---@return AvanteDiagnostic[]
function M.get_diagnostics(bufnr)
  if bufnr == nil then bufnr = vim.api.nvim_get_current_buf() end
  ---@type vim.Diagnostic[]
  local diagnositcs = vim.diagnostic.get(bufnr, {
    severity = {
      vim.diagnostic.severity.ERROR,
      vim.diagnostic.severity.WARN,
      vim.diagnostic.severity.INFO,
      vim.diagnostic.severity.HINT,
    },
  })
  return vim
    .iter(diagnositcs)
    :map(
      ---@param diagnostic vim.Diagnostic
      ---@return AvanteDiagnostic
      function(diagnostic)
        local d = {
          content = diagnostic.message,
          start_line = diagnostic.lnum + 1,
          end_line = diagnostic.end_lnum and diagnostic.end_lnum + 1 or diagnostic.lnum + 1,
          severity = severity[diagnostic.severity],
          source = diagnostic.source,
        }
        return d
      end
    )
    :totable()
end

---@param filepath string
---@return AvanteDiagnostic[]
function M.get_diagnostics_from_filepath(filepath)
  local Utils = require("avante.utils")
  local bufnr = Utils.open_buffer(filepath, false)
  return M.get_diagnostics(bufnr)
end

---@param bufnr integer
---@param selection avante.SelectionResult
---@return AvanteDiagnostic[]
function M.get_current_selection_diagnostics(bufnr, selection)
  local diagnostics = M.get_diagnostics(bufnr)
  local selection_diagnostics = {}
  for _, diagnostic in ipairs(diagnostics) do
    if selection.range.start.lnum <= diagnostic.start_line and selection.range.finish.lnum >= diagnostic.end_line then
      table.insert(selection_diagnostics, diagnostic)
    end
  end
  return selection_diagnostics
end

return M
