<div align="center">
  <img alt="logo" width="120" src="https://github.com/user-attachments/assets/2e2f2a58-2b28-4d11-afd1-87b65612b2de" />
  <h1>avante.nvim</h1>
</div>

<p align="center">
  <a href="https://neovim.io/" target="_blank"><img src="https://img.shields.io/static/v1?style=flat-square&label=Neovim&message=v0.12%2b&logo=neovim&labelColor=282828&logoColor=8faa80&color=414b32" alt="Neovim: v0.12+" /></a>
  <a href="https://github.com/yetone/avante.nvim/actions/workflows/tests.yaml" target="_blank"><img src="https://img.shields.io/github/actions/workflow/status/yetone/avante.nvim/tests.yaml?style=flat-square&logo=lua&logoColor=c7c7c7&label=Lua+CI&labelColor=1E40AF&color=347D39&event=push" alt="Lua CI status" /></a>
  <a href="https://github.com/yetone/avante.nvim/actions/workflows/rust.yaml" target="_blank"><img src="https://img.shields.io/github/actions/workflow/status/yetone/avante.nvim/rust.yaml?style=flat-square&logo=rust&logoColor=ffffff&label=Rust+CI&labelColor=BC826A&color=347D39&event=push" alt="Rust CI status" /></a>
  <a href="https://github.com/yetone/avante.nvim/actions/workflows/pre-commit.yaml" target="_blank"><img src="https://img.shields.io/github/actions/workflow/status/yetone/avante.nvim/pre-commit.yaml?style=flat-square&logo=pre-commit&logoColor=ffffff&label=pre-commit&labelColor=FAAF3F&color=347D39&event=push" alt="pre-commit status" /></a>
  <a href="https://discord.gg/QfnEFEdSjz" target="_blank"><img src="https://img.shields.io/discord/1302530866362323016?style=flat-square&logo=discord&label=Discord&logoColor=ffffff&labelColor=7376CF&color=268165" alt="Discord" /></a>
  <a href="https://dotfyle.com/plugins/yetone/avante.nvim"><img src="https://dotfyle.com/plugins/yetone/avante.nvim/shield?style=flat-square" /></a>
</p>

**avante.nvim** is a Neovim plugin designed to emulate the behaviour of the [Cursor](https://www.cursor.com) AI IDE. It provides users with AI-driven code suggestions and the ability to apply these recommendations directly to their source files with minimal effort.

[查看中文版](README_zh.md)

> [!NOTE]
>
> 🥰 This project is undergoing rapid iterations, and many exciting features will be added successively. Stay tuned!

<https://github.com/user-attachments/assets/510e6270-b6cf-459d-9a2f-15b397d1fe53>

<https://github.com/user-attachments/assets/86140bfd-08b4-483d-a887-1b701d9e37dd>

## Sponsorship ❤️

If you like this project, please consider supporting me on Patreon, as it helps me to continue maintaining and improving it:

[Sponsor me](https://patreon.com/yetone)

## Features

- **AI-Powered Code Assistance**: Interact with AI to ask questions about your current code file and receive intelligent suggestions for improvement or modification.
- **One-Click Application**: Quickly apply the AI's suggested changes to your source code with a single command, streamlining the editing process and saving time.
- **Project-Specific Instruction Files**: Customize AI behavior by adding a markdown file (`avante.md` by default) in the project root. This file is automatically referenced during workspace changes. You can also configure a custom file name for tailored project instructions.
- **ACP support**: Agent Client Protocol support (codex, gemini, ...)
- **Many providers supported**: openai, anthropic, mistral, deepseek, ollama,
  llama-cpp, ...
- **RAG (optional)**: you can with some extra configuration run a local RAG

## Avante Zen Mode

It is possible to launch avante such that it looks like a typical Vibe Coding Agent CLI but while being completely Neovim underneath. So you can use your muscle-memory Vim operations and those rich and mature Neovim plugins on it. At the same time, by leveraging [ACP](https://github.com/yetone/avante.nvim#acp-support) it has all capabilities of claude code / gemini-cli / codex! Why not enjoy both?

Now all you need to do is install [./contrib/avante] in your PATH (or create the equivalent alias); then every time you simply type avante just like using claude code and enter Avante’s Zen Mode!

The effect is as follows:

<img alt="Avante Zen Mode" src="https://github.com/user-attachments/assets/60880f65-af55-4e4c-a565-23bb63e19251" />

## Project instructions with avante.md

<details>

<summary>
The `avante.md` file allows you to provide project-specific context and instructions to the ai. this file should be placed in your project root and will be automatically referenced during all interactions with avante.
</summary>

### Best practices for avante.md

to get the most out of your project instruction file, consider following this structure:

#### Your role

define the ai's persona and expertise level for your project:

```markdown
### your role

you are an expert senior software engineer specializing in [technology stack]. you have deep knowledge of [specific frameworks/tools] and understand best practices for [domain/industry]. you write clean, maintainable, and well-documented code. you prioritize code quality, performance, and security in all your recommendations.
```

#### Your mission

clearly describe what the ai should focus on and how it should help:

```markdown
### your mission

your primary goal is to help build and maintain [project description]. you should:

- provide code suggestions that follow our established patterns and conventions
- help debug issues by analyzing code and suggesting solutions
- assist with refactoring to improve code quality and maintainability
- suggest optimizations for performance and scalability
- ensure all code follows our security guidelines
- help write comprehensive tests for new features
```

#### Additional sections to consider

- **project context**: brief description of the project, its goals, and target users
- **technology stack**: list of technologies, frameworks, and tools used
- **coding standards**: specific conventions, style guides, and patterns to follow
- **architecture guidelines**: how components should interact and be organized
- **testing requirements**: testing strategies and coverage expectations
- **security considerations**: specific security requirements or constraints

### example avante.md

```markdown
# project instructions for myapp

## your role

you are an expert full-stack developer specializing in react, node.js, and typescript. you understand modern web development practices and have experience with our tech stack.

## your mission

help build a scalable e-commerce platform by:

- writing type-safe typescript code
- following react best practices and hooks patterns
- implementing restful apis with proper error handling
- ensuring responsive design with tailwind css
- writing comprehensive unit and integration tests

## project context

myapp is a modern e-commerce platform targeting small businesses. we prioritize performance, accessibility, and user experience.

## technology stack

- frontend: react 18, typescript, tailwind css, vite
- backend: node.js, express, prisma, postgresql
- testing: jest, react testing library, playwright
- deployment: docker, aws

## coding standards

- use functional components with hooks
- prefer composition over inheritance
- write self-documenting code with clear variable names
- add jsdoc comments for complex functions
- follow the existing folder structure and naming conventions
```

</details>

## Installation

For building binary if you wish to build from source, then `cargo` is required. Otherwise `curl` and `tar` will be used to get prebuilt binary from GitHub.

<details open>

  <summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  "yetone/avante.nvim",
  -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
  -- ⚠️ must add this setting! ! !
  build = vim.fn.has("win32") ~= 0
      and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
      or "make",
  event = "VeryLazy",
  version = false, -- Never set this value to "*"! Never!
  ---@module 'avante'
  ---@type avante.Config
  opts = {
    -- add any opts here
    -- this file can contain specific instructions for your project
    instructions_file = "avante.md",
    -- for example
    provider = "claude",
    providers = {
      claude = {
        endpoint = "https://api.anthropic.com",
        model = "claude-sonnet-4-20250514",
        timeout = 30000, -- Timeout in milliseconds
          extra_request_body = {
            temperature = 0.75,
            max_tokens = 20480,
          },
      },
      moonshot = {
        endpoint = "https://api.moonshot.ai/v1",
        model = "kimi-k2-0711-preview",
        timeout = 30000, -- Timeout in milliseconds
        extra_request_body = {
          temperature = 0.75,
          max_tokens = 32768,
        },
      },
    },
  },
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    --- The below dependencies are optional,
    "nvim-mini/mini.pick", -- for file_selector provider mini.pick
    "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
    "hrsh7th/nvim-cmp", -- autocompletion for avante commands and mentions
    "ibhagwan/fzf-lua", -- for file_selector provider fzf
    "folke/snacks.nvim", -- for input provider snacks
    "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
    "zbirenbaum/copilot.lua", -- for providers='copilot'
    {
      -- support for image pasting
      "HakonHarnes/img-clip.nvim",
      event = "VeryLazy",
      opts = {
        -- recommended settings
        default = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          drag_and_drop = {
            insert_mode = true,
          },
          -- required for Windows users
          use_absolute_path = true,
        },
      },
    },
    {
      -- Make sure to set this up properly if you have lazy=true
      'MeanderingProgrammer/render-markdown.nvim',
      opts = {
        file_types = { "markdown", "Avante" },
      },
      ft = { "markdown", "Avante" },
    },
  },
}
```

</details>

<details>

  <summary><a href="https://neovim.io/doc/user/pack/">Pack</a></summary>

Pack is an out-of-the-box plugin manager since Neovim v0.12.

```lua
vim.api.nvim_create_autocmd(
  'PackChanged',
  {
    callback = function(ev)
      local name, kind = ev.data.spec.name, ev.data.kind
      if name == 'avante.nvim' and (kind == 'install' or kind == 'update') then
        -- Use `./build.sh` to use prebuilt libraries
        vim.system({ 'make' }, { cwd = ev.data.path }):wait()
      end
    end
  }
)

