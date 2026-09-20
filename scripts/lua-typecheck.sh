#!/usr/bin/env bash
# First call setup-deps to setup dependencies
# typecheck using the installed Neovim runtime and lua-language-server.
set -e

verbose=false

log() {
    echo "$1" >&2
}

log_verbose() {
    if [ "$verbose" = "true" ]; then
        echo "$1" >&2
    fi
}

die() {
    echo "Error: $1" >&2
    exit 1
}

run_typechecker() {
    local config_path="$1"
    if [ -z "$VIMRUNTIME" ]; then
        die "VIMRUNTIME is not set. Cannot proceed."
    fi
    if [ -z "$config_path" ]; then
        die "Luarc config path is not set. Cannot proceed."
    fi
    command -v lua-language-server &>/dev/null || die "lua-language-server not found in PATH."

    log "Running Lua typechecker..."
    lua-language-server --check="$PWD/lua" \
        --loglevel=trace \
        --configpath="$config_path" \
        --checklevel=Information
    log_verbose "Typecheck complete."
}

main() {
    # TODO pass it as arg
    local dest_dir="$AVANTE_RUNTIME_TEST_DIR"
    local luarc_path="$dest_dir/luarc.json"

    for arg in "$@"; do
        case $arg in
            --verbose|-v)
            verbose=true
            shift
            ;;
        esac
    done

    log "Setting up environment in: $dest_dir"

    VIMRUNTIME="$(nvim --headless --noplugin -u NONE -i NONE -c 'echo $VIMRUNTIME' +qa 2>&1)"
    export VIMRUNTIME
    export DEPS_PATH="$dest_dir/deps"

    log "VIMRUNTIME: $VIMRUNTIME"
    log "DEPS_PATH: $DEPS_PATH"

    run_typechecker "$luarc_path"
}

main "$@"
