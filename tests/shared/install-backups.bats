#!/usr/bin/env bats
#
# End-to-end: running install.sh again must never lose the user's original
# files (audit finding 1). Runs the real mac and linux installers in a
# sandboxed $HOME, with Python, cron and launchd kept out of the way.
#
# Run with:  bats tests/shared/install-backups.bats
# Requires:  bats-core and git.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LINUX_INSTALL="$REPO_ROOT/scripts/linux version/install.sh"
    MAC_INSTALL="$REPO_ROOT/scripts/mac version/install.sh"

    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME" "$SANDBOX/bin"
    export GITCONFIG_ALLOW_CROSS_OS=1
    export GIT_CONFIG_SYSTEM="$SANDBOX/no-system-config"
    unset GIT_CONFIG_GLOBAL GITCONFIG_BACKUP_KEEP

    # Hide Python (no pip installs from a test) and any login-agent tooling.
    local stub
    for stub in py python python3 launchctl crontab; do
        printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/$stub"
        chmod +x "$SANDBOX/bin/$stub"
    done
    export PATH="$SANDBOX/bin:$PATH"

    # The user's hand-written originals.
    printf '[user]\n\tname = Original Gitconfig\n' > "$HOME/.gitconfig"
    printf 'ORIGINAL-GITIGNORE\n' > "$HOME/.gitignore_global"
    printf '[safe]\n\tdirectory = /original/local\n' > "$HOME/.gitconfig.local"
}

teardown() {
    rm -rf "$SANDBOX"
}

# The timestamped backups of FILE, oldest first.
backups_of() {
    local f
    for f in "$1".bak.[0-9]*; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "$f"; fi
    done | LC_ALL=C sort
}

# Succeed if some backup of FILE contains TEXT.
some_backup_has() {
    local f
    while IFS= read -r f; do
        grep -qF -- "$2" "$f" && return 0
    done < <(backups_of "$1")
    return 1
}

linux_install() { bash "$LINUX_INSTALL" --force --no-cron "$@"; }
mac_install() { bash "$MAC_INSTALL" --force --no-launchd "$@"; }

@test "installing twice keeps the backups of the original files (finding 1)" {
    run linux_install
    [ "$status" -eq 0 ]
    run linux_install
    [ "$status" -eq 0 ]

    some_backup_has "$HOME/.gitconfig" "Original Gitconfig"
    some_backup_has "$HOME/.gitignore_global" "ORIGINAL-GITIGNORE"
    some_backup_has "$HOME/.gitconfig.local" "/original/local"
    [ -L "$HOME/.gitignore_global" ]
}

@test "a re-run does not back up links that already point into the repo" {
    run linux_install
    [ "$status" -eq 0 ]
    [ "$(backups_of "$HOME/.gitignore_global" | wc -l | tr -d ' ')" -eq 1 ]
    [ -z "$(backups_of "$HOME/gitconfig_helper.py")" ]

    run linux_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"already linked"* ]]
    [ "$(backups_of "$HOME/.gitignore_global" | wc -l | tr -d ' ')" -eq 1 ]
    [ -z "$(backups_of "$HOME/gitconfig_helper.py")" ]
    # ~/.gitconfig already matches the template, so no new backup either.
    [ "$(backups_of "$HOME/.gitconfig" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "cleanup runs only with --reinstall" {
    run linux_install
    [ "$status" -eq 0 ]
    [[ "$output" != *"STEP 0"* ]]

    run linux_install --reinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"STEP 0"* ]]
    # The reinstall moved .gitconfig.local aside with a timestamped backup and
    # the original is still recoverable.
    some_backup_has "$HOME/.gitconfig.local" "/original/local"
    [ -f "$HOME/.gitconfig.local" ]
}

@test "repeated --reinstall runs keep the original (the old single slot lost it)" {
    run linux_install --reinstall
    [ "$status" -eq 0 ]
    run linux_install --reinstall
    [ "$status" -eq 0 ]
    run linux_install --reinstall
    [ "$status" -eq 0 ]
    some_backup_has "$HOME/.gitconfig" "Original Gitconfig"
    some_backup_has "$HOME/.gitconfig.local" "/original/local"
    some_backup_has "$HOME/.gitignore_global" "ORIGINAL-GITIGNORE"
}

@test "install leaves ~/.gitconfig identical to the template (no STEP 4 drift, finding 13)" {
    run linux_install
    [ "$status" -eq 0 ]
    [[ "$output" != *"STEP 4"* ]]
    # The login sync's convergence step is a no-op right after install.
    # shellcheck source=../../scripts/shared/functions.sh
    source "$REPO_ROOT/scripts/shared/functions.sh"
    run generate_gitconfig "$REPO_ROOT" "$HOME" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
    # The global gitignore still applies, via ~/.gitconfig.local.
    [ "$(git config --global --includes core.excludesfile)" = "$HOME/.gitignore_global" ]
}

@test "the retention limit applies to install backups" {
    local i
    for i in 1 2 3 4 5 6; do
        printf 'old %s\n' "$i" > "$HOME/.gitignore_global.bak.2025010$i-000000"
    done
    run linux_install
    [ "$status" -eq 0 ]
    [ "$(backups_of "$HOME/.gitignore_global" | wc -l | tr -d ' ')" -eq 5 ]
    some_backup_has "$HOME/.gitignore_global" "ORIGINAL-GITIGNORE"
}

@test "regenerating ~/.gitconfig over and over keeps the pinned original (#253)" {
    run linux_install
    [ "$status" -eq 0 ]
    # shellcheck source=../../scripts/shared/functions.sh
    source "$REPO_ROOT/scripts/shared/functions.sh"
    local i
    for i in 1 2 3 4 5 6; do
        printf '# hand edit %s\n' "$i" >> "$HOME/.gitconfig"
        generate_gitconfig "$REPO_ROOT" "$HOME" true >/dev/null
    done
    # The timestamped backups no longer hold the original; the pin does.
    [ "$(backups_of "$HOME/.gitconfig" | wc -l | tr -d ' ')" -eq 5 ]
    run some_backup_has "$HOME/.gitconfig" "Original Gitconfig"
    [ "$status" -ne 0 ]
    grep -qF "Original Gitconfig" "$HOME/.gitconfig.pre-gitconfig"
    grep -qF "ORIGINAL-GITIGNORE" "$HOME/.gitignore_global.pre-gitconfig"
    grep -qF "/original/local" "$HOME/.gitconfig.local.pre-gitconfig"
}

@test "mac installer: installing twice keeps the original files" {
    run mac_install
    [ "$status" -eq 0 ]
    run mac_install --reinstall
    [ "$status" -eq 0 ]
    some_backup_has "$HOME/.gitconfig" "Original Gitconfig"
    some_backup_has "$HOME/.gitignore_global" "ORIGINAL-GITIGNORE"
    some_backup_has "$HOME/.gitconfig.local" "/original/local"
}
