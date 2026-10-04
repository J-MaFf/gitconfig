#!/bin/bash
# Linux entry point, kept permanently so existing commands and docs keep working.
# The implementation is scripts/unix/cleanup-gitconfig.sh (shared by macOS and Linux);
# GITCONFIG_PLATFORM=linux makes it remove the Linux auto-sync job.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITCONFIG_PLATFORM=linux exec bash "$SCRIPT_DIR/../unix/cleanup-gitconfig.sh" "$@"
