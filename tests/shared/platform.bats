#!/usr/bin/env bats
#
# scripts/shared/platform.sh: the per-OS layer under scripts/unix/ (issue #229).
#   - detect_os / requested_os / resolve_target_os: which platform to act for,
#     and the wrong-platform guard (issues #179, #181)
#   - the cron backend's line format (quoting, per-user log) and its removal,
#     which claims only this clone's lines (issue #259)
#   - the launchd plist's XML escaping and plutil -lint check (issue #259)
#   - detect_signing_key / detect_credential_helper: the same priority order
#     on both platforms, with only the probe paths and the helper differing
#
# Functions are sourced into a subshell with `uname` stubbed, so every
# platform is exercised on any host.
#
# Run with:  bats tests/shared/platform.bats
# Requires:  bats-core (>= 1.5) and git.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME" "$SANDBOX/bin"
    export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    : > "$GIT_CONFIG_GLOBAL"
    unset GITCONFIG_PLATFORM GITCONFIG_ALLOW_CROSS_OS GITCONFIG_OP_SSH_SIGN XDG_STATE_HOME XDG_CONFIG_HOME
    # The scheduler must never reach the real systemd user manager: no session
    # bus, and a systemctl that finds no user manager (tests that want one
    # replace it).
    unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
    printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/systemctl"
    chmod +x "$SANDBOX/bin/systemctl"
}

teardown() {
    rm -rf "$SANDBOX"
}

# $1 = the value `uname -s` should print
_stub_uname() {
    printf '#!/bin/sh\necho %s\n' "$1" > "$SANDBOX/bin/uname"
    chmod +x "$SANDBOX/bin/uname"
}

# Run a snippet with platform.sh sourced and the stubbed tools first on PATH.
_platform() {
    PATH="$SANDBOX/bin:$PATH" bash -c "source '$REPO_ROOT/scripts/shared/platform.sh'; $1"
}

@test "detect_os maps Darwin to macos and anything else to linux" {
    _stub_uname Darwin
    [ "$(_platform detect_os)" = macos ]
    _stub_uname Linux
    [ "$(_platform detect_os)" = linux ]
    _stub_uname FreeBSD
    [ "$(_platform detect_os)" = linux ]
}

@test "resolve_target_os follows the host when no platform is requested" {
    _stub_uname Darwin
    [ "$(_platform 'resolve_target_os installer install.sh')" = macos ]
    _stub_uname Linux
    [ "$(_platform 'resolve_target_os installer install.sh')" = linux ]
}

@test "resolve_target_os refuses a requested platform that isn't the host" {
    _stub_uname Linux
    export GITCONFIG_PLATFORM=macos
    run _platform 'resolve_target_os installer install.sh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"This is the macOS installer but this host is Linux."* ]]
    [[ "$output" == *"scripts/unix/install.sh"* ]]

    _stub_uname Darwin
    export GITCONFIG_PLATFORM=linux
    run _platform 'resolve_target_os script initialize-local-config.sh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"This is the Linux script but this host is macOS."* ]]
}

@test "GITCONFIG_ALLOW_CROSS_OS=1 lets a requested platform through" {
    _stub_uname Linux
    export GITCONFIG_PLATFORM=macos GITCONFIG_ALLOW_CROSS_OS=1
    [ "$(_platform 'resolve_target_os installer install.sh')" = macos ]
}

@test "an unknown GITCONFIG_PLATFORM is an error, not a silent default" {
    export GITCONFIG_PLATFORM=windows
    run _platform 'requested_os'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown GITCONFIG_PLATFORM"* ]]
}

@test "cron_entry runs the shared updater with the repo path and ends with the marker" {
    run _platform 'cron_entry "/r e/po"'
    [ "$status" -eq 0 ]
    [ "$output" = "0 9 * * * bash \"/r e/po/scripts/shared/update-gitconfig.sh\" \"/r e/po\" >> \"$HOME/.local/state/gitconfig/gitconfig-update.log\" 2>&1 # gitconfig-autoupdate" ]
}

@test "the cron log is per user, not the shared /tmp file (#259)" {
    run _platform 'cron_log_path'
    [ "$output" = "$HOME/.local/state/gitconfig/gitconfig-update.log" ]
    run env XDG_STATE_HOME="$SANDBOX/state" bash -c "source '$REPO_ROOT/scripts/shared/platform.sh'; cron_log_path"
    [ "$output" = "$SANDBOX/state/gitconfig/gitconfig-update.log" ]
    # The XDG spec says to ignore a relative XDG_STATE_HOME.
    run env XDG_STATE_HOME="rel/state" bash -c "source '$REPO_ROOT/scripts/shared/platform.sh'; cron_log_path"
    [ "$output" = "$HOME/.local/state/gitconfig/gitconfig-update.log" ]
    run _platform 'cron_entry /repo'
    [[ "$output" != *" /tmp/gitconfig-update.log "* ]]
    [[ "$output" == *" >> \"$HOME/.local/state/gitconfig/gitconfig-update.log\" "* ]]
}

