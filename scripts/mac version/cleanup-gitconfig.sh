#!/bin/bash

# GitConfig Cleanup Script - macOS Version
# Removes symlinks, config files, and launchd agent created by setup-gitconfig.sh.

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
    cat << 'EOF'
GitConfig Cleanup Script - macOS Version

USAGE: ./cleanup-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Skip confirmation prompts
    -h, --help      Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Backs up and removes .gitconfig, .gitignore_global, gitconfig_helper.py
    2. Removes .gitconfig.local
    3. Unloads and removes the launchd login agent
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"

echo "GitConfig Cleanup (macOS)"
echo "====================================="
echo ""

if [ "$FORCE" = false ]; then
    echo "WARNING: This will remove all gitconfig-related files and the launchd agent."
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
    backup_file "$HOME_DIR/$file" && ((REMOVED++)) || true
done
echo ""

# STEP 2: Remove .gitconfig.local
echo "[STEP 2] Removing .gitconfig.local..."
echo "-----"
backup_file "$HOME_DIR/.gitconfig.local" && ((REMOVED++)) || true
echo ""

# STEP 3: Remove launchd agent (macOS-specific)
echo "[STEP 3] Removing launchd login agent..."
echo "-----"

PLIST_LABEL="com.gitconfig.update"
PLIST_PATH="$HOME_DIR/Library/LaunchAgents/$PLIST_LABEL.plist"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null && echo "[OK] Unloaded launchd agent" || echo "[WARN] Could not unload agent (may not be running)"
    rm -f "$PLIST_PATH"
    echo "[OK] Removed launchd plist: $PLIST_PATH"
    ((REMOVED++))
else
    echo "[SKIP] launchd plist not found"
fi
echo ""

# STEP 4: Verify
echo "[STEP 4] Verifying cleanup..."
echo "-----"

ERRORS=0
for file in ".gitconfig" ".gitignore_global" "gitconfig_helper.py" ".gitconfig.local"; do
    [ ! -e "$HOME_DIR/$file" ] && echo "[OK] $file removed" || { echo "[FAIL] $file still exists!"; ((ERRORS++)); }
done
[ ! -f "$PLIST_PATH" ] && echo "[OK] launchd agent removed" || { echo "[FAIL] launchd plist still exists!"; ((ERRORS++)); }
git --version > /dev/null 2>&1 && echo "[OK] Git still functional"

echo ""
echo "[SUMMARY]"
echo "====================================="
if [ $ERRORS -eq 0 ]; then
    echo "Cleanup SUCCESSFUL!"
    echo ""
    echo "To reinstall, run:"
    echo "  bash $SCRIPT_DIR/setup-gitconfig.sh --force"
else
    echo "Cleanup INCOMPLETE — $ERRORS items still present"
fi
echo ""
