#!/bin/bash
# Platform layer for the unified macOS/Linux scripts in scripts/unix/.
#
# The per-OS differences live here and nowhere else:
#   - detect_os / resolve_target_os: which platform's behaviour to run, and the
#     wrong-platform guard (issues #179, #181)
#   - scheduler_install / scheduler_remove / scheduler_status: the login/daily
#     auto-sync job (launchd on macOS; on Linux a systemd user timer when a
#     user manager is running, else cron)
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
# Base name of the systemd user units: gitconfig-update.service runs the
# updater, gitconfig-update.timer starts it daily (issue #246).
GITCONFIG_SYSTEMD_UNIT="gitconfig-update"

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
# Every backend runs scripts/shared/update-gitconfig.sh with the repo path as
# its argument. Jobs made by older installs point at the per-OS
# "scripts/<os> version/update-gitconfig.sh" wrappers, which are kept, so those
# keep working until the next install replaces them.
#
# Linux has two backends. A systemd user timer is used when `systemctl --user`
# reaches a running user manager: it works without a crontab binary, catches
# up on a day the machine was off (Persistent=true), and logs to the journal.
# Otherwise cron. Installing either removes the other, so a machine never
# syncs twice (issue #246).
# ---------------------------------------------------------------------------

# Short name of the scheduler job for messages ("launchd agent", "systemd
# timer", "cron job"). On Linux it names the job that is installed: the
# systemd timer when its units exist, else the cron job when REPO_ROOT (if
# given) has a cron line; with neither, the one an install would pick.
# Usage: scheduler_name OS [REPO_ROOT]
scheduler_name() {
    case "$1" in
        macos) echo "launchd agent"; return 0 ;;
    esac
    if _systemd_units_present; then
        echo "systemd timer"
    elif [ -n "${2:-}" ] && command -v crontab >/dev/null 2>&1 && _cron_has_entry "$2"; then
        echo "cron job"
    elif _systemd_user_available; then
        echo "systemd timer"
    else
        echo "cron job"
    fi
}

_launchd_plist_path() {
    echo "$HOME/Library/LaunchAgents/$GITCONFIG_LAUNCHD_LABEL.plist"
}

# The launchd domain of this user's login session. `launchctl load`/`unload`
# are deprecated; `bootstrap`/`bootout` name the domain explicitly (#234).
_launchd_domain() {
    echo "gui/$(id -u)"
}

# Unload the agent if it is loaded. Fails when it wasn't loaded (or launchctl
# refused); callers that only want it gone ignore that.
# Usage: _launchd_bootout
_launchd_bootout() {
    launchctl bootout "$(_launchd_domain)/$GITCONFIG_LAUNCHD_LABEL" >/dev/null 2>&1
}

