#!/bin/bash
# Platform layer for the unified macOS/Linux scripts in scripts/unix/.
#
# The per-OS differences live here and nowhere else:
#   - detect_os / resolve_target_os: which platform's behaviour to run, and the
#     wrong-platform guard (issues #179, #181)
#   - scheduler_install / scheduler_remove / scheduler_status: the login/daily
#     auto-sync job (launchd on macOS, cron on Linux)
#   - detect_credential_helper: the HTTPS credential helper (osxkeychain on
#     macOS; gh CLI, then libsecret, on Linux)
#   - detect_signing_key: the SSH commit-signing setup (on-disk key file,
#     1Password's op-ssh-sign, or a signing key git already has)
#
# Source after scripts/shared/functions.sh. Everything here runs under the
# stock macOS /bin/bash 3.2: no associative arrays, no ${var,,}, no declare -g.

# Tag on every cron line the installer writes, so cleanup can remove exactly
# its own lines. Cron hands the whole command to /bin/sh, which reads a
# trailing " # ..." as a comment, so the tag never reaches the updater.
GITCONFIG_CRON_MARKER="# gitconfig-autoupdate"
GITCONFIG_LAUNCHD_LABEL="com.gitconfig.update"

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------

# Print the platform this host is: "macos" for Darwin, "linux" for everything
# else (Linux, the BSDs, WSL), which all get the cron/gh/libsecret behaviour.
# Usage: detect_os
detect_os() {
    case "$(uname -s)" in
        Darwin) echo macos ;;
        *)      echo linux ;;
    esac
}

# Human name of a platform id, for messages.
# Usage: os_display_name macos|linux
os_display_name() {
    case "$1" in
        macos) echo macOS ;;
        linux) echo Linux ;;
        *)     echo "$1" ;;
    esac
}

# Print the platform a script should act for, without any guard: the one
# GITCONFIG_PLATFORM names (the legacy scripts/mac version and
# scripts/linux version wrappers set it), else this host's. Returns 1 for an
# unknown GITCONFIG_PLATFORM value.
# Usage: requested_os
requested_os() {
    case "${GITCONFIG_PLATFORM:-}" in
        "")          detect_os ;;
        macos|linux) echo "$GITCONFIG_PLATFORM" ;;
        *)
            echo "[ERROR] Unknown GITCONFIG_PLATFORM '$GITCONFIG_PLATFORM' (expected macos or linux)." >&2
            return 1
            ;;
    esac
}

# Like requested_os, but refuse a platform that isn't this host's: running the
# wrong platform's setup wrote osxkeychain into a Linux ~/.gitconfig.local
# (issue #179). GITCONFIG_ALLOW_CROSS_OS=1 lets tests run either platform's
# behaviour in a sandbox on any host. KIND ("installer" or "script") and
# SCRIPT_NAME only shape the error message.
# Usage: TARGET_OS="$(resolve_target_os KIND SCRIPT_NAME)" || exit 1
resolve_target_os() {
    local kind="$1" script_name="$2" host target host_name
    target="$(requested_os)" || return 1
    host="$(detect_os)"
    if [ "$target" = "$host" ] || [ "${GITCONFIG_ALLOW_CROSS_OS:-0}" = "1" ]; then
        echo "$target"
        return 0
    fi
    if [ "$host" = macos ]; then host_name=macOS; else host_name="$(uname -s)"; fi
    echo "[ERROR] This is the $(os_display_name "$target") $kind but this host is $host_name." >&2
    echo "        Use 'scripts/unix/$script_name' instead (it detects the OS)," >&2
    echo "        or set GITCONFIG_ALLOW_CROSS_OS=1 to override (tests/sandboxes)." >&2
    return 1
}

# ---------------------------------------------------------------------------
# Auto-sync scheduler
#
# Both backends run scripts/shared/update-gitconfig.sh with the repo path as
# its argument. Jobs made by older installs point at the per-OS
# "scripts/<os> version/update-gitconfig.sh" wrappers, which are kept, so those
# keep working until the next install replaces them.
# ---------------------------------------------------------------------------

# Short name of the scheduler job for messages ("launchd agent", "cron job").
# Usage: scheduler_name OS
scheduler_name() {
    case "$1" in
        macos) echo "launchd agent" ;;
        *)     echo "cron job" ;;
    esac
}

