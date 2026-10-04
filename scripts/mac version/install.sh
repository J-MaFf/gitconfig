#!/bin/bash
# macOS entry point, kept permanently so existing commands and docs keep working.
# The implementation is scripts/unix/install.sh (shared by macOS and Linux);
# GITCONFIG_PLATFORM=macos makes it act for macOS and refuse to run on another OS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITCONFIG_PLATFORM=macos exec bash "$SCRIPT_DIR/../unix/install.sh" "$@"
