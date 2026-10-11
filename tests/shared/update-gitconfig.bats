#!/usr/bin/env bats
#
# Bats suite for scripts/shared/update-gitconfig.sh — the login-time updater
# for mac and linux. Covers the branch-prune step (issue #228): branch state is
# read with `git for-each-ref`, not by scraping `git branch -vv`, deletion tries
# `-d` before `-D`, each deleted tip is logged, worktree checkouts are skipped,
# and the exit code reports failures.
#
# Also covers the pull-then-converge step (issue #233): a template change
# pulled from origin reaches ~/.gitconfig, a dirty tree skips the pull but
# still converges, a hand-edited or deleted ~/.gitconfig self-heals, and the
# updater never touches crontab, launchd or systemd. After a pull that moves
# HEAD, the pulled functions.sh is loaded before converging (issue #297).
# Everything runs in a sandboxed $HOME against a local bare remote.
#
# Run with:  bats tests/shared/update-gitconfig.bats
# Requires:  bats-core (https://github.com/bats-core/bats-core) and git.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    UPDATER="$REPO_ROOT/scripts/shared/update-gitconfig.sh"

    TESTDIR="$(mktemp -d)"
    export HOME="$TESTDIR/home"
    # The update lock lives under XDG_STATE_HOME when it is set; keep it in HOME.
    unset XDG_STATE_HOME
    mkdir -p "$HOME"
    # Never read or write the developer's git config.
    export GIT_CONFIG_GLOBAL="$TESTDIR/gitconfig-global"
    export GIT_CONFIG_SYSTEM="$TESTDIR/no-system-config"
    printf '[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

    # Keep the updater away from real machine state: no Python (so no pip
    # install), and crontab/launchctl/systemctl stubs that only record a call.
    # The updater must never touch the login scheduler; see the test below.
    SCHED_CALLS="$TESTDIR/scheduler-calls"
    mkdir -p "$TESTDIR/bin"
    local stub
    for stub in py python python3; do
        printf '#!/bin/sh\nexit 1\n' > "$TESTDIR/bin/$stub"
    done
    for stub in crontab launchctl systemctl; do
        printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$stub" "$SCHED_CALLS" > "$TESTDIR/bin/$stub"
    done
    chmod +x "$TESTDIR"/bin/*
    export PATH="$TESTDIR/bin:$PATH"

    REMOTE="$TESTDIR/remote.git"
    REPO="$TESTDIR/repo"
    LOG="$REPO/docs/update-gitconfig.log"
    git init -q --bare -b main "$REMOTE"
    git clone -q "$REMOTE" "$REPO" 2>/dev/null
    printf '[core]\n\teditor = vi\n' > "$REPO/.gitconfig.template"
    commit "$REPO" README.md "Initial"
    git -C "$REPO" push -q -u origin main
}

teardown() {
    rm -rf "$TESTDIR"
}

commit() {
    local dir="$1" file="$2" subject="$3"
    echo "$subject" > "$dir/$file"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "$subject"
}

# Create a branch off main with one commit, push it with an upstream, and
# return to main.
pushed_branch() {
    local name="$1" subject="${2:-work on $1}"
    git -C "$REPO" switch -q -c "$name" main
    commit "$REPO" "$name.txt" "$subject"
    git -C "$REPO" push -q -u origin "$name"
    git -C "$REPO" switch -q main
}

branches() {
    git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/
}

# Commit a new .gitconfig.template from a second clone and push it to origin,
# as if another machine had published a change.
publish_template() {
    local other="$TESTDIR/other"
    [ -d "$other" ] || git clone -q "$REMOTE" "$other" 2>/dev/null
    git -C "$other" pull -q --ff-only
    printf '%b' "$1" > "$other/.gitconfig.template"
    git -C "$other" commit -q -am "Update template"
    git -C "$other" push -q origin main
}

# The timestamped backups of ~/.gitconfig.
gitconfig_backups() {
    local f
    for f in "$HOME"/.gitconfig.bak.[0-9]*; do
        if [ -e "$f" ]; then printf '%s\n' "$f"; fi
    done
}

# Run the updater the way `git selfupdate` does from a terminal: stdout on a
# pseudo-terminal, made by script(1) (util-linux on Linux, BSD on macOS). Sets
# $status to the updater's exit code and $output to what reached the terminal.
run_on_terminal() {
    local st="$TESTDIR/tty-status" cmd
    cmd="bash '$UPDATER' '$REPO'; echo \$? > '$st'"
    if script -qec true /dev/null > /dev/null 2>&1; then
        run script -qec "$cmd" /dev/null < /dev/null
    elif script -q /dev/null true > /dev/null 2>&1; then
        run script -q /dev/null bash -c "$cmd" < /dev/null
    else
        skip "script(1) is not available to provide a terminal"
    fi
    status="$(cat "$st")"
}

@test "keeps a live branch whose commit subject contains ': gone]'" {
    pushed_branch trap "docs: gone] marks a deleted upstream"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    branches | grep -qx trap
    run ! grep -q "trap" "$LOG"
}

@test "deletes a merged gone branch with -d and logs its tip" {
    pushed_branch merged
    tip=$(git -C "$REPO" rev-parse --short merged)
    git -C "$REPO" merge -q --ff-only merged
    git -C "$REPO" push -q origin main
    git -C "$REPO" push -q origin --delete merged

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    run ! grep -qx merged < <(branches)
    grep -qF "Deleted merged branch: merged (was $tip)" "$LOG"
}

@test "force-deletes an unmerged gone branch and logs how to restore it" {
    pushed_branch squashed
    tip=$(git -C "$REPO" rev-parse --short squashed)
    git -C "$REPO" push -q origin --delete squashed

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    run ! grep -qx squashed < <(branches)
    grep -qF "Deleted gone branch with commits not in HEAD (-D): squashed (was $tip; restore with: git branch squashed $tip)" "$LOG"
}

@test "leaves local-only branches and branches tracking another remote alone" {
    git -C "$REPO" branch local-only main
    git clone -q --bare "$REMOTE" "$TESTDIR/upstream.git"
    git -C "$REPO" remote add upstream "$TESTDIR/upstream.git"
    git -C "$REPO" fetch -q upstream
    git -C "$REPO" branch -q --track fork upstream/main

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    branches | grep -qx local-only
    branches | grep -qx fork
}

@test "skips a gone branch checked out in another worktree" {
    pushed_branch wt-gone
    git -C "$REPO" push -q origin --delete wt-gone
    git -C "$REPO" worktree add -q "$TESTDIR/wt" wt-gone

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    branches | grep -qx wt-gone
    grep -qF "Skipped merged branch checked out in a worktree: wt-gone" "$LOG"
}

@test "exits 1 when a branch cannot be deleted" {
    pushed_branch locked
    git -C "$REPO" push -q origin --delete locked
    # A stale ref lock makes both `git branch -d` and `-D` fail.
    : > "$REPO/.git/refs/heads/locked.lock"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 1 ]
    grep -qF "WARNING: Failed to delete branch: locked" "$LOG"
}

@test "exits 1 when ~/.gitconfig cannot be converged" {
    git -C "$REPO" rm -q .gitconfig.template
    git -C "$REPO" commit -q -m "drop template"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 1 ]
    grep -qF "ERROR: could not converge ~/.gitconfig from template" "$LOG"
}

@test "an unreachable remote is a warning, not a failure" {
    git -C "$REPO" remote set-url origin "$TESTDIR/missing.git"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    grep -qF "WARN: git fetch --prune failed" "$LOG"
}

@test "run from a terminal, a failed pull is shown there and fails the run (#258)" {
    git -C "$REPO" remote set-url origin "$TESTDIR/missing.git"

    run_on_terminal
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: pull failed"* ]]
    [[ "$output" == *"$LOG"* ]]
    grep -qF "ERROR: pull failed" "$LOG"
}

@test "run from a terminal, a successful sync is shown there (#258)" {
    run_on_terminal
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS: repo up to date"* ]]
    [[ "$output" == *"Repository synchronization completed"* ]]
}

# ---------------------------------------------------------------------------
# One sync at a time (issue #234)
# ---------------------------------------------------------------------------

LOCK_REL=".local/state/gitconfig/update.lock"

@test "exits 0 quietly, changing nothing, while another run holds the lock" {
    sleep 60 3>&- &
    holder=$!
    mkdir -p "$HOME/$LOCK_REL"
    echo "$holder" > "$HOME/$LOCK_REL/pid"

    run bash "$UPDATER" "$REPO"
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$LOG" ]
    [ ! -e "$HOME/.gitconfig" ]
    # The holder's lock is left alone.
    [ "$(cat "$HOME/$LOCK_REL/pid")" = "$holder" ]
}

@test "run from a terminal while the lock is held, it says it skipped" {
    sleep 60 3>&- &
    holder=$!
    mkdir -p "$HOME/$LOCK_REL"
    echo "$holder" > "$HOME/$LOCK_REL/pid"

    run_on_terminal
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running; skipped"* ]]
    [ ! -e "$LOG" ]
}

@test "takes over a stale lock left by a run that died, and releases it" {
    sh -c 'exit 0' &
    dead=$!
    wait "$dead"
    mkdir -p "$HOME/$LOCK_REL"
    echo "$dead" > "$HOME/$LOCK_REL/pid"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    grep -qF "Repository synchronization completed" "$LOG"
    [ ! -e "$HOME/$LOCK_REL" ]
}

@test "releases the lock when it finishes, even on failure" {
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/$LOCK_REL" ]

    # ~/.gitconfig can't be converged: exit 1, lock still released.
    rm -f "$REPO/.gitconfig.template"
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/$LOCK_REL" ]
}

# ---------------------------------------------------------------------------
# Pull, then converge ~/.gitconfig (issue #233)
# ---------------------------------------------------------------------------

@test "a template change pulled from origin reaches ~/.gitconfig, rendered for this machine" {
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    grep -qx $'\teditor = vi' "$HOME/.gitconfig"

    publish_template '[core]\n\teditor = nano\n[include]\n\tpath = {{HOME_DIR}}/.gitconfig.local\n[alias]\n\th = !python3 {{REPO_PATH}}/gitconfig_helper.py\n'
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)" ]
    grep -qx $'\teditor = nano' "$HOME/.gitconfig"
    grep -qxF $'\t'"path = $HOME/.gitconfig.local" "$HOME/.gitconfig"
    grep -qxF $'\t'"h = !python3 $REPO/gitconfig_helper.py" "$HOME/.gitconfig"
    run ! grep -qF '{{' "$HOME/.gitconfig"
    grep -qF "SUCCESS: repo up to date" "$LOG"
    grep -qF "SUCCESS: ~/.gitconfig converged to template" "$LOG"
}

@test "a dirty main skips the pull but still converges ~/.gitconfig to the local template" {
    publish_template '[core]\n\teditor = nano\n'
    before="$(git -C "$REPO" rev-parse HEAD)"
    # An uncommitted edit to the template itself: it is what gets rendered.
    printf '[core]\n\teditor = emacs\n' > "$REPO/.gitconfig.template"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$before" ]
    grep -qF "WARN: working tree not clean; skipping pull (will still converge ~/.gitconfig)" "$LOG"
    grep -qx $'\teditor = emacs' "$HOME/.gitconfig"
}

@test "a hand-edited ~/.gitconfig is reset to the template, keeping the edit in a backup" {
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ -z "$(gitconfig_backups)" ]

    printf '[core]\n\teditor = vi\n[hand]\n\tedited = yes\n' > "$HOME/.gitconfig"
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.gitconfig")" = "$(cat "$REPO/.gitconfig.template")" ]
    [ "$(gitconfig_backups | wc -l | tr -d ' ')" -eq 1 ]
    grep -qF "edited = yes" "$(gitconfig_backups)"
}

@test "a deleted ~/.gitconfig is recreated, and an unchanged one is left alone" {
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    rm "$HOME/.gitconfig"

    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.gitconfig")" = "$(cat "$REPO/.gitconfig.template")" ]

    # Nothing changed: no rewrite, so no backup piles up on every login.
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    [ -z "$(gitconfig_backups)" ]
    grep -qF "[OK] .gitconfig already up to date (matches template)" "$LOG"
}

@test "never touches crontab, launchd or systemd, headless or from a terminal" {
    run bash "$UPDATER" "$REPO"
    [ "$status" -eq 0 ]
    run_on_terminal
    [ "$status" -eq 0 ]
    # Python was hidden too: the deps step skipped instead of installing.
    grep -qF "No Python interpreter found" "$LOG"
    [ ! -e "$SCHED_CALLS" ]
}

# The updater as installed: a copy inside the synced repo, so a pull replaces
# the functions.sh it loads, as on a real machine.
install_updater_in_repo() {
    mkdir -p "$REPO/scripts/shared"
    cp "$REPO_ROOT/scripts/shared/update-gitconfig.sh" "$REPO_ROOT/scripts/shared/functions.sh" "$REPO/scripts/shared/"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "Add the updater"
    git -C "$REPO" push -q origin main
}

# Publish a functions.sh whose generate_gitconfig only says it ran.
publish_new_functions() {
    local other="$TESTDIR/other"
    [ -d "$other" ] || git clone -q "$REMOTE" "$other" 2>/dev/null
    git -C "$other" pull -q --ff-only
    printf '\ngenerate_gitconfig() { echo "NEW generate_gitconfig ran"; }\n' >> "$other/scripts/shared/functions.sh"
    git -C "$other" commit -q -am "Change generate_gitconfig"
    git -C "$other" push -q origin main
}

@test "after a pull that moves HEAD, the pulled functions.sh renders the template" {
    install_updater_in_repo
    publish_new_functions

    run bash "$REPO/scripts/shared/update-gitconfig.sh" "$REPO"
    [ "$status" -eq 0 ]
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)" ]
    # The old generate_gitconfig, loaded before the pull, would have written
    # ~/.gitconfig instead (#297).
    grep -qF "NEW generate_gitconfig ran" "$LOG"
    [ ! -e "$HOME/.gitconfig" ]
    grep -qF "reloading functions.sh" "$LOG"
}

@test "without a pull that moves HEAD, functions.sh is not reloaded" {
    install_updater_in_repo
    run bash "$REPO/scripts/shared/update-gitconfig.sh" "$REPO"
    [ "$status" -eq 0 ]
    run ! grep -qF "reloading functions.sh" "$LOG"
    [ -f "$HOME/.gitconfig" ]

    # Off main, main is fast-forwarded in place but HEAD stays: no reload.
    git -C "$REPO" switch -q -c feature
    publish_new_functions
    : > "$LOG"
    run bash "$REPO/scripts/shared/update-gitconfig.sh" "$REPO"
    [ "$status" -eq 0 ]
    run ! grep -qF "reloading functions.sh" "$LOG"
    run ! grep -qF "NEW generate_gitconfig ran" "$LOG"
}
