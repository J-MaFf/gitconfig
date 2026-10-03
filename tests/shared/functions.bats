#!/usr/bin/env bats
#
# Bats suite for scripts/shared/functions.sh — the bash utilities sourced by
# the mac and linux gitconfig scripts. Complements the Windows-only Pester
# suite so regressions on the primary dev platforms are caught.
#
# Run with:  bats tests/shared/functions.bats
# Requires:  bats-core (https://github.com/bats-core/bats-core) and git.

# `run ! cmd` (used for the negated-grep assertions below) needs bats >= 1.5 to
# parse the `!` as a "must fail" status check. A bare `! grep ...` is exempt from
# bats' errexit/ERR-trap machinery, so a mid-test one whose condition is violated
# is silently swallowed — only a terminal `!` fails the test (issue #182). The
# pragma also silences the BW02 warning that `run`'s flag syntax emits otherwise.
bats_require_minimum_version 1.5.0

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

# The timestamped backups of FILE, oldest first (one per line).
backups_of() {
    local f
    for f in "$1".bak.[0-9]*; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "$f"; fi
    done | LC_ALL=C sort
}

@test "backup_file moves an existing file to a timestamped <name>.bak.<stamp>" {
    echo "original" > "$TESTDIR/.gitconfig"
    run backup_file "$TESTDIR/.gitconfig"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTDIR/.gitconfig" ]
    [ "$(backups_of "$TESTDIR/.gitconfig" | wc -l | tr -d ' ')" -eq 1 ]
    local backup
    backup="$(backups_of "$TESTDIR/.gitconfig")"
    [[ "$(basename "$backup")" =~ ^\.gitconfig\.bak\.[0-9]{8}-[0-9]{6}$ ]]
    [ "$(cat "$backup")" = "original" ]
}

@test "backup_file returns 1 and skips when the target is missing" {
    run backup_file "$TESTDIR/does-not-exist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[SKIP]"* ]]
}

@test "backup_file never overwrites an earlier backup (finding 1)" {
    echo "original" > "$TESTDIR/file"
    backup_file "$TESTDIR/file" >/dev/null
    echo "generated" > "$TESTDIR/file"
    backup_file "$TESTDIR/file" >/dev/null
    # Both backups exist, even within the same second, and the user's original
    # is the oldest one.
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(cat "$(backups_of "$TESTDIR/file" | head -n 1)")" = "original" ]
    [ "$(cat "$(backups_of "$TESTDIR/file" | tail -n 1)")" = "generated" ]
}

@test "backup_file leaves legacy Existing.<name>.bak backups alone" {
    echo "legacy" > "$TESTDIR/Existing.file.bak"
    echo "fresh" > "$TESTDIR/file"
    run backup_file "$TESTDIR/file"
    [ "$status" -eq 0 ]
    [ "$(cat "$TESTDIR/Existing.file.bak")" = "legacy" ]
}

@test "backup_file removes a symlink into the repo without backing it up" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    echo "ours" > "$repo/.gitignore_global"
    ln -s "$repo/.gitignore_global" "$TESTDIR/.gitignore_global"
    run backup_file "$TESTDIR/.gitignore_global" "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no backup needed"* ]]
    [ ! -e "$TESTDIR/.gitignore_global" ] && [ ! -L "$TESTDIR/.gitignore_global" ]
    [ -z "$(backups_of "$TESTDIR/.gitignore_global")" ]
    [ "$(cat "$repo/.gitignore_global")" = "ours" ]
}

@test "backup_file still backs up a symlink that points outside the repo" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    echo "theirs" > "$TESTDIR/elsewhere"
    ln -s "$TESTDIR/elsewhere" "$TESTDIR/.gitignore_global"
    run backup_file "$TESTDIR/.gitignore_global" "$repo"
    [ "$status" -eq 0 ]
    [ "$(backups_of "$TESTDIR/.gitignore_global" | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# prune_backups (retention)
# ---------------------------------------------------------------------------

@test "prune_backups keeps the newest 5 by default" {
    local i
    for i in 1 2 3 4 5 6 7; do
        echo "v$i" > "$TESTDIR/file.bak.2026010$i-120000"
    done
    unset GITCONFIG_BACKUP_KEEP
    prune_backups "$TESTDIR/file"
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 5 ]
    [ ! -e "$TESTDIR/file.bak.20260101-120000" ]
    [ ! -e "$TESTDIR/file.bak.20260102-120000" ]
    [ -e "$TESTDIR/file.bak.20260107-120000" ]
}

