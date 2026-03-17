#!/bin/bash
# Run the avante ACP wrapper with the required dependencies.
# npx --package installs the package and makes it available to node.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec npx --yes --package @zed-industries/claude-code-acp node "$SCRIPT_DIR/acp-wrapper.mjs"
