#!/usr/bin/env bash
# Install required and optional plugin dependencies into the supplied directory.
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AVANTE_ROCKSPEC="$SCRIPT_DIR/../avante.nvim-dev-1.rockspec"

# Optional integrations needed to resolve their types during Lua typechecking.
OPTIONAL_DEPS=(
    snacks.nvim
    telescope.nvim
    nvim-cmp
    fzf-lua
    lazy.nvim
)

verbose=false

log_verbose() {
    if [ "$verbose" = "true" ]; then
        echo "$1" >&2
    fi
}

die() {
    echo "Error: $1" >&2
    exit 1
}

install_deps() {
    local deps_dir="$1"

    command -v luarocks &>/dev/null || die "luarocks is not installed."
    log_verbose "Installing rockspec dependencies into: $deps_dir"
    local luarocks_args=(--lua-version=5.1 --tree="$deps_dir")
    luarocks "${luarocks_args[@]}" make --only-deps --deps-mode=one "$AVANTE_ROCKSPEC" || return 1

    local dep
    for dep in "${OPTIONAL_DEPS[@]}"; do
        log_verbose "Installing optional dependency: $dep"
        luarocks "${luarocks_args[@]}" install --deps-mode=one "$dep" || return 1
    done
}

generate_luarc() {
    local luarc_path="${1}"
    local luarc_source="$SCRIPT_DIR/../.luarc.json"

    log_verbose "Generating luarc file at: $luarc_path"
    mkdir -p "$(dirname "$luarc_path")"
    cp "$luarc_source" "$luarc_path"
}

main() {
    local command=""
    local args=()

    # Manual parsing for flags and command
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
            verbose=true
            shift
            ;;
            *)
            if [ -z "$command" ]; then
                command=$1
            else
                args+=("$1")
            fi
            shift
            ;;
        esac
    done

    # TODO pass args explicitly in CI directly
    if [ "$GITHUB_ACTIONS" = "true" ]; then
        # Always be verbose in CI
        verbose=true
    fi

    echo "$AVANTE_RUNTIME_TEST_DIR"
    mkdir -p "$AVANTE_RUNTIME_TEST_DIR"

    if [ "$command" == "clone" ]; then
        install_deps "${args[@]}"
    elif [ "$command" == "generate-luarc" ]; then
        generate_luarc "${args[@]}"
    else
        echo "Usage: $0 [-v|--verbose] {clone [dir]|generate-luarc [path]}"
        exit 1
    fi
}

main "$@"
