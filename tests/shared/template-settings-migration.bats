#!/usr/bin/env bats
#
# Bats suite for the move of user.signingkey, commit.gpgsign and core.editor
# out of .gitconfig.template into ~/.gitconfig.local (issue #231).
#
# An installed machine auto-updates with scripts/shared/update-gitconfig.sh:
# it pulls the repo and regenerates ~/.gitconfig from the template, but never
# regenerates ~/.gitconfig.local. These tests install ~/.gitconfig from an
# old-style template (literal signing key, gpgsign, editor), push the current
# template, run the updater, and check that the machine still ends up with a
# signing key, gpgsign and an editor, whatever its ~/.gitconfig.local held.
#
# Run with:  bats tests/shared/template-settings-migration.bats
# Requires:  bats-core (https://github.com/bats-core/bats-core) and git.

bats_require_minimum_version 1.5.0

OLD_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY"

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    UPDATER="$REPO_ROOT/scripts/shared/update-gitconfig.sh"

    TESTDIR="$(mktemp -d)"
    export HOME="$TESTDIR/home"
    mkdir -p "$HOME"
    # Never read or write the developer's git config. The repos below commit
    # with this config; the machine under test is $HOME/.gitconfig.
    export GIT_CONFIG_GLOBAL="$TESTDIR/gitconfig-global"
    export GIT_CONFIG_SYSTEM="$TESTDIR/no-system-config"
    printf '[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

    REMOTE="$TESTDIR/remote.git"
    REPO="$TESTDIR/repo"
    DEV="$TESTDIR/dev"
    git init -q --bare -b main "$REMOTE"
    git clone -q "$REMOTE" "$REPO" 2>/dev/null
    # The template as it was before #231: signing key, gpgsign and editor set
    # for every machine, with ~/.gitconfig.local included last.
    cat > "$REPO/.gitconfig.template" <<EOF
[user]
	name = Test
	email = test@example.com
	signingkey = $OLD_KEY
[gpg]
	format = ssh
[commit]
	gpgsign = true
[alias]
	h = !echo '{{REPO_PATH}}'
[core]
	editor = code --wait
[include]
	path = ~/.gitconfig.local
EOF
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "old template"
    git -C "$REPO" push -q -u origin main
    git clone -q "$REMOTE" "$DEV" 2>/dev/null
}

teardown() {
    rm -rf "$TESTDIR"
}

# Install ~/.gitconfig from the old template, as an existing machine has it.
install_old() {
    bash -c 'source "$1/scripts/shared/functions.sh"; generate_gitconfig "$2" "$HOME" true' _ \
        "$REPO_ROOT" "$REPO" > /dev/null
    grep -qF "signingkey = $OLD_KEY" "$HOME/.gitconfig"
}

# Publish the current template, as a merge to main does.
push_new_template() {
    cp "$REPO_ROOT/.gitconfig.template" "$DEV/.gitconfig.template"
    git -C "$DEV" add -A
    git -C "$DEV" commit -q -m "new template"
    git -C "$DEV" push -q origin main
}

# What git uses on this machine: ~/.gitconfig with its includes.
effective() {
    git config --file "$HOME/.gitconfig" --includes --get "$1"
}

auto_update() {
    run bash "$UPDATER" "$REPO"
}

@test "the template no longer sets signingkey, gpgsign or editor" {
    run ! git config --file "$REPO_ROOT/.gitconfig.template" --get user.signingkey
    run ! git config --file "$REPO_ROOT/.gitconfig.template" --get commit.gpgsign
    run ! git config --file "$REPO_ROOT/.gitconfig.template" --get core.editor
    # Local values must still win: the include stays the template's last line.
    [ "$(grep -v '^[[:space:]]*\(#\|$\)' "$REPO_ROOT/.gitconfig.template" | tail -1)" = $'\tpath = ~/.gitconfig.local' ]
}

@test "server-like: a file key in ~/.gitconfig.local keeps signing; the editor moves" {
    printf '[user]\n\tsigningKey = %s/.ssh/id_ed25519_signing\n[commit]\n\tgpgsign = true\n' "$HOME" > "$HOME/.gitconfig.local"
    install_old
    push_new_template

    auto_update
    [ "$status" -eq 0 ]
    run ! grep -q signingkey "$HOME/.gitconfig"
    [ "$(effective user.signingkey)" = "$HOME/.ssh/id_ed25519_signing" ]
    [ "$(effective commit.gpgsign)" = true ]
    [ "$(effective core.editor)" = "code --wait" ]
}

@test "mac-like: a local key without gpgsign gets gpgsign carried over" {
    printf '[user]\n\tsigningkey = ~/.ssh/claude_desktop.pub\n' > "$HOME/.gitconfig.local"
    install_old
    push_new_template

    auto_update
    [ "$status" -eq 0 ]
    [ "$(effective user.signingkey)" = "~/.ssh/claude_desktop.pub" ]
    [ "$(effective commit.gpgsign)" = true ]
    [ "$(effective core.editor)" = "code --wait" ]
}

@test "agent-signing machine: the template's key moves into ~/.gitconfig.local" {
    printf '[gpg "ssh"]\n\tprogram = /opt/1Password/op-ssh-sign\n' > "$HOME/.gitconfig.local"
    install_old
    push_new_template

    auto_update
    [ "$status" -eq 0 ]
    [ "$(effective user.signingkey)" = "$OLD_KEY" ]
    [ "$(effective commit.gpgsign)" = true ]
    [ "$(effective core.editor)" = "code --wait" ]
    [ "$(effective gpg.ssh.program)" = /opt/1Password/op-ssh-sign ]
}