@test "cron_entry escapes % and quotes the path so cron and sh pass it through intact (#259)" {
    repo="$SANDBOX/odd 100%"'$HOME"q`x`\b'
    export repo
    run _platform 'cron_entry "$repo"'
    [ "$status" -eq 0 ]
    line="$output"
    # cron turns an unescaped % into a newline: every % must be escaped.
    run ! grep -qE '(^|[^\\])%' <<<"$line"
    # Do what cron does: drop the schedule, turn \% into %, hand it to sh.
    cmd="$(printf '%s\n' "${line#0 9 \* \* \* }" | sed 's/\\%/%/g')"
    # A fake bash that records its arguments, one per line.
    mkdir -p "$SANDBOX/argbin" "$HOME/.local/state/gitconfig"
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$SANDBOX/argbin/bash"
    chmod +x "$SANDBOX/argbin/bash"
    PATH="$SANDBOX/argbin:$PATH" sh -c "$cmd"
    [ "$(cat "$HOME/.local/state/gitconfig/gitconfig-update.log")" = "$(printf '%s\n%s' "$repo/scripts/shared/update-gitconfig.sh" "$repo")" ]
}

@test "cron_entry refuses a repo path with a newline" {
    run _platform 'cron_entry "$(printf "/a\nb")"'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# A crontab stub backed by $SANDBOX/crontab.txt.
_stub_crontab_file() {
    printf '#!/bin/sh\ncase "$1" in\n    -l) cat "%s" ;;\n    -)  cat > "%s.new" && mv "%s.new" "%s" ;;\nesac\n' \
        "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" \
        > "$SANDBOX/bin/crontab"
    chmod +x "$SANDBOX/bin/crontab"
}

@test "scheduler_remove keeps every cron line that isn't ours" {
    _stub_crontab_file
    {
        echo 'MAILTO=me@example.com'
        echo '0 8 * * * echo keep-me'
        echo '0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate'
        echo '0 9 * * * bash "/a/scripts/linux version/update-gitconfig.sh" "/a" >> /tmp/gitconfig-update.log 2>&1'
    } > "$SANDBOX/crontab.txt"

    run _platform 'scheduler_remove linux /a'
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$(printf 'MAILTO=me@example.com\n0 8 * * * echo keep-me')" ]
    run _platform 'scheduler_status linux /a'
    [ "$status" -ne 0 ]
}

@test "scheduler_remove claims only this clone's lines, never another clone's or a comment (#259)" {
    _stub_crontab_file
    others="$(cat <<'EOF'
0 9 * * * bash "/b/scripts/shared/update-gitconfig.sh" "/b" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate
0 9 * * * bash "/b/scripts/linux version/update-gitconfig.sh" "/b" >> /tmp/gitconfig-update.log 2>&1
0 9 * * * bash "/a2/scripts/shared/update-gitconfig.sh" "/a2" 2>&1 # gitconfig-autoupdate
# 0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" 2>&1 # gitconfig-autoupdate
   #0 9 * * * bash "/a/scripts/linux version/update-gitconfig.sh" >> /tmp/gitconfig-update.log 2>&1
0 7 * * * /usr/local/bin/my-update-gitconfig.sh
EOF
)"
    {
        echo '0 8 * * * echo keep-me'
        echo '0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" >> "/h/.local/state/gitconfig/gitconfig-update.log" 2>&1 # gitconfig-autoupdate'
        # The oldest Linux installs passed no repo argument.
        echo '0 9 * * * bash "/a/scripts/linux version/update-gitconfig.sh" >> /tmp/gitconfig-update.log 2>&1'
        printf '%s\n' "$others"
    } > "$SANDBOX/crontab.txt"

    run _platform 'scheduler_status linux /a'
    [ "$status" -eq 0 ]
    run _platform 'scheduler_remove linux /a'
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$(printf '0 8 * * * echo keep-me\n%s' "$others")" ]
    run _platform 'scheduler_status linux /a'
    [ "$status" -ne 0 ]
    # /b's and /a2's jobs are still there for their own clones.
    run _platform 'scheduler_status linux /b'
    [ "$status" -eq 0 ]
    run _platform 'scheduler_status linux /a2'
    [ "$status" -eq 0 ]
}

@test "a commented-out line alone doesn't count as an installed cron job (#259)" {
    _stub_crontab_file
    echo '# 0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" 2>&1 # gitconfig-autoupdate' > "$SANDBOX/crontab.txt"
    run _platform 'scheduler_status linux /a'
    [ "$status" -ne 0 ]
    run _platform 'scheduler_remove linux /a'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cron job not found"* ]]
}

@test "scheduler_install finds and replaces a cron line for a path with special characters (#259)" {
    _stub_crontab_file
    : > "$SANDBOX/crontab.txt"
    repo="$SANDBOX/a&b 50%"'$x"'
    mkdir -p "$repo/scripts/shared"
    : > "$repo/scripts/shared/update-gitconfig.sh"
    export repo
    for _ in 1 2; do
        run _platform 'scheduler_install linux "$repo" true'
        [ "$status" -eq 0 ]
    done
    [ "$(wc -l < "$SANDBOX/crontab.txt")" -eq 1 ]
    # The log directory exists before the job's first run.
    [ -d "$HOME/.local/state/gitconfig" ]
    run _platform 'scheduler_status linux "$repo"'
    [ "$status" -eq 0 ]
    run _platform 'scheduler_remove linux "$repo"'
    [ "$status" -eq 0 ]
    [ ! -s "$SANDBOX/crontab.txt" ]
}

# A clone at $1 with an updater, for the launchd tests; launchctl is stubbed.
_launchd_clone() {
    mkdir -p "$1/scripts/shared"
    : > "$1/scripts/shared/update-gitconfig.sh"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/launchctl"
    chmod +x "$SANDBOX/bin/launchctl"
}

@test "the launchd plist escapes & < > in the repo path and still parses (#259)" {
    repo="$SANDBOX/R&D <dev> clone"
    _launchd_clone "$repo"
    export repo
    run _platform 'scheduler_install macos "$repo" true'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] launchd agent registered"* ]]
    plist="$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    run python3 - "$plist" "$repo" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    p = plistlib.load(f)
repo = sys.argv[2]
assert p["ProgramArguments"] == ["/bin/bash", repo + "/scripts/shared/update-gitconfig.sh", repo], p["ProgramArguments"]
assert p["StandardOutPath"] == repo + "/docs/update-gitconfig.log", p["StandardOutPath"]
PY
    [ "$status" -eq 0 ]
}

