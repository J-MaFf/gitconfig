#!/bin/bash

# GitConfig Setup Wrapper - Linux/Unix Version
# Orchestrates complete setup of portable git configuration
# Works on Linux, macOS, and other Unix-like systems

set -e

FORCE=false
NO_CRON=false
HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        --no-cron)
            NO_CRON=true
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
GitConfig Setup Wrapper - Linux/Unix Version

USAGE: ./setup-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Overwrite existing files without prompting
    --no-cron       Skip cron job creation
    -h, --help      Display this help message

DESCRIPTION:
    1. Creates symlinks for .gitconfig and gitconfig_helper.py
    2. Generates machine-specific .gitconfig.local
    3. Sets up cron job for auto-sync (optional)
    4. Verifies the complete setup

REQUIREMENTS:
    - bash 4.0+
    - Standard Unix utilities (ln, cp, git)
    - cron (optional, for auto-sync feature)
EOF
    exit 0
fi

# Get paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOME_DIR="$HOME"
SCRIPTS_DIR="$REPO_ROOT/scripts"
CLEANUP_SCRIPT="$SCRIPTS_DIR/linux version/cleanup-gitconfig.sh"

echo "GitConfig Setup"
echo "====================================="
echo "Repository: $REPO_ROOT"
echo "Home Directory: $HOME_DIR"
echo ""

# STEP 0: Clean up any existing installation first
echo "[STEP 0] Cleaning up previous installation..."
echo "-----"
if [ -f "$CLEANUP_SCRIPT" ]; then
    if $CLEANUP_SCRIPT --force 2>/dev/null; then
        echo "[OK] Previous installation cleaned up"
    else
        echo "[WARN] No previous installation found or cleanup failed (this is OK)"
    fi
else
    echo "[WARN] Cleanup script not found, skipping"
fi
echo ""

# Files to symlink
declare -a FILES_TO_LINK=(
    ".gitignore_global"
    "gitconfig_helper.py"
)

# STEP 1: Generate .gitconfig from template
echo "[STEP 1] Generating .gitconfig from template..."
echo "-----"

GENERATE_SCRIPT="$SCRIPTS_DIR/linux version/initialize-gitconfig.sh"
if [ -f "$GENERATE_SCRIPT" ]; then
    if [ "$FORCE" = true ]; then
        if bash "$GENERATE_SCRIPT" --force; then
            echo "[OK] Generated .gitconfig"
        else
            echo "[FAIL] Could not generate .gitconfig"
        fi
    else
        if bash "$GENERATE_SCRIPT"; then
            echo "[OK] Generated .gitconfig"
        else
            echo "[FAIL] Could not generate .gitconfig"
        fi
    fi
else
    echo "[ERROR] Generator script not found: $GENERATE_SCRIPT"
fi
echo ""

# STEP 2: Create Symlinks
echo "[STEP 2] Creating symlinks..."
echo "-----"

LINK_ERRORS=0
for file in "${FILES_TO_LINK[@]}"; do
    SOURCE_FILE="$REPO_ROOT/$file"
    LINK_PATH="$HOME_DIR/$file"

    if [ ! -f "$SOURCE_FILE" ]; then
        echo "[ERROR] Source not found: $SOURCE_FILE"
        ((LINK_ERRORS++))
        continue
    fi

    if [ -e "$LINK_PATH" ]; then
        if [ "$FORCE" = false ]; then
            read -p "$file exists. Overwrite? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: $file"
                continue
            fi
        fi

        BACKUP_NAME="Existing.$file.bak"
        BACKUP_PATH="$HOME_DIR/$BACKUP_NAME"
        if [ -e "$BACKUP_PATH" ]; then
            rm -f "$BACKUP_PATH"
        fi
        mv "$LINK_PATH" "$BACKUP_PATH"
        echo "Backed up existing $file to $BACKUP_NAME"
    fi

    if ln -s "$SOURCE_FILE" "$LINK_PATH" 2>/dev/null; then
        echo "[OK] Linked $file"
    else
        echo "[FAIL] Could not create symlink for $file"
        ((LINK_ERRORS++))
    fi
done
echo ""

# STEP 3: Generate Local Config
echo "[STEP 3] Generating machine-specific configuration..."
echo "-----"

LOCAL_CONFIG_SCRIPT="$SCRIPTS_DIR/linux version/initialize-local-config.sh"
if [ -f "$LOCAL_CONFIG_SCRIPT" ]; then
    if [ "$FORCE" = true ]; then
        bash "$LOCAL_CONFIG_SCRIPT" --force
    else
        bash "$LOCAL_CONFIG_SCRIPT"
    fi
else
    echo "[ERROR] Local config script not found: $LOCAL_CONFIG_SCRIPT"
fi
echo ""

# STEP 4: Configure Global Gitignore
echo "[STEP 4] Configuring global gitignore..."
echo "-----"

GITIGNORE_GLOBAL_PATH="$HOME_DIR/.gitignore_global"
if [ -e "$GITIGNORE_GLOBAL_PATH" ]; then
    if git config --global core.excludesfile "$GITIGNORE_GLOBAL_PATH" 2>/dev/null; then
        echo "[OK] Configured global excludesfile"
    else
        echo "[FAIL] Could not configure global excludesfile"
    fi
else
    echo "[WARN] .gitignore_global symlink not found"
fi
echo ""

# STEP 5: Set up Cron Job
if [ "$NO_CRON" = false ]; then
    echo "[STEP 5] Setting up cron job..."
    echo "-----"

    CRON_SCRIPT="$SCRIPTS_DIR/linux version/update-gitconfig.sh"

    if [ ! -f "$CRON_SCRIPT" ]; then
        echo "[WARN] update-gitconfig.sh not found"
    else
        CRON_ENTRY="0 9 * * * bash \"$CRON_SCRIPT\" >> /tmp/gitconfig-update.log 2>&1"
        CRON_JOB_DESC="GitConfig daily update at 9 AM"

        # Check if cron job already exists
        if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; then
            if [ "$FORCE" = false ]; then
                read -p "Cron job already exists. Replace? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Skipped: Cron job"
                    echo ""
                    return 0
                fi
            fi
            # Remove old cron entry
            crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab - 2>/dev/null || true
        fi

        # Add new cron entry
        (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab - 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "[OK] Created cron job for daily updates at 9 AM"
        else
            echo "[WARN] Could not create cron job (cron may not be available)"
        fi
    fi
    echo ""
fi

# STEP 6: Verify Setup
echo "[STEP 6] Verifying setup..."
echo "-----"

# Verify generated .gitconfig
GITCONFIG_PATH="$HOME_DIR/.gitconfig"
if [ -f "$GITCONFIG_PATH" ]; then
    echo "[OK] .gitconfig verified"
else
    echo "[FAIL] .gitconfig missing"
fi

# Verify symlinks
for file in "${FILES_TO_LINK[@]}"; do
    LINK_PATH="$HOME_DIR/$file"
    if [ -e "$LINK_PATH" ]; then
        echo "[OK] $file verified"
    else
        echo "[FAIL] $file missing"
    fi
done

# Verify local config
LOCAL_CONFIG_PATH="$HOME_DIR/.gitconfig.local"
if [ -f "$LOCAL_CONFIG_PATH" ]; then
    echo "[OK] .gitconfig.local verified"
else
    echo "[FAIL] .gitconfig.local missing"
fi

# Test git configuration
if git config --list > /dev/null 2>&1; then
    echo "[OK] Git configuration accessible"
else
    echo "[WARN] Could not verify git configuration"
fi

echo ""
echo "Setup Complete!"
echo "====================================="
echo ""
