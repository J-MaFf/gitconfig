#!/bin/bash

# GitConfig Cleanup Script - Linux/Unix Version
# Removes all gitconfig-related symlinks, config files, and cron jobs.

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
GitConfig Cleanup Script - Linux/Unix Version

USAGE: ./cleanup-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Skip confirmation prompts
    -h, --help      Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Backs up and removes .gitconfig, .gitignore_global, gitconfig_helper.py
    2. Removes .gitconfig.local
    3. Removes cron job (if it exists)
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"

echo "GitConfig Cleanup"
echo "====================================="
echo ""

if [ "$FORCE" = false ]; then
    echo "WARNING: This will remove all gitconfig-related files and cron jobs."
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

REMOVED=0

# STEP 1: Remove symlinks and generated files
echo "[STEP 1] Removing symlinks..."
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

# STEP 3: Remove cron job (Linux-specific)
echo "[STEP 3] Removing cron job..."
echo "-----"

CRON_SCRIPT="$SCRIPT_DIR/update-gitconfig.sh"

if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; then
    crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab - 2>/dev/null
    echo "[OK] Removed cron job"
    ((REMOVED++))
else
    echo "[SKIP] Cron job not found"
fi
echo ""

# STEP 4: Verify
echo "[STEP 4] Verifying cleanup..."
echo "-----"

ERRORS=0
for file in ".gitconfig" ".gitignore_global" "gitconfig_helper.py" ".gitconfig.local"; do
    [ ! -e "$HOME_DIR/$file" ] && echo "[OK] $file removed" || { echo "[FAIL] $file still exists!"; ((ERRORS++)); }
done
crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT" && { echo "[FAIL] Cron job still exists!"; ((ERRORS++)); } || echo "[OK] Cron job removed"
git --version > /dev/null 2>&1 && echo "[OK] Git still functional" || echo "[WARN] Git may be unavailable"

echo ""
echo "[SUMMARY]"
echo "====================================="
if [ $ERRORS -eq 0 ]; then
    echo "Cleanup SUCCESSFUL!"
    echo ""
    echo "Ready to test fresh setup:"
    echo "  bash $SCRIPT_DIR/install.sh --force"
else
    echo "Cleanup INCOMPLETE - $ERRORS items still present"
fi
echo ""
