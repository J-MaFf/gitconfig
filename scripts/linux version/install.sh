#!/bin/bash
# Linux entry point, kept permanently so existing commands and docs keep working.
# The implementation is scripts/unix/install.sh (shared by macOS and Linux);
# GITCONFIG_PLATFORM=linux makes it act for Linux and refuse to run on another OS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITCONFIG_PLATFORM=linux exec bash "$SCRIPT_DIR/../unix/install.sh" "$@"
