#!/bin/bash

# Initialize Machine-Specific Git Configuration - Linux/Unix Version
# This script creates ~/.gitconfig.local with machine-specific paths and safe directories
# Usage: ./initialize-local-config.sh [OPTIONS]

set -e

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
Initialize Machine-Specific Git Configuration - Linux/Unix Version

USAGE:
    ./initialize-local-config.sh [OPTIONS]

OPTIONS:
    -f, --force     Overwrite existing .gitconfig.local without prompting
    -h, --help      Display this help message

DESCRIPTION:
    Creates ~/.gitconfig.local with machine-specific safe directories and paths.
    This file is included by the main .gitconfig and should NOT be version controlled.

SAFE DIRECTORIES:
    Add network locations and local paths that git should trust.
    Common examples:
    - Network mounts (e.g., /mnt/shared)
    - Local development directories
    - Work-specific repositories

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    ./initialize-local-config.sh

    # Force mode (overwrites without prompting)
    ./initialize-local-config.sh --force
EOF
    exit 0
fi

HOME_DIR="$HOME"
LOCAL_CONFIG_PATH="$HOME_DIR/.gitconfig.local"

echo "Git Local Configuration Setup"
echo "================================"
echo "Home Directory: $HOME_DIR"
echo "Local Config Path: $LOCAL_CONFIG_PATH"
echo ""

# Check if .gitconfig.local already exists
if [ -f "$LOCAL_CONFIG_PATH" ] && [ "$FORCE" = false ]; then
    echo ".gitconfig.local already exists."
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Create local config with Linux-friendly paths
CONFIG_CONTENT='# Machine-Specific Git Configuration
# This file is automatically included by .gitconfig and should NOT be committed

[core]
	# Use global gitignore file
	excludesfile = '"$HOME_DIR"'/.gitignore_global

[safe]
	# Add your local development directories here
	# Example: directory = /home/user/projects/work-repo
	# Example: directory = /mnt/shared/network-repo
'

echo "$CONFIG_CONTENT" > "$LOCAL_CONFIG_PATH"
echo "[OK] Created .gitconfig.local"
echo ""
echo "Local configuration created with default settings."
echo "You can add machine-specific safe directories by editing:"
echo "  $LOCAL_CONFIG_PATH"
echo ""
echo "To add a safe directory, add lines like:"
echo "  [safe]"
echo "      directory = /path/to/trusted/repo"
echo ""
