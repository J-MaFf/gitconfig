#!/bin/bash

# GitConfig Cleanup Script - macOS and Linux
# Removes the links, config files, and auto-sync job (launchd agent on macOS,
# cron job on Linux) created by install.sh. The per-OS scripts in
# scripts/mac version/ and scripts/linux version/ are wrappers around this one.

set -e

FORCE=false
HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force) FORCE=true; shift ;;
        -h|--help)  HELP=true;  shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << 'HELP'
GitConfig Cleanup Script - macOS and Linux

USAGE: scripts/unix/cleanup-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Skip confirmation prompts
    -h, --help      Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Removes .gitconfig, .gitignore_global, gitconfig_helper.py
    2. Removes .gitconfig.local
    Removed files are kept as timestamped backups (<file>.bak.YYYYMMDD-HHMMSS,
    newest $GITCONFIG_BACKUP_KEEP kept, default 5). The first backup of a file
    also keeps your original as <file>.pre-gitconfig, which is never pruned.
    Symlinks into this repo are removed without a backup.
    3. Removes the auto-sync job: unloads and deletes the launchd login agent
       on macOS; deletes the cron line on Linux (lines tagged
       "# gitconfig-autoupdate", plus untagged ones from older installs that
       run update-gitconfig.sh; other cron entries are kept)
HELP
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"
# shellcheck source=../shared/platform.sh
source "$REPO_ROOT/scripts/shared/platform.sh"

# No wrong-platform guard here: cleanup only removes what install made, and a
# leftover launchd plist or cron line should be removable from anywhere. The
# per-OS wrappers still pick which platform's job to remove.
TARGET_OS="$(requested_os)" || exit 1
SCHEDULER_NAME="$(scheduler_name "$TARGET_OS")"

echo "GitConfig Cleanup ($(os_display_name "$TARGET_OS"))"
echo "====================================="
echo ""

if [ "$FORCE" = false ]; then
    echo "WARNING: This will remove all gitconfig-related files and the $SCHEDULER_NAME."
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

REMOVED=0

# STEP 1: Remove symlinks and generated files
echo "[STEP 1] Removing symlinks and generated files..."
echo "-----"
for file in ".gitconfig" ".gitignore_global" "gitconfig_helper.py"; do
    backup_file "$HOME_DIR/$file" "$REPO_ROOT" && REMOVED=$((REMOVED+1)) || true
done
echo ""

# STEP 2: Remove .gitconfig.local
echo "[STEP 2] Removing .gitconfig.local..."
echo "-----"
backup_file "$HOME_DIR/.gitconfig.local" && REMOVED=$((REMOVED+1)) || true
echo ""

# STEP 2b: Remove the git-alias browser keybinding from shell rc files
echo "[STEP 2b] Removing git-alias browser keybinding..."
echo "-----"
disable_git_alias_widget "$HOME_DIR"
echo ""

# STEP 3: Remove the auto-sync job
if [ "$TARGET_OS" = macos ]; then
    echo "[STEP 3] Removing launchd login agent..."
else
    echo "[STEP 3] Removing cron job..."
fi
echo "-----"
scheduler_remove "$TARGET_OS" && REMOVED=$((REMOVED+1)) || true
echo ""

# STEP 4: Verify
echo "[STEP 4] Verifying cleanup..."
echo "-----"

ERRORS=0
for file in ".gitconfig" ".gitignore_global" "gitconfig_helper.py" ".gitconfig.local"; do
    [ ! -e "$HOME_DIR/$file" ] && echo "[OK] $file removed" || { echo "[FAIL] $file still exists!"; ERRORS=$((ERRORS+1)); }
done
if scheduler_status "$TARGET_OS"; then
    echo "[FAIL] $SCHEDULER_NAME still exists!"
    ERRORS=$((ERRORS+1))
else
    echo "[OK] $SCHEDULER_NAME removed"
fi
git --version > /dev/null 2>&1 && echo "[OK] Git still functional" || echo "[WARN] Git may be unavailable"

echo ""
echo "[SUMMARY]"
echo "====================================="
if [ $ERRORS -eq 0 ]; then
    echo "Cleanup SUCCESSFUL!"
    echo ""
    echo "To reinstall, run:"
    echo "  bash $SCRIPT_DIR/install.sh --force"
else
    echo "Cleanup INCOMPLETE - $ERRORS items still present"
fi
echo ""
