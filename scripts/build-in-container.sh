#!/bin/sh
# Used by the GitHub build action.
set -eu

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <docker-platform> <container> <make-target>" >&2
  exit 2
fi

docker_platform="$1"
container="$2"
feature="$3"

# Share downloads with rust-cache; keep host rustup and container binaries isolated.
mkdir -p "$HOME/.cargo/registry" "$HOME/.cargo/git" target

docker run \
  --rm -i \
  -v "$(pwd):/workspace" \
  -v "$HOME/.cargo/registry:/root/.cargo/registry" \
  -v "$HOME/.cargo/git:/root/.cargo/git" \
  -w /workspace \
  --platform "$docker_platform" \
  "$container" \
  bash -s -- \
    "$feature" "$(id -u)" "$(id -g)" <<'EOF'
  set -euo pipefail

  # Return root-owned build outputs to the runner so rust-cache can prune/save them.
  trap 'chown -R "$2:$3" /workspace/target /root/.cargo/registry /root/.cargo/git' EXIT

  yum install -y perl-IPC-Cmd perl-Time-Piece openssl-devel
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain 1.99.0

  . /root/.cargo/env && make "$1"
EOF
