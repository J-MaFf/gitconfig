#!/bin/bash

# Initialize Git Configuration - Linux/Unix Version
# This script generates ~/.gitconfig from .gitconfig.template
# Usage: ./initialize-gitconfig.sh [OPTIONS]

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
Initialize Git Configuration - Linux/Unix Version

USAGE:
    ./initialize-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Overwrite existing .gitconfig without prompting
    -h, --help      Display this help message

DESCRIPTION:
    Generates ~/.gitconfig from .gitconfig.template with machine-specific values.
    This allows the git configuration to be portable across different machines
    while maintaining version control of the template.

TEMPLATE PLACEHOLDERS:
    {{REPO_PATH}}   - Replaced with repository absolute path
    {{HOME_DIR}}    - Replaced with user home directory path

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    ./initialize-gitconfig.sh

    # Force mode (overwrites without prompting)
    ./initialize-gitconfig.sh --force
EOF
    exit 0
fi

# Get paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
TEMPLATE_PATH="$REPO_ROOT/.gitconfig.template"
OUTPUT_PATH="$HOME_DIR/.gitconfig"

echo "Git Configuration Generator"
echo "====================================="
echo "Repository: $REPO_ROOT"
echo "Home Directory: $HOME_DIR"
echo "Template: $TEMPLATE_PATH"
echo "Output: $OUTPUT_PATH"
echo ""

# Check if template exists
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "[ERROR] Template not found: $TEMPLATE_PATH"
    exit 1
fi

# Check if .gitconfig already exists
if [ -f "$OUTPUT_PATH" ] && [ "$FORCE" = false ]; then
    echo ".gitconfig already exists at: $OUTPUT_PATH"
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Backup existing file if it exists
if [ -f "$OUTPUT_PATH" ]; then
    BACKUP_PATH="$OUTPUT_PATH.bak"
    cp "$OUTPUT_PATH" "$BACKUP_PATH"
    echo "[INFO] Backed up existing .gitconfig to .gitconfig.bak"
fi

# Read template and replace placeholders
GENERATED_CONTENT=$(cat "$TEMPLATE_PATH")
GENERATED_CONTENT="${GENERATED_CONTENT//\{\{REPO_PATH\}\}/$REPO_ROOT}"
GENERATED_CONTENT="${GENERATED_CONTENT//\{\{HOME_DIR\}\}/$HOME_DIR}"

# Write generated config
echo "$GENERATED_CONTENT" > "$OUTPUT_PATH"
echo "[OK] Generated .gitconfig"
echo ""

# Verify git can read the config
echo "Verifying git configuration..."
if git config --file "$OUTPUT_PATH" --list > /dev/null 2>&1; then
    echo "[OK] Git configuration verified!"
else
    echo "[WARN] Git may have issues reading the configuration"
    echo "  Run: git config --list to diagnose"
fi

echo ""
echo "Configuration generated successfully!"
echo "====================================="
echo ""
echo "Generated values:"
echo "  Repository Path: $REPO_ROOT"
echo "  Home Directory: $HOME_DIR"
echo ""
echo "To customize, either:"
echo "  1. Edit the template: $TEMPLATE_PATH"
echo "  2. Re-run this script to regenerate"
echo "  OR"
echo "  3. Add overrides to ~/.gitconfig.local"
echo ""
