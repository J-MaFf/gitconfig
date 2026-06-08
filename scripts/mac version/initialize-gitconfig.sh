#!/bin/bash

# Initialize Git Configuration - macOS Version
# Generates ~/.gitconfig from .gitconfig.template with machine-specific values.

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
Initialize Git Configuration - macOS Version

USAGE:
    ./initialize-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Overwrite existing .gitconfig without prompting
    -h, --help      Display this help message

DESCRIPTION:
    Generates ~/.gitconfig from .gitconfig.template with machine-specific values.

TEMPLATE PLACEHOLDERS:
    {{REPO_PATH}}   - Replaced with repository absolute path
    {{HOME_DIR}}    - Replaced with user home directory path
EOF
    exit 0
fi

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

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "[ERROR] Template not found: $TEMPLATE_PATH"
    exit 1
fi

if [ -f "$OUTPUT_PATH" ] && [ "$FORCE" = false ]; then
    echo ".gitconfig already exists at: $OUTPUT_PATH"
    read -p "Overwrite? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

if [ -f "$OUTPUT_PATH" ]; then
    cp "$OUTPUT_PATH" "$OUTPUT_PATH.bak"
    echo "[INFO] Backed up existing .gitconfig to .gitconfig.bak"
fi

GENERATED_CONTENT=$(cat "$TEMPLATE_PATH")
GENERATED_CONTENT="${GENERATED_CONTENT//\{\{REPO_PATH\}\}/$REPO_ROOT}"
GENERATED_CONTENT="${GENERATED_CONTENT//\{\{HOME_DIR\}\}/$HOME_DIR}"

echo "$GENERATED_CONTENT" > "$OUTPUT_PATH"
echo "[OK] Generated .gitconfig"
echo ""

if git config --file "$OUTPUT_PATH" --list > /dev/null 2>&1; then
    echo "[OK] Git configuration verified!"
else
    echo "[WARN] Git may have issues reading the configuration"
fi

echo ""
echo "Configuration generated successfully!"
echo "====================================="
echo ""
echo "Generated values:"
echo "  Repository Path: $REPO_ROOT"
echo "  Home Directory: $HOME_DIR"
echo ""
echo "To customize, edit the template ($TEMPLATE_PATH) and re-run,"
echo "or add overrides to ~/.gitconfig.local"
echo ""