vim.pack.add({
  {
    src='https://github.com/yetone/avante.nvim',
    version='main'  -- default
  },

  -- Deps
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/MunifTanjim/nui.nvim',

  -- Optional deps
  'https://github.com/MeanderingProgrammer/render-markdown.nvim',
  'https://github.com/hrsh7th/nvim-cmp',
  'https://github.com/nvim-tree/nvim-web-devicons', -- or 'echasnovski/mini.icons'
  'https://github.com/HakonHarnes/img-clip.nvim',
  'https://github.com/zbirenbaum/copilot.lua',
  'https://github.com/folke/snacks.nvim', -- for modern input UI
})

-- Config customizations
require('avante').setup({})
```

</details>

<details>

  <summary><a href="https://github.com/lumen-oss/rocks.nvim">rocks.nvim</a></summary>

Run `:Rocks install avante.nvim` then add to your init.lua:

```lua
require('avante').setup()
```

</details>

<details>

  <summary>vim-plug</summary>

```vim

call plug#begin()

" Deps
Plug 'nvim-lua/plenary.nvim'
Plug 'MunifTanjim/nui.nvim'
Plug 'MeanderingProgrammer/render-markdown.nvim'

" Optional deps
Plug 'hrsh7th/nvim-cmp'
Plug 'nvim-tree/nvim-web-devicons' "or Plug 'echasnovski/mini.icons'
Plug 'HakonHarnes/img-clip.nvim'
Plug 'zbirenbaum/copilot.lua'
Plug 'folke/snacks.nvim' " for modern input UI

" Yay, pass source=true if you want to build from source
Plug 'yetone/avante.nvim', { 'branch': 'main', 'do': 'make' }

call plug#end()

autocmd! User avante.nvim
lua << EOF
require('avante').setup({})
EOF
```

</details>

<details>

  <summary><a href="https://github.com/echasnovski/mini.deps">mini.deps</a></summary>

```lua
local add, later, now = MiniDeps.add, MiniDeps.later, MiniDeps.now

add({
  source = 'yetone/avante.nvim',
  monitor = 'main',
  depends = {
    'nvim-lua/plenary.nvim',
    'MunifTanjim/nui.nvim',
    'echasnovski/mini.icons'
  },
  hooks = { post_checkout = function() vim.cmd('make') end }
})
--- optional
add({ source = 'hrsh7th/nvim-cmp' })
add({ source = 'zbirenbaum/copilot.lua' })
add({ source = 'HakonHarnes/img-clip.nvim' })
add({ source = 'MeanderingProgrammer/render-markdown.nvim' })

later(function() require('render-markdown').setup({...}) end)
later(function()
  require('img-clip').setup({...}) -- config img-clip
  require("copilot").setup({...}) -- setup copilot to your liking
  require("avante").setup({...}) -- config for avante.nvim
end)
```

</details>

<details>

  <summary><a href="https://github.com/nix-community/home-manager">Home Manager</a></summary>

```nix
programs.neovim = {
  plugins = [
    {
      plugin = pkgs.vimPlugins.avante-nvim;
      type = "lua";
      config = ''
              require("avante").setup()
      ''; # or builtins.readFile ./plugins/avante.lua
    }
  ];
};
```

</details>

<details>

  <summary><a href="https://nix-community.github.io/nixvim/plugins/avante/index.html">Nixvim</a></summary>

```nix
  plugins.avante.enable = true;
  plugins.avante.settings = {
    # setup options here
  };
```

</details>

<details>

  <summary>Lua</summary>

```lua
-- deps:
require('cmp').setup ({
  -- use recommended settings from above
})
require('img-clip').setup ({
  -- use recommended settings from above
})
require('copilot').setup ({
  -- use recommended settings from above
})
require('render-markdown').setup ({
  -- use recommended settings from above
})
require('avante').setup({
  -- Example: Using snacks.nvim as input provider
  input = {
    provider = "snacks", -- "native" | "snacks"
    provider_opts = {
      -- Snacks input configuration
      title = "Avante Input",
      icon = " ",
      placeholder = "Enter your API key...",
    },
  },
  -- Your other config here!
})
```

</details>

> [!IMPORTANT]
>
> `avante.nvim` is currently only compatible with Neovim 0.11.0 or later. Please ensure that your Neovim version meets these requirements before proceeding.

> [!NOTE]
>
> When loading the plugin synchronously, we recommend `require`ing it sometime after your colorscheme.

> [!NOTE]
>
> Recommended **Neovim** options:
>
> ```lua
> -- views can only be fully collapsed with the global statusline
> vim.opt.laststatus = 3
> ```

> [!TIP]
>
> Any rendering plugins that support markdown should work with Avante as long as you add the supported filetype `Avante`. See <https://github.com/yetone/avante.nvim/issues/175> and [this comment](https://github.com/yetone/avante.nvim/issues/175#issuecomment-2313749363) for more information.

### Configuration

You can configure avante.nvim using a global variable:

```lua
vim.g.avante = {
  provider = "claude",
  behaviour = {
    auto_suggestions = false,
  },
}

