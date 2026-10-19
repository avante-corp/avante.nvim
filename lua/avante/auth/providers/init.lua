local M = {}

function M.get(provider_name)
  local ok, mod = pcall(require, "avante.auth.providers." .. provider_name)
  if ok then return mod end
  return nil
end

-- returns a list of available oauth providers
--
-- @return table a list of provider names
function M.list_oauth_providers()
  local providers = {}
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fn.fnamemodify(script_path, ":h")

  for name, t in vim.fs.dir(dir) do
    if t == "file" and name:match("%.lua$") and name ~= "init.lua" then
      local provider_name = name:gsub("%.lua$", "")
      local ok, mod = pcall(require, "avante.auth.providers." .. provider_name)
      if ok and type(mod.authenticate) == "function" then table.insert(providers, provider_name) end
    end
  end

  table.sort(providers)
  return providers
end
return M
