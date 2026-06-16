#!/usr/bin/env bats
#
# Bats suite for scripts/shared/functions.sh — the bash utilities sourced by
# the mac and linux gitconfig scripts. Complements the Windows-only Pester
# suite so regressions on the primary dev platforms are caught.
#
# Run with:  bats tests/shared/functions.bats
# Requires:  bats-core (https://github.com/bats-core/bats-core) and git.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=../../scripts/shared/functions.sh
    source "$REPO_ROOT/scripts/shared/functions.sh"

    TESTDIR="$(mktemp -d)"
    HOME_DIR="$TESTDIR/home"
    mkdir -p "$HOME_DIR"

    # Isolate git config so update_allowed_signers reads only what we seed and
    # never touches the developer's real ~/.gitconfig.
    export GIT_CONFIG_GLOBAL="$TESTDIR/gitconfig-global"
    export GIT_CONFIG_SYSTEM="$TESTDIR/no-system-config"
    : > "$GIT_CONFIG_GLOBAL"
}

teardown() {
    rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# backup_file
# ---------------------------------------------------------------------------

@test "backup_file moves an existing file to Existing.<name>.bak" {
    echo "original" > "$TESTDIR/.gitconfig"
    run backup_file "$TESTDIR/.gitconfig"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTDIR/.gitconfig" ]
    [ -f "$TESTDIR/Existing..gitconfig.bak" ]
    [ "$(cat "$TESTDIR/Existing..gitconfig.bak")" = "original" ]
}

@test "backup_file returns 1 and skips when the target is missing" {
    run backup_file "$TESTDIR/does-not-exist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[SKIP]"* ]]
}

@test "backup_file overwrites a stale backup instead of failing" {
    echo "stale" > "$TESTDIR/Existing.file.bak"
    echo "fresh" > "$TESTDIR/file"
    run backup_file "$TESTDIR/file"
    [ "$status" -eq 0 ]
    [ "$(cat "$TESTDIR/Existing.file.bak")" = "fresh" ]
}

# ---------------------------------------------------------------------------
# create_symlink
# ---------------------------------------------------------------------------

@test "create_symlink links source to destination" {
    echo "src" > "$TESTDIR/source"
    run create_symlink "$TESTDIR/source" "$TESTDIR/link" true
    [ "$status" -eq 0 ]
    [ -L "$TESTDIR/link" ]
    [ "$(cat "$TESTDIR/link")" = "src" ]
}

@test "create_symlink errors when the source is missing" {
    run create_symlink "$TESTDIR/missing" "$TESTDIR/link" true
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
    [ ! -e "$TESTDIR/link" ]
}

@test "create_symlink backs up an existing destination with force=true" {
    echo "src" > "$TESTDIR/source"
    echo "old" > "$TESTDIR/link"
    run create_symlink "$TESTDIR/source" "$TESTDIR/link" true
    [ "$status" -eq 0 ]
    [ -L "$TESTDIR/link" ]
    [ -f "$TESTDIR/Existing.link.bak" ]
    [ "$(cat "$TESTDIR/Existing.link.bak")" = "old" ]
}

# ---------------------------------------------------------------------------
# update_allowed_signers  (the helper behind issue #116)
# ---------------------------------------------------------------------------

@test "update_allowed_signers writes the signing identity for a literal key" {
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "ssh-ed25519 AAAATESTKEY a-comment"
    local signers="$HOME_DIR/.ssh/allowed_signers"

    run update_allowed_signers "$signers"
    [ "$status" -eq 0 ]
    [ -f "$signers" ]
    # Email + git namespace + normalized "<type> <base64>" (comment dropped).
    grep -qF 'dev@example.com namespaces="git" ssh-ed25519 AAAATESTKEY' "$signers"
    ! grep -q 'a-comment' "$signers"
}

@test "update_allowed_signers is idempotent (no duplicate lines)" {
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "ssh-ed25519 AAAATESTKEY a-comment"
    local signers="$HOME_DIR/.ssh/allowed_signers"

    update_allowed_signers "$signers"
    update_allowed_signers "$signers"
    [ "$(grep -c 'dev@example.com' "$signers")" -eq 1 ]
}