_launchd_plist_path() {
    echo "$HOME/Library/LaunchAgents/$GITCONFIG_LAUNCHD_LABEL.plist"
}

# The cron line this installer writes (daily at 9 AM). The /tmp log catches
# what the updater can't log itself: its own log lives inside the repo, so a
# wrong repo path can only be reported on stderr.
# Usage: cron_entry REPO_ROOT
cron_entry() {
    local repo_root="$1"
    printf '0 9 * * * bash "%s" "%s" >> /tmp/gitconfig-update.log 2>&1 %s\n' \
        "$repo_root/scripts/shared/update-gitconfig.sh" "$repo_root" "$GITCONFIG_CRON_MARKER"
}

# Succeed if a crontab line (on stdin) is ours: tagged with the marker, or an
# untagged line from an install that predates the marker (those all ran a
# .../update-gitconfig.sh). Prints the crontab minus our lines with -v.
# Usage: crontab -l | _cron_ours [-v]
_cron_ours() {
    grep -F "$1" -e "$GITCONFIG_CRON_MARKER" -e "update-gitconfig.sh"
}

_cron_has_entry() {
    crontab -l 2>/dev/null | _cron_ours -q
}

# Rewrite the crontab without our lines. Other users' entries are kept.
_cron_remove_entries() {
    crontab -l 2>/dev/null | _cron_ours -v | crontab - 2>/dev/null
}

# Register the auto-sync job. Prompts before replacing an existing job unless
# FORCE is true. Never fails the caller (safe under set -e): returns 0 when the
# job was written, 1 when it was skipped or could not be written.
# Usage: scheduler_install OS REPO_ROOT FORCE
scheduler_install() {
    case "$1" in
        macos) _launchd_install "$2" "$3" ;;
        *)     _cron_install "$2" "$3" ;;
    esac
}

# Remove the auto-sync job. Returns 0 if one was removed, 1 if there was none
# (or no crontab binary to ask).
# Usage: scheduler_remove OS
scheduler_remove() {
    case "$1" in
        macos) _launchd_remove ;;
        *)     _cron_remove ;;
    esac
}

# Succeed if the auto-sync job is registered.
# Usage: scheduler_status OS
scheduler_status() {
    case "$1" in
        macos) [ -f "$(_launchd_plist_path)" ] ;;
        *)     command -v crontab >/dev/null 2>&1 && _cron_has_entry ;;
    esac
}

_cron_install() {
    local repo_root="$1" force="$2" updater entry
    updater="$repo_root/scripts/shared/update-gitconfig.sh"

    # Without a crontab binary (common on WSL, containers, minimal
    # Fedora/Arch) the `... | crontab -` pipeline below fails; skip the step
    # instead of ending the install under set -e.
    if ! command -v crontab >/dev/null 2>&1; then
        echo "[WARN] crontab not found; skipping auto-sync job (install cron, then re-run)"
        echo "       To sync by hand: git selfupdate"
        return 1
    fi
    if [ ! -f "$updater" ]; then
        echo "[WARN] update-gitconfig.sh not found"
        return 1
    fi

    if _cron_has_entry; then
        if [ "$force" != true ]; then
            read -p "Cron job already exists. Replace? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: Cron job"
                return 1
            fi
        fi
        # Drops the old line too when it came from an install that predates
        # the marker, so the job is migrated rather than duplicated.
        _cron_remove_entries || true
    fi

    entry="$(cron_entry "$repo_root")"
    if (crontab -l 2>/dev/null || true; echo "$entry") | crontab - 2>/dev/null; then
        echo "[OK] Created cron job for daily updates at 9 AM"
        return 0
    fi
    echo "[WARN] Could not create cron job (cron may not be available)"
    return 1
}

_cron_remove() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo "[SKIP] crontab not found; no cron job to remove"
        return 1
    fi
    if ! _cron_has_entry; then
        echo "[SKIP] Cron job not found"
        return 1
    fi
    if _cron_remove_entries; then
        echo "[OK] Removed cron job"
        return 0
    fi
    echo "[WARN] Could not rewrite the crontab"
    return 1
}

