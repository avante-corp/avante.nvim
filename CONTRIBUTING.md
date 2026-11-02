# CONTRIBUTING

Contributions to avante.nvim are welcome! If you're interested in helping out, please feel free to submit pull requests or open issues. Before contributing, ensure that your code has been thoroughly tested.

## Set up the development environment:

## With nix

Running `nix develop` will give you a shell with all dependencies.
You can build the rag service with `nix build .#ragService` or install it
declaratively with uv via:

```
uv venv --no-managed-python
source .venv/bin/activate
uv pip install py/rag-service
```

## Other systems

1. Install [StyLua](https://github.com/JohnnyMorganz/StyLua) for Lua code formatting.
2. Install [pre-commit](https://pre-commit.com) for managing and maintaining pre-commit hooks.
3. After cloning the repository, run the following command to set up pre-commit hooks:

```sh
pre-commit install --install-hooks
rustup component add rustfmt
rustup component add clippy
```

## Tooling configuration

For setting up lua_ls you can use the following for `nvim-lspconfig`:

```lua
lua_ls = {
  settings = {
    Lua = {
      runtime = {
        version = "LuaJIT",
        special = { reload = "require" },
      },
      workspace = {
        library = {
          vim.fn.expand "$VIMRUNTIME/lua",
          vim.fn.expand "$VIMRUNTIME/lua/vim/lsp",
          vim.fn.stdpath "data" .. "/lazy/lazy.nvim/lua/lazy",
        },
      },
    },
  },
},
```

You can also use the following config for `lazydev.nvim`:

```lua
      {
        "folke/lazydev.nvim",
        ft = "lua",
        cmd = "LazyDev",
        opts = {
          dependencies = {
            -- Manage libuv types with lazy. Plugin will never be loaded
            { "Bilal2453/luvit-meta", lazy = true },
          },
          library = {
            { path = "~/workspace/avante.nvim/lua", words = { "avante" } },
            { path = "luvit-meta/library", words = { "vim%.uv" } },
          },
        },
      },
```

Then you can set `dev = true` in your `lazy` config for development.

# How to run the tests ?

Use the Makefile targets to run checks; they set the test runtime and dependency paths.

```
make setup-deps
make lint
make lua-typecheck
make luatest
```

Set `AVANTE_RUNTIME_TEST_DIR` or `DEPS_PATH` when invoking `make` to override the default directories under `target/tests`.

# How to bump CI/CD actions

Install [gh-actions-lock](https://github.com/github/gh-actions-lock), then run the Makefile target:

```sh
gh extension install github/gh-actions-lock
make upgrade-actions
```

Review and commit the workflow and `.github/workflows/actions.lock` changes together.

# How to create a new release ? (maintainers-only)

1. Merge changes into `main` using [Conventional Commits](https://www.conventionalcommits.org/).
2. Review and merge the release PR opened by [Release Please](https://github.com/googleapis/release-please-action). It updates `CHANGELOG.md`, `lua/avante/version.lua`, the Rust workspace version and lockfile, and the release manifest.
3. The release workflow creates the version tag and GitHub release, builds and uploads binary assets, then publishes to LuaRocks for the upstream repository.

Enable **Allow GitHub Actions to create and approve pull requests** under the repository's **Settings > Actions > General**. The workflow uses `GITHUB_TOKEN`; its release PRs do not automatically trigger other workflows, so run any required checks manually before merging.

The release configuration uses the `go` strategy without a `version-file` to update the changelog without generating `version.txt`. Generic and TOML updaters in `extra-files` maintain the Lua and Rust versions. The Lua version is available through `require("avante.version")`.
