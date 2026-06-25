#!/bin/bash

# GitConfig Setup Wrapper - macOS Version
# Orchestrates complete setup of portable git configuration on macOS.
#
# Key macOS differences vs Linux version:
#   - Uses launchd (~/Library/LaunchAgents) instead of cron for login sync
#   - Auto-detects 1Password SSH signing helper (op-ssh-sign) for Homebrew paths

set -e

FORCE=false
NO_LAUNCHD=false
HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)       FORCE=true;      shift ;;
        --no-launchd)     NO_LAUNCHD=true; shift ;;
        -h|--help)        HELP=true;       shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << 'EOF'
GitConfig Setup Wrapper - macOS Version

USAGE: ./install.sh [OPTIONS]

OPTIONS:
    -f, --force       Overwrite existing files without prompting
    --no-launchd      Skip launchd login agent creation
    -h, --help        Display this help message

DESCRIPTION:
    1. Creates symlinks for .gitconfig and gitconfig_helper.py
    2. Generates machine-specific .gitconfig.local (with op-ssh-sign detection)
    3. Registers a launchd agent for auto-sync at login (optional)
    4. Verifies the complete setup

REQUIREMENTS:
    - macOS 12+ (Monterey or later recommended)
    - bash 4.0+  (use: brew install bash)
    - git
    - Python 3 + rich library  (brew install python && pip3 install rich); textual is optional for the interactive 'git alias' browser
    - 1Password CLI (optional, for SSH commit signing): brew install 1password-cli
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-gitconfig.sh"
LOCAL_CONFIG_SCRIPT="$SCRIPT_DIR/initialize-local-config.sh"

# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"

echo "GitConfig Setup (macOS)"
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

# STEP 5: Register launchd agent for login-triggered auto-sync
if [ "$NO_LAUNCHD" = false ]; then
    echo "[STEP 5] Setting up launchd login agent..."
    echo "-----"

    UPDATE_SCRIPT="$SCRIPT_DIR/update-gitconfig.sh"
    PLIST_LABEL="com.gitconfig.update"
    LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
    PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

    if [ ! -f "$UPDATE_SCRIPT" ]; then
        echo "[WARN] update-gitconfig.sh not found — skipping launchd setup"
    else
        mkdir -p "$LAUNCH_AGENTS_DIR"

        if [ -f "$PLIST_PATH" ]; then
            if [ "$FORCE" = false ]; then
                read -p "launchd agent already exists. Replace? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Skipped: launchd agent"
                    echo ""
                    SKIP_LAUNCHD=true
                fi
            fi
            if [ "${SKIP_LAUNCHD:-false}" = false ]; then
                launchctl unload "$PLIST_PATH" 2>/dev/null || true
                rm -f "$PLIST_PATH"
            fi
        fi

        if [ "${SKIP_LAUNCHD:-false}" = false ]; then
            cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$UPDATE_SCRIPT</string>
        <string>$REPO_ROOT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$REPO_ROOT/docs/update-gitconfig.log</string>
    <key>StandardErrorPath</key>
    <string>$REPO_ROOT/docs/update-gitconfig.log</string>
</dict>
</plist>
PLIST

            if launchctl load "$PLIST_PATH" 2>/dev/null; then
                echo "[OK] launchd agent registered: $PLIST_LABEL"
                echo "     Runs automatically at each login."
                echo ""
                echo "     NOTE: macOS may block the agent from accessing ~/Documents"
                echo "     until your terminal app has Full Disk Access."
                echo "     If auto-sync does not run, go to:"
                echo "       System Settings > Privacy & Security > Full Disk Access"
                echo "     enable your terminal app, then reload the agent with:"
                echo "       launchctl unload $PLIST_PATH && launchctl load $PLIST_PATH"
            else
                echo "[WARN] Could not load launchd agent immediately."
                echo "       It will activate at next login."
                echo "       Plist written to: $PLIST_PATH"
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

[ -f "$HOME_DIR/.gitconfig" ]       && echo "[OK] .gitconfig verified"       || { echo "[FAIL] .gitconfig missing";       ((ERRORS++)); }
[ -e "$HOME_DIR/.gitignore_global" ] && echo "[OK] .gitignore_global verified" || { echo "[FAIL] .gitignore_global missing"; ((ERRORS++)); }
[ -e "$HOME_DIR/gitconfig_helper.py" ] && echo "[OK] gitconfig_helper.py verified" || { echo "[FAIL] gitconfig_helper.py missing"; ((ERRORS++)); }
[ -f "$HOME_DIR/.gitconfig.local" ] && echo "[OK] .gitconfig.local verified"  || { echo "[FAIL] .gitconfig.local missing";  ((ERRORS++)); }

if [ "$NO_LAUNCHD" = false ]; then
    PLIST_PATH="$HOME_DIR/Library/LaunchAgents/com.gitconfig.update.plist"
    [ -f "$PLIST_PATH" ] && echo "[OK] launchd agent verified" || echo "[WARN] launchd agent plist not found (setup may have been skipped)"
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
