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

docker run \
  --rm \
  -v "$(pwd):/workspace" \
  -w /workspace \
  --platform "$docker_platform" \
  "$container" \
  bash -c "yum install -y perl-IPC-Cmd perl-Time-Piece openssl-devel && curl --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.99.0 && . /root/.cargo/env && make '$feature'"
