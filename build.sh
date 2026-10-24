#!/usr/bin/env bash

set -e
if [ $# -lt 1 ]; then
  echo "Use: $0 VERSION [repository_url]"
  echo "Please call :AvanteBuild directly from neovim"
  exit 1
fi

release_version="${1}"
latest_tag="v${release_version#v}"

REMOTE_URL="${2:-https://github.com/avante-corp/avante.nvim}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set the target directory to clone the artifact
TARGET_DIR="${SCRIPT_DIR}/lua"

# Get the artifact download URL based on the platform and Lua version
case "$(uname -s)" in
Linux*)
  PLATFORM="linux"
  CARGO_EXT="so"
  LIB_EXT="so"
  ;;
Darwin*)
  PLATFORM="darwin"
  CARGO_EXT="dylib"
  LIB_EXT="so"
  ;;
CYGWIN* | MINGW* | MSYS*)
  PLATFORM="windows"
  CARGO_EXT="dll"
  LIB_EXT="dll"
  ;;
*)
  echo "Unsupported platform"
  exit 1
  ;;
esac

# Get the architecture (x86_64 or aarch64)
case "$(uname -m)" in
x86_64)
  ARCH="x86_64"
  ;;
aarch64)
  ARCH="aarch64"
  ;;
arm64)
  ARCH="aarch64"
  ;;
*)
  echo "Unsupported architecture"
  exit 1
  ;;
esac

# Set the Lua version (lua54 or luajit)
LUA_VERSION="${LUA_VERSION:-luajit}"

# Set the artifact name pattern
ARTIFACT_NAME_PATTERN="avante_lib-$PLATFORM-$ARCH-$LUA_VERSION"

if [ ! -d "$TARGET_DIR" ]; then
  mkdir -p "$TARGET_DIR"
fi


# Get the artifact download URL
ARTIFACT_URL="$REMOTE_URL/releases/download/$latest_tag/avante_lib-$PLATFORM-$ARCH-$LUA_VERSION.tar.gz"

archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT

if ! curl -fL "$ARTIFACT_URL" -o "$archive"; then
  echo "Failed to download prebuilt libraries for $latest_tag. Check that the passed version is correct and has a release for $PLATFORM-$ARCH-$LUA_VERSION." >&2
  echo "Download URL: $ARTIFACT_URL" >&2
  exit 1
fi

tar -zxvf "$archive" -C "$TARGET_DIR"
