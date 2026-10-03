#!/usr/bin/env bats
#
# scripts/shared/platform.sh: the per-OS layer under scripts/unix/ (issue #229).
#   - detect_os / requested_os / resolve_target_os: which platform to act for,
#     and the wrong-platform guard (issues #179, #181)
#   - the cron backend's line format and its marker-based removal
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
    unset GITCONFIG_PLATFORM GITCONFIG_ALLOW_CROSS_OS GITCONFIG_OP_SSH_SIGN
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
    [ "$output" = '0 9 * * * bash "/r e/po/scripts/shared/update-gitconfig.sh" "/r e/po" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate' ]
}

@test "scheduler_remove keeps every cron line that isn't ours" {
    printf '#!/bin/sh\ncase "$1" in\n    -l) cat "%s" ;;\n    -)  cat > "%s.new" && mv "%s.new" "%s" ;;\nesac\n' \
        "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" "$SANDBOX/crontab.txt" \
        > "$SANDBOX/bin/crontab"
    chmod +x "$SANDBOX/bin/crontab"
    {
        echo 'MAILTO=me@example.com'
        echo '0 8 * * * echo keep-me'
        echo '0 9 * * * bash "/a/scripts/shared/update-gitconfig.sh" "/a" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate'
        echo '0 9 * * * bash "/b/scripts/linux version/update-gitconfig.sh" "/b" >> /tmp/gitconfig-update.log 2>&1'
    } > "$SANDBOX/crontab.txt"

    run _platform 'scheduler_remove linux'
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$(printf 'MAILTO=me@example.com\n0 8 * * * echo keep-me')" ]
    run _platform 'scheduler_status linux'
    [ "$status" -ne 0 ]
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
