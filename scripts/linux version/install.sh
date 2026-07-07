#!/bin/bash

# GitConfig Setup Wrapper - Linux/Unix Version
# Orchestrates complete setup of portable git configuration.
#
# Key Linux/Unix differences vs macOS version:
#   - Uses cron instead of launchd for login sync

set -e

# Preflight: git is required throughout (this whole tool configures git). A clear
# "install git" beats a cryptic mid-run failure. Python is checked later by
# install_python_deps, which degrades gracefully if it's missing.
command -v git >/dev/null 2>&1 || { echo "[ERROR] git not found on PATH. Install git (sudo apt install git), then re-run." >&2; exit 1; }

FORCE=false
NO_CRON=false
HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)  FORCE=true;   shift ;;
        --no-cron)   NO_CRON=true; shift ;;
        -h|--help)   HELP=true;    shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << 'EOF'
GitConfig Setup Wrapper - Linux/Unix Version

USAGE: ./install.sh [OPTIONS]

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

# Guard: refuse to run the Linux installer on macOS BEFORE STEP 0's destructive
# cleanup. cleanup-gitconfig.sh --force moves an existing correct
# ~/.gitconfig.local aside, and the guard inside initialize-local-config.sh
# (STEP 3) only fires afterwards — so running the wrong installer would displace
# the local config and then abort mid-install (issue #181). Fail first instead.
# Tests set GITCONFIG_ALLOW_CROSS_OS=1 to run in a sandbox anywhere.
if [ "$(uname -s)" = "Darwin" ] && [ "${GITCONFIG_ALLOW_CROSS_OS:-0}" != "1" ]; then
    echo "[ERROR] This is the Linux installer but this host is macOS." >&2
    echo "        Use 'scripts/mac version/install.sh' instead," >&2
    echo "        or set GITCONFIG_ALLOW_CROSS_OS=1 to override (tests/sandboxes)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-gitconfig.sh"
LOCAL_CONFIG_SCRIPT="$SCRIPT_DIR/initialize-local-config.sh"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"

echo "GitConfig Setup"
echo "====================================="
echo "Repository: $REPO_ROOT"
echo "Home Directory: $HOME_DIR"
echo ""

# STEP 0: Clean up previous installation
echo "[STEP 0] Cleaning up previous installation..."
echo "-----"
if [ -f "$CLEANUP_SCRIPT" ]; then
    if bash "$CLEANUP_SCRIPT" --force 2>/dev/null; then
        echo "[OK] Previous installation cleaned up"
    else
        echo "[WARN] No previous installation found or cleanup failed (this is OK)"
    fi
else
    echo "[WARN] Cleanup script not found, skipping"
fi
echo ""

# STEP 1: Generate .gitconfig from template
echo "[STEP 1] Generating .gitconfig from template..."
echo "-----"
if [ "$FORCE" = true ]; then
    generate_gitconfig "$REPO_ROOT" "$HOME_DIR" "true" && echo "[OK] Generated .gitconfig" || echo "[FAIL] Could not generate .gitconfig"
else
    generate_gitconfig "$REPO_ROOT" "$HOME_DIR" "false" && echo "[OK] Generated .gitconfig" || echo "[FAIL] Could not generate .gitconfig"
fi
echo ""

# STEP 2: Create symlinks
echo "[STEP 2] Creating symlinks..."
echo "-----"
LINK_ERRORS=0
for file in ".gitignore_global" "gitconfig_helper.py"; do
    create_symlink "$REPO_ROOT/$file" "$HOME_DIR/$file" "$FORCE" || ((LINK_ERRORS++))
done
echo ""

# STEP 3: Generate local config
echo "[STEP 3] Generating machine-specific configuration..."
echo "-----"
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

# STEP 4: Configure global gitignore
echo "[STEP 4] Configuring global gitignore..."
echo "-----"
configure_global_gitignore "$HOME_DIR"
echo ""

# STEP 5: Set up cron job
if [ "$NO_CRON" = false ]; then
    echo "[STEP 5] Setting up cron job..."
    echo "-----"

    CRON_SCRIPT="$SCRIPT_DIR/update-gitconfig.sh"

    if [ ! -f "$CRON_SCRIPT" ]; then
        echo "[WARN] update-gitconfig.sh not found"
    else
        CRON_ENTRY="0 9 * * * bash \"$CRON_SCRIPT\" >> /tmp/gitconfig-update.log 2>&1"

        if crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"; then
            if [ "$FORCE" = false ]; then
                read -p "Cron job already exists. Replace? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Skipped: Cron job"
                    echo ""
                    NO_CRON=true
                fi
            fi
            if [ "$NO_CRON" = false ]; then
                crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab - 2>/dev/null || true
            fi
        fi

        if [ "$NO_CRON" = false ]; then
            (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab - 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "[OK] Created cron job for daily updates at 9 AM"
            else
                echo "[WARN] Could not create cron job (cron may not be available)"
            fi
        fi
    fi
    echo ""
fi

# STEP 6: Install Python dependencies (rich required; textual optional, for the
# interactive 'git alias' browser). Declared in pyproject.toml and installed by
# the shared install_python_deps routine (single source of truth across mac/linux
# install + the login auto-update).
echo "[STEP 6] Installing Python dependencies..."
echo "-----"
install_python_deps "$REPO_ROOT"
echo ""

# STEP 6b: Enable the interactive git-alias browser keybinding (Ctrl-G)
echo "[STEP 6b] Enabling git-alias browser keybinding..."
echo "-----"
enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
echo ""

# STEP 7: Verify setup
echo "[STEP 7] Verifying setup..."
echo "-----"

ERRORS=0

[ -f "$HOME_DIR/.gitconfig" ]          && echo "[OK] .gitconfig verified"          || { echo "[FAIL] .gitconfig missing";          ((ERRORS++)); }
[ -e "$HOME_DIR/.gitignore_global" ]   && echo "[OK] .gitignore_global verified"   || { echo "[FAIL] .gitignore_global missing";   ((ERRORS++)); }
[ -e "$HOME_DIR/gitconfig_helper.py" ] && echo "[OK] gitconfig_helper.py verified" || { echo "[FAIL] gitconfig_helper.py missing"; ((ERRORS++)); }
[ -f "$HOME_DIR/.gitconfig.local" ]    && echo "[OK] .gitconfig.local verified"    || { echo "[FAIL] .gitconfig.local missing";    ((ERRORS++)); }

git config --list > /dev/null 2>&1 && echo "[OK] Git configuration accessible" || echo "[WARN] Could not verify git configuration"
python3 -c "import rich" &>/dev/null && echo "[OK] Python 'rich' importable" || echo "[WARN] Python 'rich' not importable"
python3 -c "import textual" &>/dev/null && echo "[OK] Python 'textual' importable" || echo "[WARN] Python 'textual' not importable ('git alias' uses the static table)"

echo ""
echo "Setup Complete!"
echo "====================================="
echo ""