@test "a plist that fails plutil -lint isn't reported as registered or verified (#259)" {
    _launchd_clone "$SANDBOX/clone"
    plist="$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    # plutil calls every plist malformed.
    printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/plutil"
    chmod +x "$SANDBOX/bin/plutil"
    run _platform "scheduler_install macos '$SANDBOX/clone' true"
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed plutil -lint"* ]]
    [[ "$output" != *"registered"* ]]
    [ ! -e "$plist" ]

    # A malformed plist already on disk doesn't pass the status check...
    mkdir -p "$(dirname "$plist")"
    echo '<plist><string>a & b</string></plist>' > "$plist"
    run _platform 'scheduler_status macos'
    [ "$status" -ne 0 ]
    # ...but one plutil accepts does.
    printf '#!/bin/sh\n[ "$1" = -lint ] || exit 2\nexit 0\n' > "$SANDBOX/bin/plutil"
    run _platform 'scheduler_status macos'
    [ "$status" -eq 0 ]
}

@test "detect_signing_key: an on-disk key with its .pub wins over op-ssh-sign" {
    mkdir -p "$HOME/.ssh"
    : > "$HOME/.ssh/id_ed25519_signing"
    : > "$HOME/.ssh/id_ed25519_signing.pub"
    export GITCONFIG_OP_SSH_SIGN=/some/op-ssh-sign
    run _platform 'detect_signing_key linux "$HOME"; echo "$SIGNING_MODE $SIGNING_KEY_FILE"'
    [ "$output" = "file $HOME/.ssh/id_ed25519_signing" ]
}

@test "detect_signing_key: op-ssh-sign, then an existing signing key, then none" {
    export GITCONFIG_OP_SSH_SIGN=/some/op-ssh-sign
    run _platform 'detect_signing_key linux "$HOME"; echo "$SIGNING_MODE $SIGNING_PROGRAM"'
    [ "$output" = "op /some/op-ssh-sign" ]

    export GITCONFIG_OP_SSH_SIGN=""
    git config --global user.signingkey "ssh-ed25519 AAAALITERAL"
    run _platform 'detect_signing_key linux "$HOME"; echo "$SIGNING_MODE"'
    [ "$output" = existing ]

    git config --global --unset user.signingkey
    run _platform 'detect_signing_key macos "$HOME"; echo "$SIGNING_MODE"'
    [ "$output" = none ]
}

