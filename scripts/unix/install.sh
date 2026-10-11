#!/bin/bash

# GitConfig Setup - macOS and Linux
# Orchestrates complete setup of the portable git configuration. One script
# for both platforms; the per-OS pieces (auto-sync scheduler, credential
# helper, signing helper paths) live in scripts/shared/platform.sh:
#   - macOS: launchd login agent, osxkeychain, Homebrew safe.directory
#   - Linux: daily cron job, gh / libsecret credential helper
#
# The old entry points, scripts/mac version/install.sh and
# scripts/linux version/install.sh, are thin wrappers that run this script
# with GITCONFIG_PLATFORM set, so their commands keep working.

set -e

# Preflight: git is required throughout (this whole tool configures git). A clear
# "install git" beats a cryptic mid-run failure. Python is checked later by
# install_python_deps, which degrades gracefully if it's missing.
if ! command -v git >/dev/null 2>&1; then
    if [ "$(uname -s)" = Darwin ]; then hint="brew install git"; else hint="sudo apt install git"; fi
    echo "[ERROR] git not found on PATH. Install git ($hint), then re-run." >&2
    exit 1
fi

FORCE=false
REINSTALL=false
NO_SCHEDULER=false
HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)       FORCE=true;        shift ;;
        --reinstall)      REINSTALL=true;    shift ;;
        # --no-cron and --no-launchd are the old per-OS spellings; all three
        # skip the auto-sync job on either platform.
        --no-scheduler|--no-cron|--no-launchd) NO_SCHEDULER=true; shift ;;
        -h|--help)        HELP=true;         shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << 'HELP'
GitConfig Setup - macOS and Linux

USAGE: scripts/unix/install.sh [OPTIONS]

OPTIONS:
    -f, --force       Overwrite existing files without prompting
    --reinstall       Tear down the previous install first (runs
                      cleanup-gitconfig.sh --force; files are backed up)
    --no-scheduler    Skip the auto-sync job (launchd agent on macOS, cron
                      job on Linux). --no-launchd and --no-cron are synonyms.
    -h, --help        Display this help message

DESCRIPTION:
    1. Generates ~/.gitconfig from the template
    2. Links .gitignore_global and gitconfig_helper.py into ~
    3. Generates machine-specific .gitconfig.local (signing key / op-ssh-sign
       and credential helper detection)
    4. Registers the auto-sync job (optional): a launchd agent that runs at
       each login on macOS, a daily 9 AM cron job on Linux
    5. Verifies the complete setup

    Files that would be replaced are first kept as timestamped backups
    (<file>.bak.YYYYMMDD-HHMMSS; newest 5 per file, set GITCONFIG_BACKUP_KEEP
    to change, 0 keeps all). The first backup also keeps your original as
    <file>.pre-gitconfig, which is never pruned. Put your own git settings in
    ~/.gitconfig.local: ~/.gitconfig is regenerated from the template, so
    anything added to it with `git config --global` is dropped (and backed up)
    at the next sync.

REQUIREMENTS:
    - macOS 12+ or Linux
    - bash (the stock macOS /bin/bash 3.2 works)
    - git
    - Python 3 + rich library; textual is optional for the interactive
      'git alias' browser
    - Linux: cron (optional, for auto-sync)
    - 1Password (optional, for SSH commit signing via op-ssh-sign)
HELP
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-gitconfig.sh"
LOCAL_CONFIG_SCRIPT="$SCRIPT_DIR/initialize-local-config.sh"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"
# shellcheck source=../shared/platform.sh
source "$REPO_ROOT/scripts/shared/platform.sh"

