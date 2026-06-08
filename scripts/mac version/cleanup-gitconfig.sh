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
    1. Backs up and removes .gitconfig (generated file)
    2. Removes symlinks (.gitignore_global and gitconfig_helper.py)
    3. Removes .gitconfig.local
    4. Unloads and removes the launchd login agent
    5. Backs up removed files for recovery
EOF
    exit 0
fi

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

HOME_DIR="$HOME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVED=0

# STEP 1: Remove symlinks and generated files
echo "[STEP 1] Removing symlinks and generated files..."
echo "-----"

FILES_TO_REMOVE=(".gitconfig" ".gitignore_global" "gitconfig_helper.py")

for file in "${FILES_TO_REMOVE[@]}"; do
    TARGET="$HOME_DIR/$file"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        BACKUP="$HOME_DIR/Existing.$file.bak"
        [ -e "$BACKUP" ] && rm -f "$BACKUP"
        mv "$TARGET" "$BACKUP"
        echo "[OK] Backed up $file to Existing.$file.bak"
        ((REMOVED++))
    else
        echo "[SKIP] $file not found"
    fi
done

echo ""

# STEP 2: Remove .gitconfig.local
echo "[STEP 2] Removing .gitconfig.local..."
echo "-----"

LOCAL_CONFIG="$HOME_DIR/.gitconfig.local"
if [ -f "$LOCAL_CONFIG" ]; then
    BACKUP="$HOME_DIR/Existing.gitconfig.local.bak"
    [ -e "$BACKUP" ] && rm -f "$BACKUP"
    mv "$LOCAL_CONFIG" "$BACKUP"
    echo "[OK] Backed up .gitconfig.local to Existing.gitconfig.local.bak"
    ((REMOVED++))
else
    echo "[SKIP] .gitconfig.local not found"
fi

echo ""

# STEP 3: Remove launchd agent
echo "[STEP 3] Removing launchd login agent..."
echo "-----"

PLIST_LABEL="com.gitconfig.update"
PLIST_PATH="$HOME_DIR/Library/LaunchAgents/$PLIST_LABEL.plist"

if [ -f "$PLIST_PATH" ]; then
    # Unload before removing
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

for file in "${FILES_TO_REMOVE[@]}"; do
    TARGET="$HOME_DIR/$file"
    if [ -e "$TARGET" ]; then
        echo "[FAIL] $file still exists!"
        ((ERRORS++))
    else
        echo "[OK] $file removed"
    fi
done

if [ -f "$LOCAL_CONFIG" ]; then
    echo "[FAIL] .gitconfig.local still exists!"
    ((ERRORS++))
else
    echo "[OK] .gitconfig.local removed"
fi

if [ -f "$PLIST_PATH" ]; then
    echo "[FAIL] launchd plist still exists!"
    ((ERRORS++))
else
    echo "[OK] launchd agent removed"
fi

if git --version > /dev/null 2>&1; then
    echo "[OK] Git still functional"
fi

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