@test "update_allowed_signers resolves a file-based key from its .pub file" {
    local keyfile="$HOME_DIR/.ssh/id_ed25519_signing"
    mkdir -p "$HOME_DIR/.ssh"
    echo "ssh-ed25519 AAAAFILEKEY host-comment" > "$keyfile.pub"
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "$keyfile"
    local signers="$HOME_DIR/.ssh/allowed_signers"

    run update_allowed_signers "$signers"
    [ "$status" -eq 0 ]
    grep -qF 'dev@example.com namespaces="git" ssh-ed25519 AAAAFILEKEY' "$signers"
}

@test "update_allowed_signers skips gracefully when no signing key is set" {
    git config --global user.email "dev@example.com"
    local signers="$HOME_DIR/.ssh/allowed_signers"

    run update_allowed_signers "$signers"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [ ! -f "$signers" ]
}

@test "update_allowed_signers preserves other identities already present" {
    mkdir -p "$HOME_DIR/.ssh"
    local signers="$HOME_DIR/.ssh/allowed_signers"
    echo 'other@example.com namespaces="git" ssh-ed25519 AAAAOTHER' > "$signers"
    git config --global user.email "dev@example.com"
    git config --global user.signingkey "ssh-ed25519 AAAATESTKEY a-comment"

    run update_allowed_signers "$signers"
    [ "$status" -eq 0 ]
    grep -qF 'other@example.com' "$signers"
    grep -qF 'dev@example.com' "$signers"
}

# ---------------------------------------------------------------------------
# generate_gitconfig
# ---------------------------------------------------------------------------

@test "generate_gitconfig substitutes placeholders and writes output" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[core]\n\trepo = {{REPO_PATH}}\n\thome = {{HOME_DIR}}\n' > "$repo/.gitconfig.template"

    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [ -f "$HOME_DIR/.gitconfig" ]
    grep -qF "repo = $repo" "$HOME_DIR/.gitconfig"
    grep -qF "home = $HOME_DIR" "$HOME_DIR/.gitconfig"
    ! grep -q '{{' "$HOME_DIR/.gitconfig"
}

@test "generate_gitconfig errors when the template is missing" {
    local repo="$TESTDIR/repo-no-template"
    mkdir -p "$repo"
    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
}

@test "generate_gitconfig backs up an existing config when forced" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[core]\n\trepo = {{REPO_PATH}}\n' > "$repo/.gitconfig.template"
    echo "prior" > "$HOME_DIR/.gitconfig"

    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [ -f "$HOME_DIR/.gitconfig.bak" ]
    [ "$(cat "$HOME_DIR/.gitconfig.bak")" = "prior" ]
}

# ---------------------------------------------------------------------------
# enable_git_alias_widget / disable_git_alias_widget
# ---------------------------------------------------------------------------

@test "enable_git_alias_widget adds a guarded marker block to an existing rc" {
    : > "$HOME_DIR/.bashrc"
    : > "$HOME_DIR/.zshrc"
    run enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    [ "$status" -eq 0 ]
    grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc"
    grep -qF "$GIT_ALIAS_WIDGET_END" "$HOME_DIR/.bashrc"
    grep -qF "git-alias-widget.bash" "$HOME_DIR/.bashrc"
}

@test "enable_git_alias_widget is idempotent (single marker block)" {
    : > "$HOME_DIR/.bashrc"
    enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    [ "$(grep -cF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc")" -eq 1 ]
}

@test "disable_git_alias_widget removes the marker block it added" {
    : > "$HOME_DIR/.bashrc"
    enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    run disable_git_alias_widget "$HOME_DIR"
    [ "$status" -eq 0 ]
    ! grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc"
    ! grep -qF "$GIT_ALIAS_WIDGET_END" "$HOME_DIR/.bashrc"
}

@test "disable_git_alias_widget preserves surrounding rc content" {
    printf 'export FOO=1\n' > "$HOME_DIR/.bashrc"
    enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    printf 'export BAR=2\n' >> "$HOME_DIR/.bashrc"
    disable_git_alias_widget "$HOME_DIR"
    grep -qF 'export FOO=1' "$HOME_DIR/.bashrc"
    grep -qF 'export BAR=2' "$HOME_DIR/.bashrc"
    ! grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc"
}