_launchd_install() {
    local repo_root="$1" force="$2" updater plist_path launch_agents_dir launchd_path
    updater="$repo_root/scripts/shared/update-gitconfig.sh"
    plist_path="$(_launchd_plist_path)"
    launch_agents_dir="$(dirname "$plist_path")"
    # launchd starts agents with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which finds
    # Apple's stub git/python3 (or none) instead of Homebrew's, plus gh/op used
    # by credential and signing helpers. Put Homebrew first (Apple silicon,
    # then Intel).
    launchd_path="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    if [ ! -f "$updater" ]; then
        echo "[WARN] update-gitconfig.sh not found — skipping launchd setup"
        return 1
    fi

    mkdir -p "$launch_agents_dir"

    if [ -f "$plist_path" ]; then
        if [ "$force" != true ]; then
            read -p "launchd agent already exists. Replace? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: launchd agent"
                return 1
            fi
        fi
        launchctl unload "$plist_path" 2>/dev/null || true
        rm -f "$plist_path"
    fi

    cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$GITCONFIG_LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$updater</string>
        <string>$repo_root</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$launchd_path</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$repo_root/docs/update-gitconfig.log</string>
    <key>StandardErrorPath</key>
    <string>$repo_root/docs/update-gitconfig.log</string>
</dict>
</plist>
PLIST

    if launchctl load "$plist_path" 2>/dev/null; then
        echo "[OK] launchd agent registered: $GITCONFIG_LAUNCHD_LABEL"
        echo "     Runs automatically at each login."
        echo ""
        echo "     NOTE: macOS may block the agent from accessing ~/Documents"
        echo "     until your terminal app has Full Disk Access."
        echo "     If auto-sync does not run, go to:"
        echo "       System Settings > Privacy & Security > Full Disk Access"
        echo "     enable your terminal app, then reload the agent with:"
        echo "       launchctl unload $plist_path && launchctl load $plist_path"
    else
        echo "[WARN] Could not load launchd agent immediately."
        echo "       It will activate at next login."
        echo "       Plist written to: $plist_path"
    fi
    return 0
}

_launchd_remove() {
    local plist_path
    plist_path="$(_launchd_plist_path)"
    if [ ! -f "$plist_path" ]; then
        echo "[SKIP] launchd plist not found"
        return 1
    fi
    if launchctl unload "$plist_path" 2>/dev/null; then
        echo "[OK] Unloaded launchd agent"
    else
        echo "[WARN] Could not unload agent (may not be running)"
    fi
    rm -f "$plist_path"
    echo "[OK] Removed launchd plist: $plist_path"
    return 0
}

# ---------------------------------------------------------------------------
# HTTPS credential helper
# ---------------------------------------------------------------------------

# Pick the HTTPS credential helper for OS. Sets two globals:
#   CREDENTIAL_HELPER_KIND  osxkeychain | gh | libsecret | none
#   CREDENTIAL_HELPER_PATH  the gh or git-credential-libsecret binary (gh and
#                           libsecret only)
# macOS always uses the login keychain (osxkeychain): it answers the launchd
# sync without a prompt and without 1Password. Linux prefers the GitHub CLI
# (token from `gh auth login`), then libsecret, else none (issue #179).
# GITCONFIG_GH_BIN / GITCONFIG_LIBSECRET_BIN are test seams: set to a path to
# force that helper, set to the empty string to simulate "not installed".
# Usage: detect_credential_helper OS
# shellcheck disable=SC2034  # sets globals the caller reads
detect_credential_helper() {
    local os="$1" gh_path libsecret exec_dir
    CREDENTIAL_HELPER_KIND=none
    CREDENTIAL_HELPER_PATH=""

    if [ "$os" = macos ]; then
        CREDENTIAL_HELPER_KIND=osxkeychain
        CREDENTIAL_HELPER_PATH=osxkeychain
        return 0
    fi

    if [ -n "${GITCONFIG_GH_BIN+set}" ]; then
        gh_path="$GITCONFIG_GH_BIN"
    else
        gh_path="$(command -v gh 2>/dev/null || true)"
    fi
    if [ -n "$gh_path" ]; then
        CREDENTIAL_HELPER_KIND=gh
        CREDENTIAL_HELPER_PATH="$gh_path"
        return 0
    fi

    if [ -n "${GITCONFIG_LIBSECRET_BIN+set}" ]; then
        libsecret="$GITCONFIG_LIBSECRET_BIN"
    else
        libsecret="$(command -v git-credential-libsecret 2>/dev/null || true)"
        if [ -z "$libsecret" ]; then
            # Some distros ship the helper in git's exec path without a PATH entry.
            exec_dir="$(git --exec-path 2>/dev/null || true)"
            if [ -n "$exec_dir" ] && [ -x "$exec_dir/git-credential-libsecret" ]; then
                libsecret="$exec_dir/git-credential-libsecret"
            fi
        fi
    fi
    if [ -n "$libsecret" ]; then
        CREDENTIAL_HELPER_KIND=libsecret
        CREDENTIAL_HELPER_PATH="$libsecret"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# SSH commit signing
# ---------------------------------------------------------------------------

# Print the op-ssh-sign (1Password SSH signing helper) paths to probe on OS.
# Usage: op_ssh_sign_candidates OS
op_ssh_sign_candidates() {
    case "$1" in
        macos)
            echo /opt/homebrew/bin/op-ssh-sign                         # Homebrew, Apple silicon
            echo /usr/local/bin/op-ssh-sign                            # Homebrew, Intel
            echo /Applications/1Password.app/Contents/MacOS/op-ssh-sign # 1Password app bundle
            ;;
        *)
            echo /opt/1Password/op-ssh-sign                            # 1Password .deb/.rpm/tarball
            ;;
    esac
}

