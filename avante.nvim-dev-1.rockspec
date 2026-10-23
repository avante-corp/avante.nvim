rockspec_format = "3.0"
package = "avante.nvim"
version = "dev-1"

description = {
	summary = "Use your Neovim like using Cursor AI IDE!",
	detailed = "**avante.nvim** is a Neovim plugin designed to emulate the behaviour of the [Cursor](https://www.cursor.com) AI IDE. It provides users with AI-driven code suggestions and the ability to apply these recommendations directly to their source files with minimal effort.",
	license = "Apache-2.0",
	homepage = "https://github.com/avante-corp/avante.nvim",
	labels = {
		"neovim",
		"ai",
		"llm",
	},
}

dependencies = {
	"lua==5.1",
	"nui.nvim",
	"plenary.nvim",
	"luarocks>=3.11.1, <4.0.0",
	"mega.cmdparse",
}

source = {
	url = "git+https://github.com/avante-corp/avante.nvim.git",
}

build = {
	type = "builtin",
	copy_directories = {
		"autoload",
		"doc",
		"ftplugin",
		"plugin",
	},
}