```


You can also pass options directly to `setup()`:

```lua
require("avante").setup({
  provider = "claude",
  behaviour = {
    auto_suggestions = false,
  },
})
```

If both are used, options passed to `setup()` override values from `vim.g.avante`.

<details>
<summary>Default configuration</summary>

_See [config.lua#L9](./lua/avante/config.lua) for the up to date full default configuration_

```lua
{
  ---@alias Provider "claude" | "openai" | "azure" | "gemini" | "cohere" | "copilot" | string
  ---@type Provider
  provider = "claude", -- The provider used in Aider mode or in the planning phase of Cursor Planning Mode
  ---@alias Mode "agentic" | "legacy"
  ---@type Mode
  mode = "agentic", -- The default mode for interaction. "agentic" uses tools to automatically generate code, "legacy" uses the old planning method to generate code.
  -- WARNING: Since auto-suggestions are a high-frequency operation and therefore expensive,
  -- currently designating it as `copilot` provider is dangerous because: https://github.com/yetone/avante.nvim/issues/1048
  -- Of course, you can reduce the request frequency by increasing `suggestion.debounce`.
  auto_suggestions_provider = "claude",
  providers = {
    claude = {
      endpoint = "https://api.anthropic.com",
      auth_type = "api" -- Set to "max" to sign in with Claude Pro/Max subscription
      model = "claude-3-5-sonnet-20241022",
      extra_request_body = {
        temperature = 0.75,
        max_tokens = 4096,
      },
    },
  },
  ---Specify the special dual_boost mode
  ---1. enabled: Whether to enable dual_boost mode. Default to false.
  ---2. first_provider: The first provider to generate response. Default to "openai".
  ---3. second_provider: The second provider to generate response. Default to "claude".
  ---4. prompt: The prompt to generate response based on the two reference outputs.
  ---5. timeout: Timeout in milliseconds. Default to 60000.
  ---How it works:
  --- When dual_boost is enabled, avante will generate two responses from the first_provider and second_provider respectively. Then use the response from the first_provider as provider1_output and the response from the second_provider as provider2_output. Finally, avante will generate a response based on the prompt and the two reference outputs, with the default Provider as normal.
  ---Note: This is an experimental feature and may not work as expected.
  dual_boost = {
    enabled = false,
    first_provider = "openai",
    second_provider = "claude",
    prompt = "Based on the two reference outputs below, generate a response that incorporates elements from both but reflects your own judgment and unique perspective. Do not provide any explanation, just give the response directly. Reference Output 1: [{{provider1_output}}], Reference Output 2: [{{provider2_output}}]",
    timeout = 60000, -- Timeout in milliseconds
  },
  behaviour = {
    auto_suggestions = false, -- Experimental stage
    auto_set_highlight_group = true,
    auto_set_keymaps = true,
    auto_apply_diff_after_generation = false,
    support_paste_from_clipboard = false,
    minimize_diff = true, -- Whether to remove unchanged lines when applying a code block
    enable_token_counting = true, -- Whether to enable token counting. Default to true.
    auto_add_current_file = true, -- Whether to automatically add the current file when opening a new chat. Default to true.
    auto_approve_tool_permissions = true, -- Default: auto-approve all tools (no prompts)
    -- Examples:
    -- auto_approve_tool_permissions = false,                -- Show permission prompts for all tools
    -- auto_approve_tool_permissions = {"bash", "str_replace"}, -- Auto-approve specific tools only
    ---@type "popup" | "inline_buttons"
    confirmation_ui_style = "inline_buttons",
    --- Whether to automatically open files and navigate to lines when ACP agent makes edits
    ---@type boolean
    acp_follow_agent_locations = true,
  },
  prompt_logger = { -- logs prompts to disk (timestamped, for replay/debugging)
    enabled = true, -- toggle logging entirely
    log_dir = vim.fn.stdpath("cache") .. "/avante_prompts", -- directory where logs are saved
    fortune_cookie_on_success = false, -- shows a random fortune after each logged prompt (requires `fortune` installed)
    next_prompt = {
      normal = "<C-n>", -- load the next (newer) prompt log in normal mode
      insert = "<C-n>",
    },
    prev_prompt = {
      normal = "<C-p>", -- load the previous (older) prompt log in normal mode
      insert = "<C-p>",
    },
  },
  mappings = {
    --- @class AvanteConflictMappings
    diff = {
      ours = "co",
      theirs = "ct",
      all_theirs = "ca",
      both = "cb",
      cursor = "cc",
      next = "]x",
      prev = "[x",
    },
    suggestion = {
      accept = "<M-l>",
      next = "<M-]>",
      prev = "<M-[>",
      dismiss = "<C-]>",
    },
    jump = {
      next = "]]",
      prev = "[[",
    },
    submit = {
      normal = "<CR>",
      insert = "<C-s>",
    },
    cancel = {
      normal = { "<C-c>", "<Esc>", "q" },
      insert = { "<C-c>" },
    },
    sidebar = {
      apply_all = "A",
      apply_cursor = "a",
      retry_user_request = "r",
      edit_user_request = "e",
      switch_windows = "<Tab>",
      reverse_switch_windows = "<S-Tab>",
      remove_file = "d",
      add_file = "@",
      close = { "<Esc>", "q" },
      close_from_input = nil, -- e.g., { normal = "<Esc>", insert = "<C-d>" }
    },
  },
  selection = {
    enabled = true,
    hint_display = "delayed",
  },
  windows = {
    ---@type "right" | "left" | "top" | "bottom"
    position = "right", -- the position of the sidebar
    wrap = true, -- similar to vim.o.wrap
    width = 30, -- default % based on available width
    sidebar_header = {
      enabled = true, -- true, false to enable/disable the header
      align = "center", -- left, center, right for title
      rounded = true,
    },
    spinner = {
      editing = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿" },
      generating = { "·", "✢", "✳", "∗", "✻", "✽" }, -- Spinner characters for the 'generating' state
      thinking = { "🤯", "🙄" }, -- Spinner characters for the 'thinking' state
    },
    input = {
      prefix = "> ",
      height = 8, -- Height of the input window in vertical layout
    },
    edit = {
      border = "rounded",
      start_insert = true, -- Start insert mode when opening the edit window
    },
    ask = {
      floating = false, -- Open the 'AvanteAsk' prompt in a floating window
      start_insert = true, -- Start insert mode when opening the ask window
      border = "rounded",
      ---@type "ours" | "theirs"
      focus_on_apply = "ours", -- which diff to focus after applying
    },
  },
  highlights = {
    ---@type AvanteConflictHighlights
    diff = {
      current = "DiffText",
      incoming = "DiffAdd",
    },
  },
  --- @class AvanteConflictUserConfig
  diff = {
    autojump = true,
    ---@type string | fun(): any
    list_opener = "copen",
    --- Override the 'timeoutlen' setting while hovering over a diff (see :help timeoutlen).
    --- Helps to avoid entering operator-pending mode with diff mappings starting with `c`.
    --- Disable by setting to -1.
    override_timeoutlen = 500,
  },
  suggestion = {
    debounce = 600,
    throttle = 600,
  },
}
```

</details>

### Blink.cmp users

For blink cmp users (nvim-cmp alternative) view below instruction for configuration
This is achieved by emulating nvim-cmp using blink.compat
or you can use [Kaiser-Yang/blink-cmp-avante](https://github.com/Kaiser-Yang/blink-cmp-avante).

<details>
  <summary>Lua</summary>

```lua
      selector = {
        --- @alias avante.SelectorProvider "native" | "fzf_lua" | "mini_pick" | "snacks" | "telescope" | fun(selector: avante.ui.Selector): nil
        --- @type avante.SelectorProvider
        provider = "fzf",
        -- Options override for custom providers
        provider_opts = {},
      }
