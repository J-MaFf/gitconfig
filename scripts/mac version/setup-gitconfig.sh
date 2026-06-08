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

USAGE: ./setup-gitconfig.sh [OPTIONS]

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
    - Python 3 + rich library  (brew install python && pip3 install rich)
    - 1Password CLI (optional, for SSH commit signing): brew install 1password-cli
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOME_DIR="$HOME"
SCRIPTS_MAC_DIR="$SCRIPT_DIR"
CLEANUP_SCRIPT="$SCRIPTS_MAC_DIR/cleanup-gitconfig.sh"

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

# Files to symlink
declare -a FILES_TO_LINK=(".gitignore_global" "gitconfig_helper.py")

# STEP 1: Generate .gitconfig from template
echo "[STEP 1] Generating .gitconfig from template..."
echo "-----"

GENERATE_SCRIPT="$SCRIPTS_MAC_DIR/initialize-gitconfig.sh"
if [ -f "$GENERATE_SCRIPT" ]; then
    if [ "$FORCE" = true ]; then
        bash "$GENERATE_SCRIPT" --force && echo "[OK] Generated .gitconfig" || echo "[FAIL] Could not generate .gitconfig"
    else
        bash "$GENERATE_SCRIPT" && echo "[OK] Generated .gitconfig" || echo "[FAIL] Could not generate .gitconfig"
    fi
else
    echo "[ERROR] Generator script not found: $GENERATE_SCRIPT"
fi
echo ""

# STEP 2: Create symlinks
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

    if [ -e "$LINK_PATH" ] || [ -L "$LINK_PATH" ]; then
        if [ "$FORCE" = false ]; then
            read -p "$file exists. Overwrite? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: $file"
                continue
            fi
        fi
        BACKUP="$HOME_DIR/Existing.$file.bak"
        [ -e "$BACKUP" ] && rm -f "$BACKUP"
        mv "$LINK_PATH" "$BACKUP"
        echo "Backed up existing $file to Existing.$file.bak"
    fi

    if ln -s "$SOURCE_FILE" "$LINK_PATH" 2>/dev/null; then
        echo "[OK] Linked $file"
    else
        echo "[FAIL] Could not create symlink for $file"
        ((LINK_ERRORS++))
    fi
done
echo ""

# STEP 3: Generate local config
echo "[STEP 3] Generating machine-specific configuration..."
echo "-----"

LOCAL_CONFIG_SCRIPT="$SCRIPTS_MAC_DIR/initialize-local-config.sh"
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

GITIGNORE_GLOBAL="$HOME_DIR/.gitignore_global"
if [ -e "$GITIGNORE_GLOBAL" ]; then
    if git config --global core.excludesfile "$GITIGNORE_GLOBAL" 2>/dev/null; then
        echo "[OK] Configured global excludesfile"
    else
        echo "[FAIL] Could not configure global excludesfile"
    fi
else
    echo "[WARN] .gitignore_global symlink not found"
fi
echo ""

# STEP 5: Register launchd agent for login-triggered auto-sync
if [ "$NO_LAUNCHD" = false ]; then
    echo "[STEP 5] Setting up launchd login agent..."
    echo "-----"

    UPDATE_SCRIPT="$SCRIPTS_MAC_DIR/update-gitconfig.sh"
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
                    # jump to step 6
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
            else
                echo "[WARN] Could not load launchd agent immediately."
                echo "       It will activate at next login."
                echo "       Plist written to: $PLIST_PATH"
            fi
        fi
    fi
    echo ""
fi

# STEP 6: Verify setup
echo "[STEP 6] Verifying setup..."
echo "-----"

ERRORS=0

GITCONFIG_PATH="$HOME_DIR/.gitconfig"
if [ -f "$GITCONFIG_PATH" ]; then
    echo "[OK] .gitconfig verified"
else
    echo "[FAIL] .gitconfig missing"
    ((ERRORS++))
fi

for file in "${FILES_TO_LINK[@]}"; do
    if [ -e "$HOME_DIR/$file" ]; then
        echo "[OK] $file verified"
    else
        echo "[FAIL] $file missing"
        ((ERRORS++))
    fi
done

LOCAL_CONFIG="$HOME_DIR/.gitconfig.local"
if [ -f "$LOCAL_CONFIG" ]; then
    echo "[OK] .gitconfig.local verified"
else
    echo "[FAIL] .gitconfig.local missing"
    ((ERRORS++))
fi

if [ "$NO_LAUNCHD" = false ]; then
    PLIST_PATH="$HOME_DIR/Library/LaunchAgents/com.gitconfig.update.plist"
    if [ -f "$PLIST_PATH" ]; then
        echo "[OK] launchd agent verified"
    else
        echo "[WARN] launchd agent plist not found (setup may have been skipped)"
    fi
fi

if git config --list > /dev/null 2>&1; then
    echo "[OK] Git configuration accessible"
else
    echo "[WARN] Could not verify git configuration"
fi

echo ""
echo "Setup Complete!"
echo "====================================="
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "Next step: install the Python dependency if not already done:"
    echo "  pip3 install rich"
    echo ""
    echo "Then verify your git aliases:"
    echo "  git alias"
else
    echo "Setup completed with $ERRORS error(s). Review the output above."
fi
echo ""
