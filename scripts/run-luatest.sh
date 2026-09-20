#!/usr/bin/env bash
set -e

DEST_DIR="${AVANTE_RUNTIME_TEST_DIR:-$PWD/target/tests}"
NVIM_TEST_HOME="$DEST_DIR/nvim"

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
    command -v nlua &>/dev/null || {
        log "Error: nlua is not installed. Please install nlua."
        exit 1
    }
    command -v busted &>/dev/null || {
        log "Error: busted is not installed. Please install busted."
        exit 1
    }
}

run_tests() {
    log "Running tests..."
    mkdir -p "$NVIM_TEST_HOME"/{config,data,state,cache}
    local test_roots=("$@")
    if [ ${#test_roots[@]} -eq 0 ]; then
        test_roots=("tests")
    fi

    XDG_CONFIG_HOME="$NVIM_TEST_HOME/config" \
        XDG_DATA_HOME="$NVIM_TEST_HOME/data" \
        XDG_STATE_HOME="$NVIM_TEST_HOME/state" \
        XDG_CACHE_HOME="$NVIM_TEST_HOME/cache" \
        busted "${test_roots[@]}"
}

main() {
    check_tools
    run_tests "$@"
}

main "$@"