@test "op-ssh-sign probe paths cover Homebrew, the macOS app bundle and the Linux package" {
    run _platform 'op_ssh_sign_candidates macos'
    [[ "$output" == *"/opt/homebrew/bin/op-ssh-sign"* ]]
    [[ "$output" == *"/usr/local/bin/op-ssh-sign"* ]]
    [[ "$output" == *"/Applications/1Password.app/Contents/MacOS/op-ssh-sign"* ]]
    run _platform 'op_ssh_sign_candidates linux'
    [ "$output" = /opt/1Password/op-ssh-sign ]
}

@test "detect_credential_helper: osxkeychain on macOS, gh then libsecret on Linux" {
    run _platform 'detect_credential_helper macos; echo "$CREDENTIAL_HELPER_KIND"'
    [ "$output" = osxkeychain ]

    export GITCONFIG_GH_BIN=/x/gh GITCONFIG_LIBSECRET_BIN=/x/libsecret
    run _platform 'detect_credential_helper linux; echo "$CREDENTIAL_HELPER_KIND $CREDENTIAL_HELPER_PATH"'
    [ "$output" = "gh /x/gh" ]

    export GITCONFIG_GH_BIN=""
    run _platform 'detect_credential_helper linux; echo "$CREDENTIAL_HELPER_KIND $CREDENTIAL_HELPER_PATH"'
    [ "$output" = "libsecret /x/libsecret" ]

    export GITCONFIG_LIBSECRET_BIN=""
    run _platform 'detect_credential_helper linux; echo "$CREDENTIAL_HELPER_KIND"'
    [ "$output" = none ]
}

# A systemctl whose user manager is running; calls are logged.
_stub_systemctl_ok() {
    printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\nexit 0\n' "$SANDBOX" > "$SANDBOX/bin/systemctl"
    chmod +x "$SANDBOX/bin/systemctl"
}

@test "the systemd timer's ExecStart escapes quotes, backslashes, percent and dollar signs in the repo path (#246)" {
    _stub_systemctl_ok
    repo="$SANDBOX/a\"b\\c 50%"'$x'
    mkdir -p "$repo/scripts/shared"
    : > "$repo/scripts/shared/update-gitconfig.sh"
    export repo
    run _platform 'scheduler_install linux "$repo" true'
    [ "$status" -eq 0 ]
    # systemd reads \" and \\ as escapes, %% as %, $$ as $.
    esc="$SANDBOX/a\\\"b\\\\c 50%%\$\$x"
    grep -qF "\"$esc/scripts/shared/update-gitconfig.sh\" \"$esc\"" \
        "$HOME/.config/systemd/user/gitconfig-update.service"
    run _platform 'scheduler_status linux "$repo"'
    [ "$status" -eq 0 ]
    run _platform 'scheduler_remove linux "$repo"'
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.config/systemd/user/gitconfig-update.timer" ]
}

@test "the systemd units go under an absolute XDG_CONFIG_HOME, not a relative one (#246)" {
    export XDG_CONFIG_HOME="$SANDBOX/cfg"
    [ "$(_platform _systemd_unit_dir)" = "$SANDBOX/cfg/systemd/user" ]
    export XDG_CONFIG_HOME=relative/cfg
    [ "$(_platform _systemd_unit_dir)" = "$HOME/.config/systemd/user" ]
}

@test "scheduler_name on Linux names the timer or the cron job that is in place (#246)" {
    _stub_uname Linux
    _stub_crontab_file
    : > "$SANDBOX/crontab.txt"
    # No user manager, nothing installed: an install would use cron.
    [ "$(_platform 'scheduler_name linux /a')" = "cron job" ]
    _stub_systemctl_ok
    [ "$(_platform 'scheduler_name linux /a')" = "systemd timer" ]
    # This clone's cron line wins over an available but unused user manager...
    echo '0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" # gitconfig-autoupdate' > "$SANDBOX/crontab.txt"
    [ "$(_platform 'scheduler_name linux /a')" = "cron job" ]
    # ...and the timer's units win over both.
    mkdir -p "$HOME/.config/systemd/user"
    : > "$HOME/.config/systemd/user/gitconfig-update.timer"
    [ "$(_platform 'scheduler_name linux /a')" = "systemd timer" ]
    [ "$(_platform 'scheduler_name macos /a')" = "launchd agent" ]
}
