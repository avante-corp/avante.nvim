local specrev = '1'

-- luarocks-tag-release reserved variable
local is_release = '$is_release' == 'true'

local repo_url = 'https://github.com/avante-corp/avante.nvim'


rockspec_format = '3.0'
package = 'avante.nvim'

dependencies = {
  'lua == 5.1',
  'luarocks >= 3.11.1,< 4.0.0',
  'plenary.nvim',
  'nui.nvim',
  'mega.cmdparse'
}

test_dependencies = { 'busted' }


if is_release then
  -- git_ref is set to a tag if possible, else git revision
  local git_ref = '$git_ref'
  -- $modrev is "git_ref" stripped of "v" prefix (disallowed in rockspec filename)
  local modrev = '$modrev'
  source = {
    url = repo_url .. '/archive/' .. git_ref .. '.zip',
    dir = 'avante.nvim-' .. modrev,
  }
else

  version = "scm-" .. specrev
  source = {
    url = repo_url:gsub('https', 'git')
  }
end

build = {
  type = 'builtin',
  copy_directories = { 'autoload', 'doc', 'ftplugin', 'plugin' } ,
}

description = {
  summary = 'Use your Neovim like using Cursor AI IDE!',
  detailed = [[
avante.nvim** is a Neovim plugin designed to emulate the behaviour of the [Cursor](https://www.cursor.com) AI IDE. It provides users with AI-driven code suggestions and the ability to apply these recommendations directly to their source files with minimal effort.]],
  labels = { 'neovim', 'ai', 'llm' } ,
  homepage = 'https://github.com/avante-corp/avante.nvim',
  license = 'Apache-2.0'
}