@test "prune_backups honours GITCONFIG_BACKUP_KEEP, and 0 keeps everything" {
    local i
    for i in 1 2 3 4; do
        echo "v$i" > "$TESTDIR/file.bak.2026010$i-120000"
    done
    GITCONFIG_BACKUP_KEEP=0 prune_backups "$TESTDIR/file"
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 4 ]
    GITCONFIG_BACKUP_KEEP=2 prune_backups "$TESTDIR/file"
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 2 ]
    [ -e "$TESTDIR/file.bak.20260104-120000" ]
}

@test "prune_backups never deletes other files or legacy backups" {
    local i
    for i in 1 2 3; do
        echo "v$i" > "$TESTDIR/file.bak.2026010$i-120000"
    done
    echo "legacy" > "$TESTDIR/Existing.file.bak"
    echo "legacy" > "$TESTDIR/file.bak"
    echo "note" > "$TESTDIR/file.bak.notes"
    GITCONFIG_BACKUP_KEEP=1 prune_backups "$TESTDIR/file"
    [ -e "$TESTDIR/Existing.file.bak" ]
    [ -e "$TESTDIR/file.bak" ]
    [ -e "$TESTDIR/file.bak.notes" ]
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a same-second collision sorts after the first backup" {
    echo "a" > "$TESTDIR/file"
    backup_copy "$TESTDIR/file" >/dev/null
    echo "b" > "$TESTDIR/file"
    backup_copy "$TESTDIR/file" >/dev/null
    echo "c" > "$TESTDIR/file"
    backup_copy "$TESTDIR/file" >/dev/null
    [ "$(backups_of "$TESTDIR/file" | wc -l | tr -d ' ')" -eq 3 ]
    [ "$(backups_of "$TESTDIR/file" | while IFS= read -r f; do cat "$f"; done | tr -d '\n')" = "abc" ]
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
    [ "$(backups_of "$TESTDIR/link" | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(cat "$(backups_of "$TESTDIR/link")")" = "old" ]
}

@test "create_symlink leaves an already-correct link alone, with no backup" {
    mkdir -p "$TESTDIR/repo"
    echo "src" > "$TESTDIR/repo/source"
    ln -s "$TESTDIR/repo/source" "$HOME_DIR/link"
    run create_symlink "$TESTDIR/repo/source" "$HOME_DIR/link" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"already linked"* ]]
    [ -L "$HOME_DIR/link" ]
    [ -z "$(backups_of "$HOME_DIR/link")" ]
}

@test "create_symlink replaces a stale link into the repo without a backup or prompt" {
    mkdir -p "$TESTDIR/repo/old"
    echo "src" > "$TESTDIR/repo/source"
    echo "stale" > "$TESTDIR/repo/old/source"
    ln -s "$TESTDIR/repo/old/source" "$HOME_DIR/link"
    # force=false and no stdin: a prompt would read EOF and skip.
    run create_symlink "$TESTDIR/repo/source" "$HOME_DIR/link" false "$TESTDIR/repo" < /dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME_DIR/link")" = "src" ]
    [ -z "$(backups_of "$HOME_DIR/link")" ]
}

# ---------------------------------------------------------------------------
# file_owner_uid  (the helper behind issue #169)
# ---------------------------------------------------------------------------

@test "file_owner_uid prints the owning uid of a path" {
    run file_owner_uid "$TESTDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "$(id -u)" ]
}