# Guard: refuse to set up another platform than this host before any step
# writes to $HOME (only possible through the per-OS wrappers, which request a
# platform). The guard inside initialize-local-config.sh (STEP 3) fires too
# late: STEP 0 (--reinstall) moves ~/.gitconfig.local aside and STEPs 1-2
# rewrite ~/.gitconfig and the links, so the wrong installer would change the
# machine and then abort mid-install (issue #181). Fail first instead.
# Tests set GITCONFIG_ALLOW_CROSS_OS=1 to run in a sandbox anywhere.
TARGET_OS="$(resolve_target_os installer install.sh)" || exit 1
# The child scripts (cleanup, local config) act for the same platform.
export GITCONFIG_PLATFORM="$TARGET_OS"
SCHEDULER_NAME="$(scheduler_name "$TARGET_OS")"

echo "GitConfig Setup ($(os_display_name "$TARGET_OS"))"
echo "====================================="
echo "Repository: $REPO_ROOT"
echo "Home Directory: $HOME_DIR"
echo ""

# STEP 0: Tear down the previous installation, only when asked (--reinstall).
# A plain re-run converges in place: existing files that differ are backed up
# with a timestamp, and links that already point into the repo are left alone.
if [ "$REINSTALL" = true ]; then
    echo "[STEP 0] Cleaning up previous installation (--reinstall)..."
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
fi

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
    create_symlink "$REPO_ROOT/$file" "$HOME_DIR/$file" "$FORCE" "$REPO_ROOT" || LINK_ERRORS=$((LINK_ERRORS+1))
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

# STEP 5: Register the auto-sync job (launchd login agent on macOS, daily cron
# job on Linux). It runs scripts/shared/update-gitconfig.sh with this clone's
# path, so the updater syncs THIS clone wherever it lives.
if [ "$NO_SCHEDULER" = false ]; then
    if [ "$TARGET_OS" = macos ]; then
        echo "[STEP 5] Setting up launchd login agent..."
    else
        echo "[STEP 5] Setting up cron job..."
    fi
    echo "-----"
    # Never fatal: a skipped or failed job only means syncing by hand.
    scheduler_install "$TARGET_OS" "$REPO_ROOT" "$FORCE" || true
    echo ""
fi

# STEP 6: Install Python dependencies (rich required; textual optional, for the
# interactive 'git alias' browser). Declared in pyproject.toml and installed by
# the shared install_python_deps routine (single source of truth across the
# install and the auto-update).
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

[ -f "$HOME_DIR/.gitconfig" ]          && echo "[OK] .gitconfig verified"          || { echo "[FAIL] .gitconfig missing";          ERRORS=$((ERRORS+1)); }
[ -e "$HOME_DIR/.gitignore_global" ]   && echo "[OK] .gitignore_global verified"   || { echo "[FAIL] .gitignore_global missing";   ERRORS=$((ERRORS+1)); }
[ -e "$HOME_DIR/gitconfig_helper.py" ] && echo "[OK] gitconfig_helper.py verified" || { echo "[FAIL] gitconfig_helper.py missing"; ERRORS=$((ERRORS+1)); }
[ -f "$HOME_DIR/.gitconfig.local" ]    && echo "[OK] .gitconfig.local verified"    || { echo "[FAIL] .gitconfig.local missing";    ERRORS=$((ERRORS+1)); }

# The auto-sync job is optional (no cron, or a declined replace prompt), so a
# missing one is a warning, not an error.
if [ "$NO_SCHEDULER" = false ]; then
    if scheduler_status "$TARGET_OS"; then
        echo "[OK] $SCHEDULER_NAME verified"
    else
        echo "[WARN] $SCHEDULER_NAME not found (setup may have been skipped)"
    fi
fi

python3 -c "import rich" &>/dev/null && echo "[OK] Python 'rich' importable" || echo "[WARN] Python 'rich' not importable"
python3 -c "import textual" &>/dev/null && echo "[OK] Python 'textual' importable" || echo "[WARN] Python 'textual' not importable ('git alias' uses the static table)"

git config --list > /dev/null 2>&1 && echo "[OK] Git configuration accessible" || echo "[WARN] Could not verify git configuration"

echo ""
echo "Setup Complete!"
echo "====================================="
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "Verify your git aliases:"
    echo "  git alias"
else
    echo "Setup completed with $ERRORS error(s). Review the output above."
fi
echo ""
