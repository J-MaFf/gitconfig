#!/usr/bin/env bats
#
# Bats suite for scripts/mac version/initialize-local-config.sh, covering:
#   - allowedSignersFile behavior (issue #116): on macOS, allowedSignersFile must
#     be written whenever signing is enabled — not only when 1Password's
#     op-ssh-sign is installed. Otherwise `git log --show-signature` reports
#     "No signature" for a file-based or literal signing key.
#   - Homebrew safe.directory (issue #169): on a shared Mac where /opt/homebrew
#     is owned by another account, the generated [safe] section must trust it
#     or `brew update` fails with "fatal: not in a git directory".
#
# These tests run the real script in a mktemp sandbox with HOME and git config
# redirected, so they never touch the developer's machine. op-ssh-sign is not on
# the sandbox's fixed lookup paths (/opt/homebrew/bin, /usr/local/bin), so the
# "no 1Password" branches are exercised naturally.
#
# Run with:  bats tests/shared/mac-initialize-local-config.bats
# Requires:  bats-core and git.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/mac version/initialize-local-config.sh"

    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
    export GIT_CONFIG_SYSTEM="$SANDBOX/no-system-config"
    : > "$GIT_CONFIG_GLOBAL"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "writes allowedSignersFile when a literal signing key is configured (no 1Password)" {
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "ssh-ed25519 AAAALITERALKEY dev-comment"
    git config --global commit.gpgsign true

    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # The whole point of #116: the [gpg "ssh"] allowedSignersFile block is present.
    grep -qF 'allowedSignersFile = ' "$SANDBOX/.gitconfig.local"
    grep -qF '[gpg "ssh"]' "$SANDBOX/.gitconfig.local"
    # And the signing identity was registered for local verification.
    [ -f "$SANDBOX/.ssh/allowed_signers" ]
    grep -qF 'dev@example.com namespaces="git" ssh-ed25519 AAAALITERALKEY' "$SANDBOX/.ssh/allowed_signers"
}

@test "writes allowedSignersFile when a file-based signing key is configured (no 1Password)" {
    mkdir -p "$SANDBOX/.ssh"
    local keyfile="$SANDBOX/.ssh/id_ed25519_signing"
    echo "ssh-ed25519 AAAAFILEKEY host-comment" > "$keyfile.pub"
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "$keyfile"
    git config --global commit.gpgsign true

    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    grep -qF 'allowedSignersFile = ' "$SANDBOX/.gitconfig.local"
    grep -qF 'dev@example.com namespaces="git" ssh-ed25519 AAAAFILEKEY' "$SANDBOX/.ssh/allowed_signers"
}

@test "skips signing config when no key is configured and 1Password is absent" {
    git config --global user.email "dev@example.com"   # email only, no signingkey

    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # No active signing block, no allowed_signers file — unchanged prior behavior.
    ! grep -qF 'allowedSignersFile = ' "$SANDBOX/.gitconfig.local"
    [ ! -f "$SANDBOX/.ssh/allowed_signers" ]
    # The commented "how to enable" hint is still shown.
    grep -qF '# Uncomment and set program path' "$SANDBOX/.gitconfig.local"
}

@test "always includes the core excludesfile and safe directory regardless of signing" {
    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    grep -qF 'excludesfile = ' "$SANDBOX/.gitconfig.local"
    grep -qF '[safe]' "$SANDBOX/.gitconfig.local"
}

@test "adds the Homebrew repo as a safe directory when it is owned by another user" {
    mkdir -p "$SANDBOX/homebrew/.git"
    # A non-root sandbox can't create a dir owned by someone else, so stub
    # `id -u` to report a different uid instead — the same mismatch the script
    # sees when /opt/homebrew belongs to another account.
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\necho 999999\n' > "$SANDBOX/bin/id"
    chmod +x "$SANDBOX/bin/id"

    run env PATH="$SANDBOX/bin:$PATH" HOMEBREW_REPO="$SANDBOX/homebrew" \
        bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # The entry is present and the file still parses as valid git config.
    git config --file "$SANDBOX/.gitconfig.local" --get-all safe.directory \
        | grep -qFx "$SANDBOX/homebrew"
}

@test "omits the Homebrew safe directory when the repo is owned by the current user" {
    mkdir -p "$SANDBOX/homebrew/.git"

    run env HOMEBREW_REPO="$SANDBOX/homebrew" bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    ! grep -qF "directory = $SANDBOX/homebrew" "$SANDBOX/.gitconfig.local"
}

@test "omits the Homebrew safe directory when no Homebrew repo exists" {
    run env HOMEBREW_REPO="$SANDBOX/no-such-brew" bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    ! grep -qF 'no-such-brew' "$SANDBOX/.gitconfig.local"
}