```

To create a customized selector provider, you can specify a customized function to launch a picker to select items and pass the selected items to the `on_select` callback.

```lua
      selector = {
        ---@param selector avante.ui.Selector
        provider = function(selector)
          local items = selector.items ---@type avante.ui.SelectorItem[]
          local title = selector.title ---@type string
          local on_select = selector.on_select ---@type fun(selected_item_ids: string[]|nil): nil

          --- your customized picker logic here
        end,
      }
```

### Input Provider Configuration

Avante.nvim supports multiple input providers for user input (like API key entry). You can configure which provider to use:

<details>
  <summary>Native Input Provider (Default)</summary>

```lua
{
  input = {
    provider = "native", -- Uses vim.ui.input
    provider_opts = {},
  }
}
```

</details>

<details>
  <summary>Snacks.nvim Input Provider (Recommended)</summary>

For modern, feature-rich input UI:

```lua
{
  input = {
    provider = "snacks",
    provider_opts = {
      -- Additional snacks.input options
      title = "Avante Input",
      icon = " ",
    },
  }
}
```

You'll need to install snacks.nvim:

```lua
-- With lazy.nvim
{ "folke/snacks.nvim" }
```

</details>

<details>
  <summary>Custom Input Provider</summary>

To create a customized input provider, you can specify a function:

```lua
{
  input = {
    ---@param input avante.ui.Input
    provider = function(input)
      local title = input.title ---@type string
      local default = input.default ---@type string
      local conceal = input.conceal ---@type boolean
      local on_submit = input.on_submit ---@type fun(result: string|nil): nil

      --- your customized input logic here
    end,
  }
}
```

</details>

Choose a selector other that native, the default as that currently has an issue
For lazyvim users copy the full config for blink.cmp from the website or extend the options

```lua
      compat = {
        "avante_commands",
        "avante_mentions",
        "avante_files",
      }
```

For other users just add a custom provider

### Available Completion Sources

Avante.nvim provides several completion sources that can be integrated with blink.cmp:

#### Mentions (`@` trigger)

Mentions allow you to quickly reference specific features or add files to the chat context:

- `@codebase` - Enable project context and repository mapping
- `@diagnostics` - Enable diagnostics information
- `@file` - Open file selector to add files to chat context
- `@quickfix` - Add files from quickfix list to chat context
- `@buffers` - Add open buffers to chat context

#### Slash Commands (`/` trigger)

Built-in slash commands for common operations:

- `/help` - Show help message with available commands
- `/init` - Initialize AGENTS.md based on current project
- `/clear` - Clear chat history
- `/new` - Start a new chat
- `/compact` - Compact history messages to save tokens
- `/lines <start>-<end> <question>` - Ask about specific lines
- `/commit` - Generate commit message for changes

#### Shortcuts (`#` trigger)

Shortcuts provide quick access to predefined prompt templates. You can customize these in your config:

```lua
{
  shortcuts = {
    {
      name = "refactor",
      description = "Refactor code with best practices",
      details = "Automatically refactor code to improve readability, maintainability, and follow best practices while preserving functionality",
      prompt = "Please refactor this code following best practices, improving readability and maintainability while preserving functionality."
    },
    {
      name = "test",
      description = "Generate unit tests",
      details = "Create comprehensive unit tests covering edge cases, error scenarios, and various input conditions",
      prompt = "Please generate comprehensive unit tests for this code, covering edge cases and error scenarios."
    },
    -- Add more custom shortcuts...
  }
}
```

When you type `#refactor` in the input, it will automatically be replaced with the corresponding prompt text.

### Configuration Example

Here's a complete blink.cmp configuration example with all Avante sources:

```lua
      default = {
        ...
        "avante_commands",
        "avante_mentions",
        "avante_shortcuts",
        "avante_files",
      }
```

```lua
      providers = {
        avante_commands = {
          name = "avante_commands",
          module = "blink.compat.source",
          score_offset = 90, -- show at a higher priority than lsp
          opts = {},
        },
        avante_files = {
          name = "avante_files",
          module = "blink.compat.source",
          score_offset = 100, -- show at a higher priority than lsp
          opts = {},
        },
        avante_mentions = {
          name = "avante_mentions",
          module = "blink.compat.source",
          score_offset = 1000, -- show at a higher priority than lsp
          opts = {},
        },
        avante_shortcuts = {
          name = "avante_shortcuts",
          module = "blink.compat.source",
          score_offset = 1000, -- show at a higher priority than lsp
          opts = {},
        }
        ...
    }
```

</details>

## Usage

### Using Claude Pro/Max Subscription
To login with your Claude subscription, set the **auth_type** of the Claude provider entry in your config to "max", re-open Neovim then the authentication process will start in your browser. Once logged in and authorized, a code will show that needs to be copied into the prompt in Neovim, which should then give access to use your subscription with Avante.

You may need to run `AvanteSwitchProvider claude` to initiate the authentication if you previously had a different provider selected.

```lua
-- Providers = { ...

  claude = {
    -- ...
    auth_type = "max",
  },

```

### Basic Functionality

Given its early stage, `avante.nvim` currently supports the following basic functionalities:

