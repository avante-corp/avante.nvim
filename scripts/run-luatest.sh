#!/usr/bin/env bash
set -e

DEST_DIR="$PWD/target/tests"
DEPS_DIR="$DEST_DIR/deps"

log() {
    echo "$1" >&2
}

check_tools() {
    command -v rg &>/dev/null || {
        log "Error: ripgrep (rg) is not installed. Please install it."
        exit 1
    }
    command -v ag &>/dev/null || {
        log "Error: silversearcher-ag (ag) is not installed. Please install it."
        exit 1
    }
}

# nui.nvim is a real dependency of lua/avante/sidebar.lua. Without it the
# sidebar specs silently skip rather than fail, which hides regressions.
clone_dep() {
    local name="$1"
    local repo="$2"
    local path="$DEPS_DIR/$name"
    if [ -d "$path/.git" ]; then
        log "$name already exists. Updating..."
        (
            cd "$path"
            git fetch -q
            if git show-ref --verify --quiet refs/remotes/origin/main; then
                git reset -q --hard origin/main
            elif git show-ref --verify --quiet refs/remotes/origin/master; then
                git reset -q --hard origin/master
            fi
        )
    elif [ -d "$path" ]; then
        log "$name present (non-git); leaving as-is."
    else
        log "Cloning $name..."
        mkdir -p "$DEPS_DIR"
        git clone --depth 1 "$repo" "$path"
    fi
}

setup_deps() {
    clone_dep "nui.nvim" "https://github.com/MunifTanjim/nui.nvim.git"
    local plenary_path="$DEPS_DIR/plenary.nvim"
    if [ -d "$plenary_path/.git" ]; then
        log "plenary.nvim already exists. Updating..."
        (
            cd "$plenary_path"
            git fetch -q
            if git show-ref --verify --quiet refs/remotes/origin/main; then
                git reset -q --hard origin/main
            elif git show-ref --verify --quiet refs/remotes/origin/master; then
                git reset -q --hard origin/master
            fi
        )
    else
        if [ -d "$plenary_path" ]; then
            log "Removing non-git plenary.nvim directory and re-cloning."
            rm -rf "$plenary_path"
        fi
        log "Cloning plenary.nvim..."
        mkdir -p "$DEPS_DIR"
        git clone --depth 1 "https://github.com/nvim-lua/plenary.nvim.git" "$plenary_path"
    fi
}

run_tests() {
    log "Running tests..."
    nvim --headless --clean \
        -c "set runtimepath+=$DEPS_DIR/plenary.nvim" \
        -c "set runtimepath+=$DEPS_DIR/nui.nvim" \
        -c "lua require('plenary.test_harness').test_directory('tests/', { minimal_init = 'tests/minimal_init.lua' })"
}

main() {
    check_tools
    setup_deps
    run_tests
}

main "$@"