# Per-user log for the cron job: ${XDG_STATE_HOME:-~/.local/state}/gitconfig/
# gitconfig-update.log. It used to be the shared /tmp/gitconfig-update.log:
# once another user owned that file, the job's `>>` redirect failed and sh
# skipped the whole job, so auto-sync silently never ran (issue #259). The XDG
# spec ignores a relative XDG_STATE_HOME, and so does this.
# Usage: cron_log_path
cron_log_path() {
    local state="${XDG_STATE_HOME:-}"
    case "$state" in
        /*) ;;
        *)  state="$HOME/.local/state" ;;
    esac
    echo "$state/gitconfig/gitconfig-update.log"
}

# Quote a value for a crontab command line: a double-quoted sh word with \, ",
# $ and ` escaped, then every % escaped as \% (cron turns an unescaped % into
# a newline and strips the backslash from \%). Fails for a value with a
# newline, which no crontab line can hold.
# Usage: _cron_quote VALUE
_cron_quote() {
    case "$1" in
        *"
"*) return 1 ;;
    esac
    printf '"%s"\n' "$(printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g' -e 's/%/\\%/g')"
}

# The cron line this installer writes (daily at 9 AM). The log catches what
# the updater can't log itself: its own log lives inside the repo, so a wrong
# repo path can only be reported on stderr. Fails (prints nothing) for a path
# that can't be quoted (a newline in it).
# Usage: cron_entry REPO_ROOT
cron_entry() {
    local repo_root="$1" q_updater q_repo q_log
    q_updater="$(_cron_quote "$repo_root/scripts/shared/update-gitconfig.sh")" || return 1
    q_repo="$(_cron_quote "$repo_root")" || return 1
    q_log="$(_cron_quote "$(cron_log_path)")" || return 1
    printf '0 9 * * * bash %s %s >> %s 2>&1 %s\n' \
        "$q_updater" "$q_repo" "$q_log" "$GITCONFIG_CRON_MARKER"
}

# Filter a crontab (on stdin) by whether each line is this clone's job:
#   -q  succeed if any line is ours (prints nothing)
#   -v  print the crontab minus our lines
# A line is ours when it isn't a comment, runs an update-gitconfig.sh, and
# names this clone's own "<REPO_ROOT>/scripts/... path: the tagged line this
# installer writes, or an untagged one from an install that predates the
# marker (those ran "<REPO_ROOT>/scripts/linux version/update-gitconfig.sh").
# Another clone's job, or a commented-out line, is never ours (issue #259).
# The leading quote and trailing /scripts/ stop /x/gitconfig from matching
# /x/gitconfig2. Both the escaped form we write and the raw form older
# installs wrote are matched; they differ only for paths with \ " $ ` or %.
# Usage: crontab -l | _cron_ours -q|-v REPO_ROOT
_cron_ours() {
    local mode="$1" repo_root="$2" escaped
    # The quoted path minus its closing quote. A path with a newline can't be
    # in a crontab line at all; the raw pattern below still covers it.
    escaped="$(_cron_quote "$repo_root")" || escaped="\"$repo_root\""
    escaped="${escaped%?}"
    # awk -v would process backslash escapes in the patterns; ENVIRON doesn't.
    GITCONFIG_CRON_PAT_RAW="\"$repo_root/scripts/" \
    GITCONFIG_CRON_PAT_ESC="$escaped/scripts/" \
    awk -v mode="$mode" '
        function ours(line) {
            if (line ~ /^[ \t]*#/) return 0
            if (index(line, "update-gitconfig.sh") == 0) return 0
            return index(line, ENVIRON["GITCONFIG_CRON_PAT_RAW"]) > 0 ||
                   index(line, ENVIRON["GITCONFIG_CRON_PAT_ESC"]) > 0
        }
        ours($0) { found = 1; next }
        mode == "-v" { print }
        END { if (mode == "-q") exit(found ? 0 : 1) }
    '
}

# Usage: _cron_has_entry REPO_ROOT
_cron_has_entry() {
    crontab -l 2>/dev/null | _cron_ours -q "$1"
}

# Rewrite the crontab without this clone's lines. Every other entry is kept.
# Usage: _cron_remove_entries REPO_ROOT
_cron_remove_entries() {
    crontab -l 2>/dev/null | _cron_ours -v "$1" | crontab - 2>/dev/null
}

# Register the auto-sync job. Prompts before replacing an existing job unless
# FORCE is true. Never fails the caller (safe under set -e): returns 0 when the
# job was written, 1 when it was skipped or could not be written. On Linux a
# systemd timer that can't be enabled falls back to cron.
# Usage: scheduler_install OS REPO_ROOT FORCE
scheduler_install() {
    local rc
    case "$1" in
        macos) _launchd_install "$2" "$3"; return ;;
    esac
    if _systemd_user_available; then
        rc=0
        _systemd_install "$2" "$3" || rc=$?
        # 2: the units couldn't be enabled (and were removed again); use cron.
        [ "$rc" -ne 2 ] && return "$rc"
    fi
    _cron_install "$2" "$3"
}

# Remove the auto-sync job. Returns 0 if one was removed, 1 if there was none
# (or no crontab binary to ask). On Linux this removes the systemd timer and
# REPO_ROOT's cron lines, whichever are present; another clone's cron line
# survives. The launchd agent and the systemd timer have one fixed name per
# user, so they are removed whatever REPO_ROOT is.
# Usage: scheduler_remove OS REPO_ROOT
scheduler_remove() {
    local rc=1
    case "$1" in
        macos) _launchd_remove; return ;;
    esac
    if _systemd_units_present; then
        _systemd_remove && rc=0
        if command -v crontab >/dev/null 2>&1 && _cron_has_entry "$2"; then
            _cron_remove "$2" && rc=0
        fi
        return "$rc"
    fi
    _cron_remove "$2"
}

# Succeed if the auto-sync job is registered: on macOS a plist that is valid
# (checked with plutil -lint where plutil exists), on Linux the systemd timer
# unit or a cron line for REPO_ROOT.
# Usage: scheduler_status OS REPO_ROOT
scheduler_status() {
    case "$1" in
        macos) [ -f "$(_launchd_plist_path)" ] && _launchd_plist_valid "$(_launchd_plist_path)" ;;
        *)     [ -f "$(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.timer" ] ||
               { command -v crontab >/dev/null 2>&1 && _cron_has_entry "$2"; } ;;
    esac
}

_cron_install() {
    local repo_root="$1" force="$2" updater entry log_path
    updater="$repo_root/scripts/shared/update-gitconfig.sh"
    log_path="$(cron_log_path)"

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

    if ! entry="$(cron_entry "$repo_root")"; then
        echo "[WARN] Repo path contains a newline; a cron line can't hold it. Skipping the cron job."
        return 1
    fi
    # sh skips the whole job when the >> redirect can't open the log, so the
    # directory must exist before the first run.
    if ! mkdir -p "$(dirname "$log_path")" 2>/dev/null; then
        echo "[WARN] Could not create $(dirname "$log_path"); skipping the cron job"
        return 1
    fi

    if _cron_has_entry "$repo_root"; then
        if [ "$force" != true ]; then
            # No input to read (cron, CI) counts as "no" rather than failing (#258).
            read -p "Cron job already exists. Replace? (y/n) " -n 1 -r || REPLY=
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: Cron job"
                return 1
            fi
        fi
        # Drops this clone's old line too when it came from an install that
        # predates the marker, so the job is migrated rather than duplicated.
        _cron_remove_entries "$repo_root" || true
    fi

    if (crontab -l 2>/dev/null || true; echo "$entry") | crontab - 2>/dev/null; then
        echo "[OK] Created cron job for daily updates at 9 AM"
        echo "     Log: $log_path"
        # A timer left by an earlier install (when a user manager was running)
        # would sync a second time.
        if _systemd_units_present; then
            _systemd_remove >/dev/null 2>&1 || true
            if _systemd_units_present; then
                echo "[WARN] Could not remove the old systemd timer; remove $(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.{service,timer} so the sync doesn't run twice"
            else
                echo "[OK] Removed the old systemd timer (the cron job replaces it)"
            fi
        fi
        return 0
    fi
    echo "[WARN] Could not create cron job (cron may not be available)"
    return 1
}

# Usage: _cron_remove REPO_ROOT
_cron_remove() {
    local repo_root="$1"
    if ! command -v crontab >/dev/null 2>&1; then
        echo "[SKIP] crontab not found; no cron job to remove"
        return 1
    fi
    if ! _cron_has_entry "$repo_root"; then
        echo "[SKIP] Cron job not found"
        return 1
    fi
    if _cron_remove_entries "$repo_root"; then
        echo "[OK] Removed cron job"
        return 0
    fi
    echo "[WARN] Could not rewrite the crontab"
    return 1
}

# ---------------------------------------------------------------------------
# systemd user timer (Linux)
# ---------------------------------------------------------------------------

# Where systemd looks for the user's own units. Like the XDG spec, a relative
# XDG_CONFIG_HOME is ignored.
# Usage: _systemd_unit_dir
_systemd_unit_dir() {
    local config="${XDG_CONFIG_HOME:-}"
    case "$config" in
        /*) ;;
        *)  config="$HOME/.config" ;;
    esac
    echo "$config/systemd/user"
}

# Succeed if either of our unit files exists.
_systemd_units_present() {
    local dir
    dir="$(_systemd_unit_dir)"
    [ -f "$dir/$GITCONFIG_SYSTEMD_UNIT.timer" ] || [ -f "$dir/$GITCONFIG_SYSTEMD_UNIT.service" ]
}

# Succeed if `systemctl --user` reaches a running user manager. It doesn't
# without one (containers, WSL without systemd, a cron/ssh context with no
# session bus), and then cron is used instead.
_systemd_user_available() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# Quote a value as one word of a systemd ExecStart= line: a double-quoted
# string with \ and " escaped, % doubled (specifier) and $ doubled (variable
# expansion). Fails for a value with a newline, which no unit line can hold.
# Usage: _systemd_quote VALUE
_systemd_quote() {
    case "$1" in
        *"
"*) return 1 ;;
    esac
    printf '"%s"\n' "$(printf '%s' "$1" | sed -e 's/[\\"]/\\&/g' -e 's/%/%%/g' -e 's/\$/$$/g')"
}

# Delete the unit files and the enable link `systemctl enable` made, so
# nothing is left behind even when systemctl can't be asked.
_systemd_delete_units() {
    local dir
    dir="$(_systemd_unit_dir)"
    rm -f "$dir/$GITCONFIG_SYSTEMD_UNIT.timer" "$dir/$GITCONFIG_SYSTEMD_UNIT.service" \
        "$dir/timers.target.wants/$GITCONFIG_SYSTEMD_UNIT.timer" 2>/dev/null
}

# A user timer only runs while the user manager does: from login to logout,
# unless linger is on. Print a one-line hint when loginctl says it's off;
# print nothing when that can't be told.
_systemd_linger_hint() {
    local user linger
    command -v loginctl >/dev/null 2>&1 || return 0
    user="${USER:-$(id -un 2>/dev/null)}"
    [ -n "$user" ] || return 0
    linger="$(loginctl show-user "$user" -p Linger 2>/dev/null)" || return 0
    if [ "$linger" = "Linger=no" ]; then
        echo "[NOTE] Linger is off, so the timer runs only while you are logged in. To run it with no session (headless machines): loginctl enable-linger $user"
    fi
    return 0
}

# Write and enable the timer. Returns 0 when it is enabled, 1 when skipped or
# not written, 2 when systemctl couldn't enable it (the units are removed
# again and the caller falls back to cron).
# Usage: _systemd_install REPO_ROOT FORCE
_systemd_install() {
    local repo_root="$1" force="$2" updater dir bash_bin q_bash q_updater q_repo
    updater="$repo_root/scripts/shared/update-gitconfig.sh"
    dir="$(_systemd_unit_dir)"

    if [ ! -f "$updater" ]; then
        echo "[WARN] update-gitconfig.sh not found"
        return 1
    fi
    # systemd needs an absolute ExecStart path; /bin/bash isn't one on NixOS.
    bash_bin="$(command -v bash 2>/dev/null || true)"
    case "$bash_bin" in
        /*) ;;
        *)  bash_bin=/bin/bash ;;
    esac
    if ! q_bash="$(_systemd_quote "$bash_bin")" ||
       ! q_updater="$(_systemd_quote "$updater")" ||
       ! q_repo="$(_systemd_quote "$repo_root")"; then
        echo "[WARN] Repo path contains a newline; a systemd unit can't hold it. Skipping the systemd timer."
        return 1
    fi

    if _systemd_units_present && [ "$force" != true ]; then
        # No input to read (cron, CI) counts as "no" rather than failing (#258).
        read -p "systemd timer already exists. Replace? (y/n) " -n 1 -r || REPLY=
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipped: systemd timer"
            return 1
        fi
    fi

    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "[WARN] Could not create $dir; skipping the systemd timer"
        return 1
    fi
    if ! cat > "$dir/$GITCONFIG_SYSTEMD_UNIT.service" 2>/dev/null << UNIT
# Written by gitconfig's install.sh; removed by cleanup-gitconfig.sh.
[Unit]
Description=Sync the gitconfig repo and regenerate ~/.gitconfig

[Service]
Type=oneshot
ExecStart=$q_bash $q_updater $q_repo
UNIT
    then
        echo "[WARN] Could not write $dir/$GITCONFIG_SYSTEMD_UNIT.service; skipping the systemd timer"
        _systemd_delete_units
        return 1
    fi
    if ! cat > "$dir/$GITCONFIG_SYSTEMD_UNIT.timer" 2>/dev/null << UNIT
# Written by gitconfig's install.sh; removed by cleanup-gitconfig.sh.
[Unit]
Description=Daily gitconfig sync

[Timer]
OnCalendar=daily
# Run at the next start when the machine was off at the scheduled time.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    then
        echo "[WARN] Could not write $dir/$GITCONFIG_SYSTEMD_UNIT.timer; skipping the systemd timer"
        _systemd_delete_units
        return 1
    fi

    if ! systemctl --user daemon-reload >/dev/null 2>&1 ||
       ! systemctl --user enable --now "$GITCONFIG_SYSTEMD_UNIT.timer" >/dev/null 2>&1; then
        echo "[WARN] Could not enable the systemd timer; using cron instead"
        _systemd_delete_units
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        return 2
    fi

    echo "[OK] Enabled systemd timer $GITCONFIG_SYSTEMD_UNIT.timer (daily; runs at the next start after a missed day)"
    echo "     Logs: journalctl --user -u $GITCONFIG_SYSTEMD_UNIT"
    # A cron line from an earlier install (tagged, or untagged from before the
    # marker) would sync a second time.
    if command -v crontab >/dev/null 2>&1 && _cron_has_entry "$repo_root"; then
        if _cron_remove_entries "$repo_root" && ! _cron_has_entry "$repo_root"; then
            echo "[OK] Removed the old cron job (the timer replaces it)"
        else
            echo "[WARN] Could not remove the old cron job; remove it with 'crontab -e' so the sync doesn't run twice"
        fi
    fi
    _systemd_linger_hint
    return 0
}

# Disable the timer and delete its units. Returns 0 when they are gone, 1
# when there were none or they couldn't be deleted.
_systemd_remove() {
    local dir
    dir="$(_systemd_unit_dir)"
    if ! _systemd_units_present; then
        echo "[SKIP] systemd timer not found"
        return 1
    fi
    if _systemd_user_available; then
        systemctl --user disable --now "$GITCONFIG_SYSTEMD_UNIT.timer" >/dev/null 2>&1 || true
        systemctl --user stop "$GITCONFIG_SYSTEMD_UNIT.service" >/dev/null 2>&1 || true
    fi
    _systemd_delete_units
    if _systemd_user_available; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    if _systemd_units_present; then
        echo "[WARN] Could not delete the systemd units in $dir"
        return 1
    fi
    echo "[OK] Removed systemd timer: $GITCONFIG_SYSTEMD_UNIT.timer"
    return 0
}

# Escape a value for a plist <string>: & < > would otherwise end the element
# or start an entity, and the plist would not parse (issue #259).
# Usage: _xml_escape VALUE
_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Succeed if PLIST parses. Uses plutil -lint where it exists (macOS); without
# plutil there is nothing to check with, so the plist is taken as valid.
# Usage: _launchd_plist_valid PLIST
_launchd_plist_valid() {
    command -v plutil >/dev/null 2>&1 || return 0
    plutil -lint -s "$1" >/dev/null 2>&1
}

_launchd_install() {
    local repo_root="$1" force="$2" updater plist_path launch_agents_dir launchd_path
    local x_updater x_repo x_log
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
            # No input to read (cron, CI) counts as "no" rather than failing (#258).
            read -p "launchd agent already exists. Replace? (y/n) " -n 1 -r || REPLY=
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: launchd agent"
                return 1
            fi
        fi
        rm -f "$plist_path"
    fi
    # Bootstrapping a label that is still loaded fails ("service already
    # loaded"), so unload any copy first, even one whose plist is gone.
    _launchd_bootout || true

    x_updater="$(_xml_escape "$updater")"
    x_repo="$(_xml_escape "$repo_root")"
    x_log="$(_xml_escape "$repo_root/docs/update-gitconfig.log")"
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
        <string>$x_updater</string>
        <string>$x_repo</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$launchd_path</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$x_log</string>
    <key>StandardErrorPath</key>
    <string>$x_log</string>
</dict>
</plist>
PLIST

    # Don't report "registered" for a plist launchd can't read.
    if ! _launchd_plist_valid "$plist_path"; then
        echo "[WARN] The launchd plist failed plutil -lint; removed it."
        echo "       Auto-sync is not set up. Sync by hand with: git selfupdate"
        rm -f "$plist_path"
        return 1
    fi

    if launchctl bootstrap "$(_launchd_domain)" "$plist_path" 2>/dev/null; then
        echo "[OK] launchd agent registered: $GITCONFIG_LAUNCHD_LABEL"
        echo "     Runs automatically at each login."
        echo ""
        echo "     NOTE: macOS may block the agent from accessing ~/Documents"
        echo "     until your terminal app has Full Disk Access."
        echo "     If auto-sync does not run, go to:"
        echo "       System Settings > Privacy & Security > Full Disk Access"
        echo "     enable your terminal app, then reload the agent with:"
        echo "       launchctl bootout $(_launchd_domain)/$GITCONFIG_LAUNCHD_LABEL"
        echo "       launchctl bootstrap $(_launchd_domain) \"$plist_path\""
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
        # A loaded agent whose plist was deleted by hand still runs until
        # logout; unload it too.
        if _launchd_bootout; then
            echo "[OK] Unloaded launchd agent (its plist was already gone)"
            return 0
        fi
        echo "[SKIP] launchd plist not found"
        return 1
    fi
    # bootout fails when the agent isn't loaded (say, launchd never picked it
    # up, or it was unloaded by hand); the plist is still removed.
    if _launchd_bootout; then
        echo "[OK] Unloaded launchd agent"
    else
        echo "[SKIP] launchd agent was not loaded"
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