@test "no ~/.gitconfig.local: it is created with the three settings" {
    install_old
    push_new_template

    auto_update
    [ "$status" -eq 0 ]
    [ -f "$HOME/.gitconfig.local" ]
    [ "$(effective user.signingkey)" = "$OLD_KEY" ]
    [ "$(effective commit.gpgsign)" = true ]
    [ "$(effective core.editor)" = "code --wait" ]
}

@test "local values are left alone and still win" {
    printf '[core]\n\teditor = vim\n[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig.local"
    install_old
    push_new_template

    auto_update
    [ "$status" -eq 0 ]
    [ "$(effective core.editor)" = vim ]
    [ "$(effective commit.gpgsign)" = false ]
    [ "$(git config --file "$HOME/.gitconfig.local" --get-all core.editor)" = vim ]
}

@test "a second update changes nothing and adds no duplicates" {
    install_old
    push_new_template
    auto_update
    [ "$status" -eq 0 ]
    before="$(cat "$HOME/.gitconfig.local")"

    auto_update
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.gitconfig.local")" = "$before" ]
    [ "$(git config --file "$HOME/.gitconfig.local" --get-all user.signingkey | wc -l)" -eq 1 ]
    [ "$(git config --file "$HOME/.gitconfig.local" --get-all core.editor | wc -l)" -eq 1 ]
}

@test "if ~/.gitconfig.local can't be written, ~/.gitconfig is left as it was" {
    printf '[gpg "ssh"]\n\tprogram = /opt/1Password/op-ssh-sign\n' > "$HOME/.gitconfig.local"
    install_old
    push_new_template
    cp "$HOME/.gitconfig" "$TESTDIR/before"
    # A stale lock makes every `git config --file` write to it fail.
    : > "$HOME/.gitconfig.local.lock"

    auto_update
    [ "$status" -eq 1 ]
    cmp "$HOME/.gitconfig" "$TESTDIR/before"
    grep -qF "ERROR: could not converge ~/.gitconfig from template" "$REPO/docs/update-gitconfig.log"

    # Once the lock is gone the next run completes the move.
    rm "$HOME/.gitconfig.local.lock"
    auto_update
    [ "$status" -eq 0 ]
    [ "$(effective user.signingkey)" = "$OLD_KEY" ]
    [ "$(effective commit.gpgsign)" = true ]
}

@test "an unreadable ~/.gitconfig.local stops the rewrite" {
    install_old
    push_new_template
    cp "$HOME/.gitconfig" "$TESTDIR/before"
    printf '[broken\n' > "$HOME/.gitconfig.local"

    auto_update
    [ "$status" -eq 1 ]
    cmp "$HOME/.gitconfig" "$TESTDIR/before"
}

# --- migrate_template_settings_to_local, directly -----------------------------

migrate() {
    run bash -c 'source "$1/scripts/shared/functions.sh"; migrate_template_settings_to_local "$2" "$3" "$4"' _ \
        "$REPO_ROOT" "$1" "$2" "$HOME/.gitconfig.local"
}

@test "gpgsign is not carried over without a signing key" {
    printf '[commit]\n\tgpgsign = true\n[core]\n\teditor = nano\n' > "$TESTDIR/old"
    migrate "$TESTDIR/old" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"no signing key is configured"* ]]
    run ! git config --file "$HOME/.gitconfig.local" --get commit.gpgsign
    [ "$(git config --file "$HOME/.gitconfig.local" --get core.editor)" = nano ]
}

@test "gpgsign off is not carried over" {
    printf '[user]\n\tsigningkey = %s\n[commit]\n\tgpgsign = no\n' "$OLD_KEY" > "$TESTDIR/old"
    migrate "$TESTDIR/old" ""
    [ "$status" -eq 0 ]
    run ! git config --file "$HOME/.gitconfig.local" --get commit.gpgsign
}

@test "a key the new template still sets is not copied" {
    printf '[core]\n\teditor = nano\n' > "$TESTDIR/old"
    migrate "$TESTDIR/old" $'[core]\n\teditor = emacs'
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.gitconfig.local" ]
}

@test "a key set through an include in ~/.gitconfig.local counts as set" {
    printf '[core]\n\teditor = nano\n' > "$TESTDIR/old"
    printf '[core]\n\teditor = vim\n' > "$HOME/extra.cfg"
    printf '[include]\n\tpath = extra.cfg\n' > "$HOME/.gitconfig.local"
    migrate "$TESTDIR/old" ""
    [ "$status" -eq 0 ]
    run ! git config --file "$HOME/.gitconfig.local" --get core.editor
}

@test "the dropped-settings warning leaves out what ~/.gitconfig.local sets" {
    printf '[core]\n\teditor = nano\n[foo]\n\tbar = 1\n' > "$TESTDIR/old"
    printf '[core]\n\teditor = nano\n' > "$HOME/.gitconfig.local"
    run bash -c 'source "$1/scripts/shared/functions.sh"; warn_dropped_gitconfig_keys "$2" "" "$3"' _ \
        "$REPO_ROOT" "$TESTDIR/old" "$HOME/.gitconfig.local"
    [ "$status" -eq 0 ]
    [[ "$output" == *"foo.bar"* ]]
    [[ "$output" != *"core.editor"* ]]
}
