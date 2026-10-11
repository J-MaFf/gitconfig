#!/bin/bash
# Shared initialize-gitconfig script for mac and linux.
# Generates ~/.gitconfig from .gitconfig.template.

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
Initialize Git Configuration

USAGE:
    ./initialize-gitconfig.sh [OPTIONS]

OPTIONS:
    -f, --force     Overwrite existing .gitconfig without prompting
    -h, --help      Display this help message

DESCRIPTION:
    Generates ~/.gitconfig from .gitconfig.template with machine-specific values.

EXIT STATUS:
    0 written (or already up to date), 1 error, 2 not overwritten because the
    prompt was declined or had no input (use --force when unattended)

TEMPLATE PLACEHOLDERS:
    {{REPO_PATH}}   - Replaced with repository absolute path
    {{HOME_DIR}}    - Replaced with user home directory path
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=functions.sh
source "$SCRIPT_DIR/functions.sh"

generate_gitconfig "$REPO_ROOT" "$HOME" "$FORCE"
