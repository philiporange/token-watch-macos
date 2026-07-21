#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Set DEVELOPER_DIR if unset and Xcode exists at the default path
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEFAULT_XCODE="/Applications/Xcode.app/Contents/Developer"
    if [ -d "$DEFAULT_XCODE" ]; then
        export DEVELOPER_DIR="$DEFAULT_XCODE"
    fi
fi

# Run swift test from app/ directory, forwarding all arguments
cd "$REPO_ROOT/app"
exec swift test "$@"