> [!IMPORTANT]
>
> For most consistency between neovim session, it is recommended to set the environment variables in your shell file.
> By default, `Avante` will prompt you at startup to input the API key for the provider you have selected.
>
> **Scoped API Keys (Recommended for Isolation)**
>
> Avante now supports scoped API keys, allowing you to isolate API keys specifically for Avante without affecting other applications. Simply prefix any API key with `AVANTE_`:
>
> ```sh
> # Scoped keys (recommended)
> export AVANTE_ANTHROPIC_API_KEY=your-claude-api-key
> export AVANTE_OPENAI_API_KEY=your-openai-api-key
> export AVANTE_AZURE_OPENAI_API_KEY=your-azure-api-key
> export AVANTE_GEMINI_API_KEY=your-gemini-api-key
> export AVANTE_CO_API_KEY=your-cohere-api-key
> export AVANTE_AIHUBMIX_API_KEY=your-aihubmix-api-key
> export AVANTE_MOONSHOT_API_KEY=your-moonshot-api-key
> ```
>
> **Global API Keys (Legacy)**
>
> You can still use the traditional global API keys if you prefer:
>
> For Claude:
>
> ```sh
> export ANTHROPIC_API_KEY=your-api-key
> ```
>
> For OpenAI:
>
> ```sh
> export OPENAI_API_KEY=your-api-key
> ```
>
> For Azure OpenAI:
>
> ```sh
> export AZURE_OPENAI_API_KEY=your-api-key
> ```
>
> For Amazon Bedrock:
>
> You can specify the `BEDROCK_KEYS` environment variable to set credentials. When this variable is not specified, bedrock will use the default AWS credentials chain (see below).
>
> ```sh
> export BEDROCK_KEYS=aws_access_key_id,aws_secret_access_key,aws_region[,aws_session_token]
> ```
>
> Note: The aws_session_token is optional and only needed when using temporary AWS credentials
>
> Alternatively Bedrock tries to resolve AWS credentials using the [Default Credentials Provider Chain](https://docs.aws.amazon.com/cli/v1/userguide/cli-chap-authentication.html).
> This means you can have credentials e.g. configured via the AWS CLI, stored in your ~/.aws/profile, use AWS SSO etc.
> In this case `aws_region` and optionally `aws_profile` should be specified via the bedrock config, e.g.:
>
> ```lua
> bedrock = {
>   model = "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
>   aws_profile = "bedrock",
>   aws_region = "us-east-1",
> },
> ```
>
> Note: Bedrock requires the [AWS CLI](https://aws.amazon.com/cli/) to be installed on your system.

1. Open a code file in Neovim.
2. Use the `:AvanteAsk` command to query the AI about the code.
3. Review the AI's suggestions.
4. Apply the recommended changes directly to your code with a simple command or key binding.

**Note**: The plugin is still under active development, and both its functionality and interface are subject to significant changes. Expect some rough edges and instability as the project evolves.

## Key Bindings

The following key bindings are available for use with `avante.nvim`:

| Key Binding                               | Description                            |
| ----------------------------------------- | -------------------------------------- |
| **Sidebar**                               |                                        |
| <kbd>]</kbd><kbd>p</kbd>                  | next prompt                            |
| <kbd>[</kbd><kbd>p</kbd>                  | previous prompt                        |
| <kbd>A</kbd>                              | apply all                              |
| <kbd>a</kbd>                              | apply cursor                           |
| <kbd>r</kbd>                              | retry user request                     |
| <kbd>e</kbd>                              | edit user request                      |
| <kbd>&lt;Tab&gt;</kbd>                    | switch windows                         |
| <kbd>&lt;S-Tab&gt;</kbd>                  | reverse switch windows                 |
| <kbd>d</kbd>                              | remove file                            |
| <kbd>@</kbd>                              | add file                               |
| <kbd>q</kbd>                              | close sidebar                          |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>a</kbd> | show sidebar                           |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>t</kbd> | toggle sidebar visibility              |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>r</kbd> | refresh sidebar                        |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>f</kbd> | switch sidebar focus                   |
| **Suggestion**                            |                                        |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>?</kbd> | select model                           |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>n</kbd> | new ask                                |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>e</kbd> | edit selected blocks                   |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>S</kbd> | stop current AI request                |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>h</kbd> | select between chat histories          |
| <kbd>&lt;M-l&gt;</kbd>                    | accept suggestion                      |
| <kbd>&lt;M-]&gt;</kbd>                    | next suggestion                        |
| <kbd>&lt;M-[&gt;</kbd>                    | previous suggestion                    |
| <kbd>&lt;C-]&gt;</kbd>                    | dismiss suggestion                     |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>d</kbd> | toggle debug mode                      |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>s</kbd> | toggle suggestion display              |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>R</kbd> | toggle repomap                         |
| **Files**                                 |                                        |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>c</kbd> | add current buffer to selected files   |
| <kbd>Leader</kbd><kbd>a</kbd><kbd>B</kbd> | add all buffer files to selected files |
| **Diff**                                  |                                        |
| <kbd>c</kbd><kbd>o</kbd>                  | choose ours                            |
| <kbd>c</kbd><kbd>t</kbd>                  | choose theirs                          |
| <kbd>c</kbd><kbd>a</kbd>                  | choose all theirs                      |
| <kbd>c</kbd><kbd>b</kbd>                  | choose both                            |
| <kbd>c</kbd><kbd>c</kbd>                  | choose cursor                          |
| <kbd>]</kbd><kbd>x</kbd>                  | move to next conflict                  |
| <kbd>[</kbd><kbd>x</kbd>                  | move to previous conflict              |
| **Confirm**                               |                                        |
| <kbd>Ctrl</kbd><kbd>w</kbd><kbd>f</kbd>   | focus confirm window                   |
| <kbd>c</kbd>                              | confirm code                           |
| <kbd>r</kbd>                              | confirm response                       |
| <kbd>i</kbd>                              | confirm input                          |

> [!NOTE]
>
> If you are using `lazy.nvim`, then all keymap here will be safely set, meaning if `<leader>aa` is already binded, then avante.nvim won't bind this mapping.
> In this case, user will be responsible for setting up their own. See [notes on keymaps](https://github.com/yetone/avante.nvim/wiki#keymaps-and-api-i-guess) for more details.

### Neotree shortcut

In the neotree sidebar, you can also add a new keyboard shortcut to quickly add `file/folder` to `Avante Selected Files`.

<details>
<summary>Neotree configuration</summary>

```lua
return {
  {
    'nvim-neo-tree/neo-tree.nvim',
    config = function()
      require('neo-tree').setup({
        filesystem = {
          commands = {
            avante_add_files = function(state)
              local node = state.tree:get_node()
              local filepath = node:get_id()
              local relative_path = require('avante.utils').relative_path(filepath)

              local sidebar = require('avante').get()

              local open = sidebar:is_open()
              -- ensure avante sidebar is open
              if not open then
                require('avante.api').ask()
                sidebar = require('avante').get()
              end

              sidebar.file_selector:add_selected_file(relative_path)

              -- remove neo tree buffer
              if not open then
                sidebar.file_selector:remove_selected_file('neo-tree filesystem [1]')
              end
            end,
          },
          window = {
            mappings = {
              ['oa'] = 'avante_add_files',
            },
          },
        },
      })
    end,
  },
}
```

</details>

## Commands

| Command                            | Description                                                                                                 | Examples                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `:AvanteAsk [question] [position]` | Ask AI about your code. Optional `position` set window position and `ask` enable/disable direct asking mode | `:AvanteAsk position=right Refactor this code here` |
| `:AvanteBuild`                     | Build dependencies for the project                                                                          |                                                     |
| `:AvanteChat`                      | Start a chat session with AI about your codebase. Default is `ask`=false                                    |                                                     |
| `:AvanteChatNew`                   | Start a new chat session. The current chat can be re-opened with the chat session selector                  |                                                     |
| `:AvanteHistory`                   | Opens a picker for your previous chat sessions                                                              |                                                     |
| `:AvanteClear`                     | Clear the chat history for your current chat session                                                        |                                                     |
| `:AvanteEdit`                      | Edit the selected code blocks                                                                               |                                                     |
| `:AvanteFocus`                     | Switch focus to/from the sidebar                                                                            |                                                     |
| `:AvanteRefresh`                   | Refresh all Avante windows                                                                                  |                                                     |
| `:AvanteStop`                      | Stop the current AI request                                                                                 |                                                     |
| `:AvanteSwitchProvider`            | Switch AI provider (e.g. openai)                                                                            |                                                     |
| `:AvanteShowRepoMap`               | Show repo map for project's structure                                                                       |                                                     |
| `:AvanteToggle`                    | Toggle the Avante sidebar                                                                                   |                                                     |
| `:AvanteModels`                    | Show model list                                                                                             |                                                     |
| `:AvanteSwitchSelectorProvider`    | Switch avante selector provider (e.g. native, telescope, fzf_lua, mini_pick, snacks)                        |                                                     |

## Highlight Groups

| Highlight Group             | Description                                   | Notes                                        |
| --------------------------- | --------------------------------------------- | -------------------------------------------- |
| AvanteTitle                 | Title                                         |                                              |
| AvanteReversedTitle         | Used for rounded border                       |                                              |
| AvanteSubtitle              | Selected code title                           |                                              |
| AvanteReversedSubtitle      | Used for rounded border                       |                                              |
| AvanteThirdTitle            | Prompt title                                  |                                              |
| AvanteReversedThirdTitle    | Used for rounded border                       |                                              |
| AvanteConflictCurrent       | Current conflict highlight                    | Default to `Config.highlights.diff.current`  |
| AvanteConflictIncoming      | Incoming conflict highlight                   | Default to `Config.highlights.diff.incoming` |
| AvanteConflictCurrentLabel  | Current conflict label highlight              | Default to shade of `AvanteConflictCurrent`  |
| AvanteConflictIncomingLabel | Incoming conflict label highlight             | Default to shade of `AvanteConflictIncoming` |
| AvantePopupHint             | Usage hints in popup menus                    |                                              |
| AvanteInlineHint            | The end-of-line hint displayed in visual mode |                                              |
| AvantePromptInput           | The body highlight of the prompt input        |                                              |
| AvantePromptInputBorder     | The border highlight of the prompt input      | Default to `NormalFloat`                     |

See [highlights.lua](./lua/avante/highlights.lua) for more information

## Fast Apply

Fast Apply is a feature that enables instant code edits with high accuracy by leveraging specialized models. It replicates Cursor's instant apply functionality, allowing for seamless code modifications without the typical delays associated with traditional code generation.

### Purpose and Benefits

Fast Apply addresses the common pain point of slow code application in AI-assisted development. Instead of waiting for a full language model to process and apply changes, Fast Apply uses a specialized "apply model" that can quickly and accurately merge code edits with 96-98% accuracy at speeds of 2500-4500+ tokens per second.

Key benefits:

- **Instant application**: Code changes are applied immediately without noticeable delays
- **High accuracy**: Specialized models achieve 96-98% accuracy for code edits
- **Seamless workflow**: Maintains the natural flow of development without interruptions
- **Large context support**: Handles up to 16k tokens for both input and output

### Configuration

To enable Fast Apply, you need to:

1. **Enable Fast Apply in your configuration**:

   ```lua
     behaviour = {
       enable_fastapply = true,  -- Enable Fast Apply feature
     },
     -- ... other configuration
   ```

2. **Get your Morph API key**:
   Go to [morphllm.com](https://morphllm.com/api-keys) and create an account and get the API key.

3. **Set your Morph API key**:

   ```bash
   export MORPH_API_KEY="your-api-key"
   ```

4. **Change Morph model**:
   ```lua
   providers = {
     morph = {
       model = "morph-v3-large",
     },
   }
   ```

### Model Options

Morph provides different models optimized for different use cases:

| Model            | Speed             | Accuracy | Context Limit |
| ---------------- | ----------------- | -------- | ------------- |
| `morph-v3-fast`  | 4500+ tok/sec     | 96%      | 16k tokens    |
| `morph-v3-large` | 2500+ tok/sec     | 98%      | 16k tokens    |
| `auto`           | 2500-4500 tok/sec | 98%      | 16k tokens    |

### How It Works

When Fast Apply is enabled and a Morph provider is configured, avante.nvim will:

1. Use the `edit_file` tool for code modifications instead of traditional tools
2. Send the original code, edit instructions, and update snippet to the Morph API
3. Receive the fully merged code back from the specialized apply model
4. Apply the changes directly to your files with high accuracy

The process uses a specialized prompt format that includes:

- `<instructions>`: Clear description of what changes to make
- `<code>`: The original code content
- `<update>`: The specific changes using truncation markers (`// ... existing code ...`)

This approach ensures that the apply model can quickly and accurately merge your changes without the overhead of full code generation.

## ACP Support

Avante.nvim now supports the [Agent Client Protocol (ACP)](https://agentclientprotocol.com/overview/introduction), enabling seamless integration with AI agents that follow this standardized communication protocol. ACP provides a unified way for AI agents to interact with development environments, offering enhanced capabilities for code editing, file operations, and tool execution.

Avante provides a set of default providers (codex, gemini, claude-code,...), but users can also create their own providers. Providers are configured in the `acp_providers` section of your configuration:
See `:h avante-acp` and [Custom Providers](https://github.com/yetone/avante.nvim/wiki/Custom-providers) for more information.

## RAG Service

Avante provides a RAG service, which is a tool for obtaining the required context for the AI to generate the codes. By default, it is not enabled. You can enable it this way:

```lua
  rag_service = { -- RAG Service configuration
    enabled = false, -- Enables the RAG service
    host_mount = os.getenv("HOME"), -- Host mount path for the rag service (Docker will mount this path)
    runner = "docker", -- Runner for the RAG service (can use docker or nix)
    llm = { -- Language Model (LLM) configuration for RAG service
      provider = "openai", -- LLM provider
      endpoint = "https://api.openai.com/v1", -- LLM API endpoint
      api_key = "OPENAI_API_KEY", -- Environment variable name for the LLM API key
      model = "gpt-4o-mini", -- LLM model name
      extra = nil, -- Additional configuration options for LLM
    },
    embed = { -- Embedding model configuration for RAG service
      provider = "openai", -- Embedding provider
      endpoint = "https://api.openai.com/v1", -- Embedding API endpoint
      api_key = "OPENAI_API_KEY", -- Environment variable name for the embedding API key
      model = "text-embedding-3-large", -- Embedding model name
      extra = {
        max_embedding_tokens = 512, -- Maximum tokens per chunk sent to the embedding model
      },
    },
    docker_extra_args = "", -- Extra arguments to pass to the docker command
  },
```

The RAG Service can currently configure the LLM and embedding models separately. In the `llm` and `embed` configuration blocks, you can set the following fields:

- `provider`: Model provider (e.g., "openai", "ollama", "dashscope", and "openrouter")
- `endpoint`: API endpoint
- `api_key`: Environment variable name for the API key
- `model`: Model name
- `extra`: Additional configuration options

For detailed configuration of different model providers, you can check [here](./py/rag-service/README.md).

Additionally, RAG Service also depends on Docker! (For macOS users, OrbStack is recommended as a Docker alternative).

`host_mount` is the path that will be mounted to the container, and the default is the home directory. The mount is required
for the RAG service to access the files in the host machine. It is up to the user to decide if you want to mount the whole
`/` directory, just the project directory, or the home directory. If you plan using avante and RAG event for projects
stored outside your home directory, you will need to set the `host_mount` to the root directory of your file system.

The mount will be read only.

After changing the rag_service configuration, you need to manually delete the rag_service container to ensure the new configuration is used: `docker rm -fv avante-rag-service`

## Web Search Engines

Avante's tools include some web search engines, currently support:

- [Tavily](https://tavily.com/)
- [SerpApi - Search API](https://serpapi.com/)
- [SearchAPI](https://www.searchapi.io/)
- Google's [Programmable Search Engine](https://developers.google.com/custom-search/v1/overview)
- [Kagi](https://help.kagi.com/kagi/api/search.html)
- [Brave Search](https://api-dashboard.search.brave.com/app/documentation/web-search/get-started)
- [SearXNG](https://searxng.github.io/searxng/)

Each engine is exposed as its own tool (`web_search_tavily`, `web_search_serpapi`,
`web_search_searchapi`, `web_search_google`, `web_search_kagi`, `web_search_brave`,
and `web_search_searxng`). Shared settings remain under `web_search_engine`:

```lua
web_search_engine = {
  proxy = nil, -- proxy support, e.g., http://127.0.0.1:7890
}
```

Environment variables required for providers:

- Tavily: `TAVILY_API_KEY`
- SerpApi: `SERPAPI_API_KEY`
- SearchAPI: `SEARCHAPI_API_KEY`
- Google:
  - `GOOGLE_SEARCH_API_KEY` as the [API key](https://developers.google.com/custom-search/v1/overview)
  - `GOOGLE_SEARCH_ENGINE_ID` as the [search engine](https://programmablesearchengine.google.com) ID
- Kagi: `KAGI_API_KEY` as the [API Token](https://kagi.com/settings?p=api)
- Brave Search: `BRAVE_API_KEY` as the [API key](https://api-dashboard.search.brave.com/app/keys)
- SearXNG: `SEARXNG_API_URL` as the [API URL](https://docs.searxng.org/dev/search_api.html)

## Disable Tools

Avante enables tools by default, but some LLM models do not support tools. You can disable tools by setting `disable_tools = true` for the provider. For example:

```lua
providers = {
  claude = {
    endpoint = "https://api.anthropic.com",
    model = "claude-sonnet-4-20250514",
    timeout = 30000, -- Timeout in milliseconds
    disable_tools = true, -- disable tools!
    extra_request_body = {
      temperature = 0,
      max_tokens = 4096,
    }
  }
}
```

In case you want to ban some tools to avoid its usage (like Claude 3.7 overusing the python tool) you can disable just specific tools

```lua
{
  disabled_tools = { "python" },
}
```

Tool list

> rag_search, python, git_diff, git_commit, glob, search_keyword, read_file_toplevel_symbols,
> read_file, create_file, move_path, copy_path, delete_path, create_dir, bash,
> web_search_tavily


## Custom Tools

See `:h avante-custom-tools`.

## MCP

Now you can integrate MCP functionality for Avante through `mcphub.nvim`. For detailed documentation, please refer to [mcphub.nvim](https://ravitemer.github.io/mcphub.nvim/extensions/avante.html)

## Custom prompts

By default, `avante.nvim` provides three different modes to interact with: `planning`, `editing`, and `suggesting`, followed with three different prompts per mode.

- `planning`: Used with `require("avante").toggle()` on sidebar
- `editing`: Used with `require("avante").edit()` on selection codeblock
- `suggesting`: Used with `require("avante").get_suggestion():suggest()` on Tab flow.
- `cursor-planning`: Used with `require("avante").toggle()` on Tab flow, but only when cursor planning mode is enabled.

Users can customize the system prompts via `Config.system_prompt` or `Config.override_prompt_dir`.

`Config.system_prompt` allows you to set a global system prompt. We recommend calling this in a custom Autocmds depending on your need:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ToggleMyPrompt",
  callback = function() require("avante.config").override({system_prompt = "MY CUSTOM SYSTEM PROMPT"}) end,
})

vim.keymap.set("n", "<leader>am", function() vim.api.nvim_exec_autocmds("User", { pattern = "ToggleMyPrompt" }) end, { desc = "avante: toggle my prompt" })
```

`Config.override_prompt_dir` allows you to specify a directory containing your own custom prompt templates, which will override the built-in templates. This is useful if you want to maintain a set of custom prompts outside of your Neovim configuration. It can be a string representing the directory path, or a function that returns a string representing the directory path.

```lua
-- Example: Override with prompts from a specific directory
require("avante").setup({
  override_prompt_dir = vim.fn.expand("~/.config/nvim/avante_prompts"),
})

-- Example: Override with prompts from a function (dynamic directory)
require("avante").setup({
  override_prompt_dir = function()
    -- Your logic to determine the prompt directory
    return vim.fn.expand("~/.config/nvim/my_dynamic_prompts")
  end,
})
```

> [!WARNING]
>
> If you customize `base.avanterules`, please ensure that `{% block custom_prompt %}{% endblock %}` and `{% block extra_prompt %}{% endblock %}` exist, otherwise the entire plugin may become unusable.
> If you are unsure about the specific reasons or what you are doing, please do not override the built-in prompts. The built-in prompts work very well.

If you wish to custom prompts for each mode, `avante.nvim` will check for project root based on the given buffer whether it contains
the following patterns: `*.{mode}.avanterules`.

The rules for root hierarchy:

- lsp workspace folders
- lsp root_dir
- root pattern of filename of the current buffer
- root pattern of cwd

You can also configure custom directories for your `avanterules` files using the `rules` option:

```lua
require('avante').setup({
  rules = {
    project_dir = '.avante/rules', -- relative to project root, can also be an absolute path
    global_dir = '~/.config/avante/rules', -- absolute path
  },
})
```

The loading priority is as follows:

1.  `rules.project_dir`
2.  `rules.global_dir`
3.  Project root

<details>

  <summary>Example folder structure for custom prompt</summary>

If you have the following structure:

```bash
.
├── .git/
├── typescript.planning.avanterules
├── snippets.editing.avanterules
├── suggesting.avanterules
└── src/

```

- `typescript.planning.avanterules` will be used for `planning` mode
- `snippets.editing.avanterules` will be used for `editing` mode
- `suggesting.avanterules` will be used for `suggesting` mode.

</details>

> [!important]
>
> `*.avanterules` is a jinja template file, in which will be rendered using [minijinja](https://github.com/mitsuhiko/minijinja). See [templates](https://github.com/yetone/avante.nvim/blob/main/lua/avante/templates) for example on how to extend current templates.

## Integrations

Avante.nvim can be extended to work with other plugins by using its extension modules. For instance with [`nvim-tree`](https://github.com/nvim-tree/nvim-tree.lua), see [the wiki](https://github.com/yetone/avante.nvim/wiki/plugin%E2%80%90integrations).

## TODOs

- [x] Chat with current file
- [x] Apply diff patch
- [x] Chat with the selected block
- [x] Slash commands
- [x] Edit the selected block
- [x] Smart Tab (Cursor Flow)
- [x] Chat with project (You can use `@codebase` to chat with the whole project)
- [x] Chat with selected files
- [x] Tool use
- [x] MCP
- [x] ACP
- [ ] Better codebase indexing

## Roadmap

- **Enhanced AI Interactions**: Improve the depth of AI analysis and recommendations for more complex coding scenarios.
- **LSP + Tree-sitter + LLM Integration**: Integrate with LSP and Tree-sitter and LLM to provide more accurate and powerful code suggestions and analysis.

## FAQ

### How to disable agentic mode?

Avante.nvim provides two interaction modes:

- **`agentic`** (default): Uses AI tools to automatically generate and apply code changes
- **`legacy`**: Uses the traditional planning method without automatic tool execution

To disable agentic mode and switch to legacy mode, update your configuration:

```lua
{
  mode = "legacy", -- Switch from "agentic" to "legacy"
  -- ... your other configuration options
}
```

**What's the difference?**

- **Agentic mode**: AI can automatically execute tools like file operations, bash commands, web searches, etc. to complete complex tasks
- **Legacy mode**: AI provides suggestions and plans but requires manual approval for all actions

**When should you use legacy mode?**

- If you prefer more control over what actions the AI takes
- If you're concerned about security with automatic tool execution
- If you want to manually review each step before applying changes
- If you're working in a sensitive environment where automatic code changes aren't desired

You can also disable specific tools while keeping agentic mode enabled by configuring `disabled_tools`:

```lua
{
  mode = "agentic",
  disabled_tools = { "bash", "python" }, -- Disable specific tools
  -- ... your other configuration options
}
```

## Contributing

Contributions to avante.nvim are welcome! If you're interested in helping out, please feel free to submit pull requests or open issues.

See [wiki](https://github.com/yetone/avante.nvim/wiki) for more recipes and tricks and [./CONTRIBUTING.md] to setup a local development environment.

## Acknowledgments

We would like to express our heartfelt gratitude to the contributors of the following open-source projects, whose code has provided invaluable inspiration and reference for the development of avante.nvim:

| Nvim Plugin                                                           | License            | Functionality                 | Location                                                                                                                               |
| --------------------------------------------------------------------- | ------------------ | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [git-conflict.nvim](https://github.com/akinsho/git-conflict.nvim)     | No License         | Diff comparison functionality | [lua/avante/diff.lua](https://github.com/yetone/avante.nvim/blob/main/lua/avante/diff.lua)                                             |
| [ChatGPT.nvim](https://github.com/jackMort/ChatGPT.nvim)              | Apache 2.0 License | Calculation of tokens count   | [lua/avante/utils/tokens.lua](https://github.com/yetone/avante.nvim/blob/main/lua/avante/utils/tokens.lua)                             |
| [img-clip.nvim](https://github.com/HakonHarnes/img-clip.nvim)         | MIT License        | Clipboard image support       | [lua/avante/clipboard.lua](https://github.com/yetone/avante.nvim/blob/main/lua/avante/clipboard.lua)                                   |
| [copilot.lua](https://github.com/zbirenbaum/copilot.lua)              | MIT License        | Copilot support               | [lua/avante/providers/copilot.lua](https://github.com/yetone/avante.nvim/blob/main/lua/avante/providers/copilot.lua)                   |
| [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) | MIT License        | Secrets logic support         | [lua/avante/providers/init.lua](https://github.com/yetone/avante.nvim/blob/main/lua/avante/providers/init.lua)                         |
| [aider](https://github.com/paul-gauthier/aider)                       | Apache 2.0 License | Planning mode user prompt     | [lua/avante/templates/planning.avanterules](https://github.com/yetone/avante.nvim/blob/main/lua/avante/templates/planning.avanterules) |

The high quality and ingenuity of these projects' source code have been immensely beneficial throughout our development process. We extend our sincere thanks and respect to the authors and contributors of these projects. It is the selfless dedication of the open-source community that drives projects like avante.nvim forward.

## Business Sponsors

<table>
  <tr>
    <td align="center">
      <a href="https://s.kiiro.ai/r/ylVbT6" target="_blank">
        <img height="80" src="https://github.com/user-attachments/assets/1abd8ede-bd98-4e6e-8ee0-5a661b40344a" alt="Meshy AI" /><br/>
        <strong>Meshy AI</strong>
        <div>&nbsp;</div>
        <div>The #1 AI 3D Model Generator for Creators</div>
      </a>
    </td>
    <td align="center">
      <a href="https://s.kiiro.ai/r/mGPJOd" target="_blank">
        <img height="80" src="https://github.com/user-attachments/assets/7b7bd75e-1fd2-48cc-a71a-cff206e4fbd7" alt="BabelTower API" /><br/>
        <strong>BabelTower API</strong>
        <div>&nbsp;</div>
        <div>No account needed, use any model instantly</div>
      </a>
    </td>
  </tr>
</table>

## License

avante.nvim is licensed under the Apache 2.0 License. For more details, please refer to the [LICENSE](./LICENSE) file.

# Star History

<p align="center">
  <a target="_blank" href="https://star-history.dera.page/#avante-corp/avante.nvim&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=avante-corp/avante.nvim&type=Date&theme=dark">
      <img alt="NebulaGraph Data Intelligence Suite(ngdi)" src="https://star-history.dera.page/svg?repos=avante-corp/avante.nvim&type=Date">
    </picture>
  </a>
</p>