# Decide how commits get signed. Sets globals:
#   SIGNING_MODE          file | op | existing | none
#   SIGNING_KEY_FILE      the on-disk private key (file mode)
#   SIGNING_PROGRAM       gpg.ssh.program: the no-agent wrapper (file mode,
#                         when present) or op-ssh-sign (op mode)
#   EXISTING_SIGNING_KEY  user.signingkey git already resolves (existing mode)
# Order, the same on both platforms:
#   1. an on-disk key (~/.ssh/claude_desktop, then ~/.ssh/id_ed25519_signing)
#      with its .pub (the .pub feeds allowed_signers). Signs straight from the
#      file: no agent, no Touch ID prompt, works unattended (issue #171).
#      ~/.ssh/git-sign-no-agent, if executable, becomes gpg.ssh.program so the
#      1Password agent can't intercept the key.
#   2. 1Password's op-ssh-sign at a known install path.
#   3. a user.signingkey git already has (the template ships a literal key with
#      commit.gpgsign = true): signing is on, so allowedSignersFile is still
#      needed or verification shows "No signature" (issue #116, finding 28).
# GITCONFIG_OP_SSH_SIGN is a test seam: set to a path to force op-ssh-sign,
# set to the empty string to simulate "not installed".
# Usage: detect_signing_key OS HOME_DIR
# shellcheck disable=SC2034  # sets globals the caller reads
detect_signing_key() {
    local os="$1" home_dir="$2" candidate
    SIGNING_MODE=none
    SIGNING_KEY_FILE=""
    SIGNING_PROGRAM=""
    EXISTING_SIGNING_KEY=""

    for candidate in "$home_dir/.ssh/claude_desktop" "$home_dir/.ssh/id_ed25519_signing"; do
        if [ -f "$candidate" ] && [ -f "$candidate.pub" ]; then
            SIGNING_MODE="file"
            SIGNING_KEY_FILE="$candidate"
            if [ -x "$home_dir/.ssh/git-sign-no-agent" ]; then
                SIGNING_PROGRAM="$home_dir/.ssh/git-sign-no-agent"
            fi
            return 0
        fi
    done

    if [ -n "${GITCONFIG_OP_SSH_SIGN+set}" ]; then
        candidate="$GITCONFIG_OP_SSH_SIGN"
    else
        candidate=""
        while IFS= read -r candidate; do
            [ -x "$candidate" ] && break
            candidate=""
        done < <(op_ssh_sign_candidates "$os")
    fi
    if [ -n "$candidate" ]; then
        SIGNING_MODE=op
        SIGNING_PROGRAM="$candidate"
        return 0
    fi

    # `|| true`: git config --get exits non-zero when the key is unset.
    EXISTING_SIGNING_KEY="$(git config --get user.signingkey 2>/dev/null || true)"
    if [ -n "$EXISTING_SIGNING_KEY" ]; then
        SIGNING_MODE=existing
    fi
    return 0
}