@test "file_owner_uid fails silently for a missing path" {
    run file_owner_uid "$TESTDIR/does-not-exist"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
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
    run ! grep -q 'a-comment' "$signers"
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
    run ! grep -q '{{' "$HOME_DIR/.gitconfig"
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
    [ "$(backups_of "$HOME_DIR/.gitconfig" | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(cat "$(backups_of "$HOME_DIR/.gitconfig")")" = "prior" ]
}

@test "generate_gitconfig keeps every earlier backup across regenerations" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[core]\n\trepo = {{REPO_PATH}}\n' > "$repo/.gitconfig.template"
    echo "hand-written" > "$HOME_DIR/.gitconfig"
    generate_gitconfig "$repo" "$HOME_DIR" true >/dev/null
    printf '[core]\n\tother = 1\n' > "$repo/.gitconfig.template"
    generate_gitconfig "$repo" "$HOME_DIR" true >/dev/null
    [ "$(backups_of "$HOME_DIR/.gitconfig" | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(cat "$(backups_of "$HOME_DIR/.gitconfig" | head -n 1)")" = "hand-written" ]
}

@test "generate_gitconfig names settings the rewrite drops, without their values" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[user]\n\tname = Tester\n' > "$repo/.gitconfig.template"
    printf '[user]\n\tname = Tester\n[filter "lfs"]\n\tclean = git-lfs clean -- %%f\n[credential "https://github.com"]\n\thelper = secret-helper-value\n' > "$HOME_DIR/.gitconfig"
    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"filter.lfs.clean"* ]]
    [[ "$output" == *"credential.https://github.com.helper"* ]]
    [[ "$output" == *".gitconfig.local"* ]]
    [[ "$output" != *"secret-helper-value"* ]]
    [[ "$output" != *"user.name"* ]]
}

@test "generate_gitconfig doesn't flag a value the template changed, but does flag a lost multi-value" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[alias]\n\tst = status\n[safe]\n\tdirectory = /a\n' > "$repo/.gitconfig.template"
    printf '[alias]\n\tst = status -sb\n[safe]\n\tdirectory = /a\n' > "$HOME_DIR/.gitconfig"
    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [[ "$output" != *"[WARN]"* ]]

    printf '[alias]\n\tst = status\n[safe]\n\tdirectory = /a\n\tdirectory = /b\n' > "$HOME_DIR/.gitconfig"
    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"* ]]
    [[ "$output" == *"safe.directory"* ]]
    [[ "$output" != *"alias.st"* ]]
}

@test "generate_gitconfig replaces a ~/.gitconfig symlink into the repo instead of writing through it" {
    local repo="$TESTDIR/repo"
    mkdir -p "$repo"
    printf '[core]\n\trepo = {{REPO_PATH}}\n' > "$repo/.gitconfig.template"
    echo "repo copy" > "$repo/.gitconfig"
    ln -s "$repo/.gitconfig" "$HOME_DIR/.gitconfig"
    run generate_gitconfig "$repo" "$HOME_DIR" true
    [ "$status" -eq 0 ]
    [ ! -L "$HOME_DIR/.gitconfig" ]
    grep -qF "repo = $repo" "$HOME_DIR/.gitconfig"
    [ "$(cat "$repo/.gitconfig")" = "repo copy" ]
    [ -z "$(backups_of "$HOME_DIR/.gitconfig")" ]
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
    run ! grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc"
    run ! grep -qF "$GIT_ALIAS_WIDGET_END" "$HOME_DIR/.bashrc"
}

@test "disable_git_alias_widget preserves surrounding rc content" {
    printf 'export FOO=1\n' > "$HOME_DIR/.bashrc"
    enable_git_alias_widget "$REPO_ROOT" "$HOME_DIR"
    printf 'export BAR=2\n' >> "$HOME_DIR/.bashrc"
    disable_git_alias_widget "$HOME_DIR"
    grep -qF 'export FOO=1' "$HOME_DIR/.bashrc"
    grep -qF 'export BAR=2' "$HOME_DIR/.bashrc"
    run ! grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$HOME_DIR/.bashrc"
}
