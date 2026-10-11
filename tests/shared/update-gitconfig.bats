#!/usr/bin/env bats
#
# Bats suite for scripts/shared/update-gitconfig.sh — the login-time updater
# for mac and linux. Covers the branch-prune step (issue #228): branch state is
# read with `git for-each-ref`, not by scraping `git branch -vv`, deletion tries
# `-d` before `-D`, each deleted tip is logged, worktree checkouts are skipped,
# and the exit code reports failures.
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
