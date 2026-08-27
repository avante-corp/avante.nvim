#!/usr/bin/env bash

set -e

REMOTE_URL="${1:-https://github.com/yetone/avante.nvim.git}"

if [[ "$REMOTE_URL" == *"github.com"* ]]; then
  tmp="${REMOTE_URL#*github.com[:/]}"
  tmp="${tmp%.git}"
  REPO_OWNER="${tmp%/*}"
  REPO_NAME="${tmp#*/}"
else
  REPO_OWNER="yetone"
  REPO_NAME="avante.nvim"
fi

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

test_command() {
  command -v "$1" >/dev/null 2>&1
}

fetch_remote_tags() {
  git ls-remote --tags "$REMOTE_URL" | cut -f2 | sed 's|refs/tags/||' | while read -r tag; do
    if ! git rev-parse "$tag" >/dev/null 2>&1; then
      git fetch "$REMOTE_URL" "refs/tags/$tag:refs/tags/$tag"
    fi
  done
}

if [ ! -d "$TARGET_DIR" ]; then
  mkdir -p "$TARGET_DIR"
fi

fetch_remote_tags
latest_tag="$(git describe --tags --abbrev=0 --match "v*" || true)" # will be empty in clone repos
built_tag="$(cat "${TARGET_DIR}/.tag" 2>/dev/null || true)"

save_tag() {
  echo "$latest_tag" > "${TARGET_DIR}/.tag"
}

if [[ "$latest_tag" = "$built_tag" && -n "$latest_tag" ]]; then
  echo "Local build is up to date $latest_tag. No download needed."
elif [[ "$latest_tag" != "$built_tag" && -n "$latest_tag" ]]; then
  echo "Local build is out of date $built_tag. Downloading latest $latest_tag."

  # Get the artifact download URL
  DOWNLOAD_URL=$(curl -sSL "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/tags/$latest_tag" | grep "browser_download_url")
  ARTIFACT_URL=$(echo "$DOWNLOAD_URL" | cut -d '"' -f 4 | grep "$ARTIFACT_NAME_PATTERN")

  mkdir -p "$TARGET_DIR"

  curl -L "$ARTIFACT_URL" | tar -zxv -C "$TARGET_DIR"
  save_tag
else
  echo "No latest tag found. Run ':AvanteBuild source=true'."
fi
