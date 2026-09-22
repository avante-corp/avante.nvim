#!/usr/bin/env bash
# Install required and optional plugin dependencies into ./target/tests/deps,
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AVANTE_ROCKSPEC="$SCRIPT_DIR/../avante.nvim-scm-1.rockspec"

# Optional integrations needed to resolve their types during Lua typechecking.
OPTIONAL_DEPS=(
    neodev.nvim
    snacks.nvim
    telescope.nvim
    nvim-cmp
    fzf-lua
    copilot.lua
    lazy.nvim
)

LUALS_VERSION="3.18.2"

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

install_luals() {
    local dest_dir=${1:-"$PWD/target/tests"}

    # Detect operating system and architecture
    local os_name=""
    local arch=""
    local file_ext=""

    case "$(uname -s)" in
        Linux*)
            os_name="linux"
            file_ext="tar.gz"
            ;;
        Darwin*)
            os_name="darwin"
            file_ext="tar.gz"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            os_name="win32"
            file_ext="zip"
            ;;
        *)
            log "Unsupported operating system: $(uname -s)"
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)
            arch="x64"
            ;;
        arm64|aarch64)
            arch="arm64"
            ;;
        *)
            log "Unsupported architecture: $(uname -m), falling back to x64"
            arch="x64"
            ;;
    esac

    local platform="${os_name}-${arch}"
    local luals_download_url="https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/lua-language-server-${LUALS_VERSION}-${platform}.${file_ext}"

    local luals_dir="$dest_dir/lua-language-server-${LUALS_VERSION}-${platform}"

    if [ ! -d "$luals_dir" ]; then
        log "Installing lua-language-server ${LUALS_VERSION} for ${platform} from https://github.com/LuaLS/lua-language-server/releases..."
        mkdir -p "$luals_dir"

        if [ "$file_ext" = "tar.gz" ]; then
            curl -sSL "${luals_download_url}" | tar zx --directory "$luals_dir"
        else
            # For zip files, download first then extract
            local temp_file="/tmp/luals-${LUALS_VERSION}.zip"
            curl -sSL "${luals_download_url}" -o "$temp_file"
            unzip -q "$temp_file" -d "$luals_dir"
            rm -f "$temp_file"
        fi
    else
        log_verbose "lua-language-server is already installed in $luals_dir"
    fi
    echo "$luals_dir/bin"
}

install_nvim_runtime() {
    local dest_dir=${1:-"$PWD/target/tests"}

    command -v jq &>/dev/null || die "jq is not installed for parsing GitHub API responses."

    local nvim_version
    nvim_version="v0.12.0"
    log_verbose "Parsed nvim version from workflow: $nvim_version"

    log_verbose "Resolving ${nvim_version} Neovim release from GitHub API..."
    local api_url="https://api.github.com/repos/neovim/neovim/releases"
    if [ "$nvim_version" == "stable" ]; then
        api_url="$api_url/latest"
    else
        api_url="$api_url/tags/${nvim_version}"
    fi

    local release_data
    release_data="$(curl -s "$api_url")"
    if [ -z "$release_data" ] || echo "$release_data" | jq -e '.message == "Not Found"' > /dev/null; then
        die "Failed to fetch release data from GitHub API for version '${nvim_version}'."
    fi

    # Find the correct asset by regex and extract its name and download URL.
    local asset_info
    asset_info="$(echo "$release_data" | \
      jq -r '.assets[] | select(.name | test("nvim-linux(64|-x86_64)\\.tar\\.gz$")) | .name + " " + .browser_download_url')"

    if [ -z "$asset_info" ]; then
        die "Could not find a suitable linux tarball asset for version '${nvim_version}'."
    fi

    local asset_name
    local download_url
    read -r asset_name download_url <<< "$asset_info"

    local actual_version
    actual_version="$(echo "$download_url" | grep -E -o 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [ -z "$actual_version" ]; then
        die "Could not resolve a version tag from URL: $download_url"
    fi
    log_verbose "Resolved Neovim version is ${actual_version}"

    local runtime_dir="$dest_dir/nvim-${actual_version}-runtime"
    if [ ! -d "$runtime_dir" ]; then
        log "Installing Neovim runtime (${actual_version})..."
        mkdir -p "$runtime_dir"
        curl -sSL "${download_url}" | \
            tar xzf - -C "$runtime_dir" --strip-components=4 \
                "${asset_name%.tar.gz}/share/nvim/runtime"
    else
        log_verbose "Neovim runtime (${actual_version}) is already installed"
    fi
    echo "$runtime_dir"
}

generate_luarc() {
    local luarc_path="${1}"
    local luarc_template="$SCRIPT_DIR/../luarc.json.template"

    log_verbose "Generating luarc file at: $luarc_path"
    mkdir -p "$(dirname "$luarc_path")"

    # LuaRocks installs all dependency modules into a shared Lua library directory.
    # TODO does path depends on lua interpreter version?
    sed 's#{{DEPS}}#, "$DEPS_PATH/share/lua/5.1"#' "$luarc_template" > "$luarc_path"
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
    elif [ "$command" == "install-luals" ]; then
        install_luals "${args[@]}"
    elif [ "$command" == "install-nvim" ]; then
        install_nvim_runtime "${args[@]}"
    else
        echo "Usage: $0 [-v|--verbose] {clone [dir]|generate-luarc [path]|install-luals [dir]|install-nvim [dir]}"
        exit 1
    fi
}

main "$@"
