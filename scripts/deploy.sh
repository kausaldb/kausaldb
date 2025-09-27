#!/usr/bin/env bash
set -euo pipefail

# Simple, robust deployment script for KausalDB
# Usage: ./scripts/deploy.sh [command]
# Example: ./scripts/deploy.sh "test-e2e -Dseed=0x8BADF00D"

SERVER="${KAUSAL_SERVER:-mitander@server}"
REMOTE_PATH="${KAUSAL_PATH:-~/kausaldb}"
COMMAND="${1:-test}"

echo "==> Deploying to $SERVER:$REMOTE_PATH"

# Sync git-tracked files only
echo "==> Syncing files..."
git ls-files -z | rsync -av --files-from=- --from0 . "$SERVER:$REMOTE_PATH/"

# Run command on remote
echo "==> Running: $COMMAND"
ssh "$SERVER" "cd $REMOTE_PATH && {
    # Ensure Zig is installed
    if [ ! -f zig/zig ]; then
        echo 'Installing Zig...'
        ./scripts/install_zig.sh
    fi

    # Run the command
    ./zig/zig build $COMMAND
}"

echo "==> Done"
