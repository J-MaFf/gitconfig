#!/usr/bin/env bats
#
# Bats suite for scripts/linux version/initialize-local-config.sh, covering:
#   - HTTPS credential helper (issue #179): the generated ~/.gitconfig.local must
#     carry a Linux-appropriate credential helper — the gh CLI when installed
#     (scoped to github.com, like `gh auth setup-git`), libsecret as a fallback —
#     or unattended HTTPS git (e.g. `bd dolt push`, cron pulls of private repos)
#     fails with "could not read Username for 'https://github.com'".
#   - Platform guard (issue #179): the macOS script must refuse to run on Linux
#     and vice versa; a mislabeled ~/.gitconfig.local is how the Ubuntu server
#     ended up with credential.helper = osxkeychain.
#
# These tests run the real script in a mktemp sandbox with HOME and git config
# redirected, so they never touch the developer's machine. Helper detection is
# controlled through the GITCONFIG_GH_BIN / GITCONFIG_LIBSECRET_BIN seams (empty
# string = "not installed"), so results don't depend on what the host has.
#
# Run with:  bats tests/shared/linux-initialize-local-config.bats
# Requires:  bats-core and git.

# `run ! cmd` (used for the negated-grep assertions below) needs bats >= 1.5 to
# parse the `!` as a "must fail" status check. A bare `! grep ...` is exempt from
# bats' errexit/ERR-trap machinery, so a mid-test one whose condition is violated
# is silently swallowed — only a terminal `!` fails the test (issue #182). The
# pragma also silences the BW02 warning that `run`'s flag syntax emits otherwise.
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/linux version/initialize-local-config.sh"

    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
    export GIT_CONFIG_SYSTEM="$SANDBOX/no-system-config"
    # The script refuses to run on a macOS host (issue #179); the sandbox makes
    # cross-OS runs safe, so opt out of the guard for every test.
    export GITCONFIG_ALLOW_CROSS_OS=1
    : > "$GIT_CONFIG_GLOBAL"
}

teardown() {
    rm -rf "$SANDBOX"
}

# Make a fake gh binary inside the sandbox so assertions have a stable path.
make_fake_gh() {
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
}

@test "emits a github.com-scoped gh credential helper when gh is installed" {
    make_fake_gh

    run env GITCONFIG_GH_BIN="$SANDBOX/bin/gh" GITCONFIG_LIBSECRET_BIN="" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # The block parses as valid git config: an empty reset entry followed by
    # the gh helper, for both github.com and gist.github.com.
    local helpers
    helpers="$(git config --file "$SANDBOX/.gitconfig.local" \
        --get-all 'credential.https://github.com.helper')"
    [ "$(head -n1 <<< "$helpers")" = "" ]
    grep -qFx "!$SANDBOX/bin/gh auth git-credential" <<< "$helpers"

    git config --file "$SANDBOX/.gitconfig.local" \
        --get-all 'credential.https://gist.github.com.helper' \
        | grep -qFx "!$SANDBOX/bin/gh auth git-credential"
}

@test "falls back to libsecret when gh is absent" {
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git-credential-libsecret"
    chmod +x "$SANDBOX/bin/git-credential-libsecret"

    run env GITCONFIG_GH_BIN="" GITCONFIG_LIBSECRET_BIN="$SANDBOX/bin/git-credential-libsecret" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    [ "$(git config --file "$SANDBOX/.gitconfig.local" credential.helper)" = \
        "$SANDBOX/bin/git-credential-libsecret" ]
    # gh-specific scoped sections are absent.
    run ! grep -qF 'credential "https://github.com"' "$SANDBOX/.gitconfig.local"
}

@test "prefers gh over libsecret when both are installed" {
    make_fake_gh
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git-credential-libsecret"
    chmod +x "$SANDBOX/bin/git-credential-libsecret"

    run env GITCONFIG_GH_BIN="$SANDBOX/bin/gh" \
        GITCONFIG_LIBSECRET_BIN="$SANDBOX/bin/git-credential-libsecret" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    grep -qF "helper = !$SANDBOX/bin/gh auth git-credential" "$SANDBOX/.gitconfig.local"
    run ! grep -qF 'git-credential-libsecret' "$SANDBOX/.gitconfig.local"
}

@test "leaves a commented hint when no credential helper is available" {
    run env GITCONFIG_GH_BIN="" GITCONFIG_LIBSECRET_BIN="" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # No active helper anywhere in the generated file. Exactly 1 = clean
    # no-match; 128 would mean the file itself failed to parse.
    run git config --file "$SANDBOX/.gitconfig.local" --get-regexp '^credential\.'
    [ "$status" -eq 1 ]
    # The file as a whole still parses (this branch's output is not otherwise
    # value-checked through git, so parse-validate it explicitly)...
    git config --file "$SANDBOX/.gitconfig.local" --list
    # ...and the how-to-enable hint is present.
    grep -qF '# Uncomment to enable HTTPS auth via the GitHub CLI' "$HOME/.gitconfig.local"
}

@test "never emits the macOS osxkeychain helper" {
    make_fake_gh

    run env GITCONFIG_GH_BIN="$SANDBOX/bin/gh" GITCONFIG_LIBSECRET_BIN="" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    run ! grep -qF 'osxkeychain' "$SANDBOX/.gitconfig.local"
}

@test "always includes the core excludesfile and safe directory" {
    run env GITCONFIG_GH_BIN="" GITCONFIG_LIBSECRET_BIN="" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    grep -qF 'excludesfile = ' "$SANDBOX/.gitconfig.local"
    grep -qF '[safe]' "$SANDBOX/.gitconfig.local"
}

@test "still emits file-based signing config alongside the credential block" {
    mkdir -p "$SANDBOX/.ssh"
    echo "fake private key" > "$SANDBOX/.ssh/id_ed25519_signing"
    echo "ssh-ed25519 AAAALINUXKEY comment" > "$SANDBOX/.ssh/id_ed25519_signing.pub"
    git config --global user.email "dev@example.com"
    make_fake_gh

    run env GITCONFIG_GH_BIN="$SANDBOX/bin/gh" GITCONFIG_LIBSECRET_BIN="" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    [ "$(git config --file "$SANDBOX/.gitconfig.local" user.signingkey)" = \
        "$SANDBOX/.ssh/id_ed25519_signing" ]
    [ "$(git config --file "$SANDBOX/.gitconfig.local" commit.gpgsign)" = "true" ]
    grep -qF "helper = !$SANDBOX/bin/gh auth git-credential" "$SANDBOX/.gitconfig.local"
}

@test "refuses to run on a macOS host without the cross-OS override" {
    # Stub uname so the guard sees Darwin regardless of the real host.
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\necho Darwin\n' > "$SANDBOX/bin/uname"
    chmod +x "$SANDBOX/bin/uname"

    run env -u GITCONFIG_ALLOW_CROSS_OS PATH="$SANDBOX/bin:$PATH" \
        bash "$SCRIPT" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"Linux script"* ]]
    # Nothing was written: the guard fires before any config generation.
    [ ! -f "$SANDBOX/.gitconfig.local" ]
}
