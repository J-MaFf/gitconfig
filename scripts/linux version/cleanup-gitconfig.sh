#!/bin/bash

# GitConfig Cleanup Script - Linux/Unix Version
# Removes all gitconfig-related symlinks, config files, and cron jobs
# Useful for testing fresh setup

FORCE=false
HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
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
    1. Backs up and removes .gitconfig (generated file)
    2. Removes symlinks (.gitignore_global and gitconfig_helper.py)
    3. Removes .gitconfig.local
    4. Removes cron job (if it exists)
    5. Backs up all removed files for recovery
EOF
    exit 0
fi

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

HOME_DIR="$HOME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
REMOVED=0

# STEP 1: Remove Symlinks
echo "[STEP 1] Removing symlinks..."
echo "-----"

FILES_TO_REMOVE=(".gitconfig" ".gitignore_global" "gitconfig_helper.py")

for file in "${FILES_TO_REMOVE[@]}"; do
    PATH_TO_REMOVE="$HOME_DIR/$file"
    if [ -e "$PATH_TO_REMOVE" ]; then
        BACKUP_NAME="Existing.$file.bak"
        BACKUP_PATH="$HOME_DIR/$BACKUP_NAME"
        if [ -e "$BACKUP_PATH" ]; then
            rm -f "$BACKUP_PATH"
        fi
        mv "$PATH_TO_REMOVE" "$BACKUP_PATH"
        echo "[OK] Backed up $file to $BACKUP_NAME"
        ((REMOVED++))
    else
        echo "[SKIP] $file not found"
    fi
done

echo ""

# STEP 2: Remove .gitconfig.local
echo "[STEP 2] Removing .gitconfig.local..."
echo "-----"

LOCAL_CONFIG_PATH="$HOME_DIR/.gitconfig.local"
if [ -f "$LOCAL_CONFIG_PATH" ]; then
    BACKUP_NAME="Existing.gitconfig.local.bak"
    BACKUP_PATH="$HOME_DIR/$BACKUP_NAME"
    if [ -e "$BACKUP_PATH" ]; then
        rm -f "$BACKUP_PATH"
    fi
    mv "$LOCAL_CONFIG_PATH" "$BACKUP_PATH"
    echo "[OK] Backed up .gitconfig.local to $BACKUP_NAME"
    ((REMOVED++))
else
    echo "[SKIP] .gitconfig.local not found"
fi

echo ""

# STEP 3: Remove Cron Job
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

# STEP 4: Verify Cleanup Success
echo "[STEP 4] Verifying cleanup..."
echo "-----"

VERIFY_ERRORS=0

# Check symlinks were removed
for file in "${FILES_TO_REMOVE[@]}"; do
    PATH_TO_CHECK="$HOME_DIR/$file"
    if [ -e "$PATH_TO_CHECK" ]; then
        echo "[FAIL] $file still exists!"
        ((VERIFY_ERRORS++))
    else
        echo "[OK] $file removed"
    fi
done

# Check .gitconfig.local was removed
if [ -f "$LOCAL_CONFIG_PATH" ]; then
    echo "[FAIL] .gitconfig.local still exists!"
    ((VERIFY_ERRORS++))
else
    echo "[OK] .gitconfig.local removed"
fi

# Check cron job was removed
if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; then
    echo "[FAIL] Cron job still exists!"
    ((VERIFY_ERRORS++))
else
    echo "[OK] Cron job removed"
fi

# Check git still works
if git --version > /dev/null 2>&1; then
    echo "[OK] Git still functional"
else
    echo "[WARN] Git may be unavailable"
fi

echo ""

# STEP 5: Summary
echo "[SUMMARY]"
echo "====================================="
echo ""

if [ $VERIFY_ERRORS -eq 0 ]; then
    echo "Cleanup SUCCESSFUL!"
    echo "All gitconfig-related files and cron jobs removed."
    echo ""
    echo "Ready to test fresh setup:"
    echo "  bash $SCRIPT_DIR/setup-gitconfig.sh --force"
else
    echo "Cleanup INCOMPLETE - $VERIFY_ERRORS items still present"
fi
echo ""
