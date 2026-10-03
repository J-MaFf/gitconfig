#!/bin/bash
# Shared git repository auto-update script for mac and linux.
# Pulls the gitconfig repo, reinstalls ~/.gitconfig if the template changed, and
# prunes merged branches; triggered by launchd/cron at login.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default to the repo this script lives in (scripts/shared -> repo root), not a
# fixed ~/Documents path, so a clone anywhere still syncs. The installers also
# pass the path explicitly.
REPO_PATH="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOG_FILE="$REPO_PATH/docs/update-gitconfig.log"

# Headless (cron/launchd/login): a git credential prompt would block forever
# with nobody to answer it. Fail the network step instead; it is best-effort.
export GIT_TERMINAL_PROMPT=0

log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # The whole main block below is redirected to "$LOG_FILE", so a plain echo
    # already reaches the log. Using `tee -a "$LOG_FILE"` here would write the
    # line a second time (once via tee, once via the block redirect). This runs
    # headless under launchd/cron with no terminal attached, so the block
    # redirect is the single source of truth for log output.
    echo "[$timestamp] $1"
}

# Check the path BEFORE creating anything: a wrong path must not leave a stray
# "<path>/docs" tree behind. The log lives inside the repo, so this error can
# only go to stderr (the cron entry and launchd plist capture it).
if [ ! -d "$REPO_PATH" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Repository path not found: $REPO_PATH" >&2
    exit 1
fi

EXIT_CODE=0

mkdir -p "$(dirname "$LOG_FILE")"

{
    log_message "Starting git repository synchronization..."

    cd "$REPO_PATH" || exit 1

    # --- Update the repo (best-effort; never fatal) ------------------------
    # A dirty tree, offline state, or diverged history must not stop us from
    # converging ~/.gitconfig below. --untracked-files=no: the log we just wrote
    # under docs/ is untracked and must not count as "dirty" (untracked files
    # don't block an ff-only pull).
    # Never switch branches: a feature branch is someone's work in progress, and
    # checking out main under them at login is a surprise. Off main, fast-forward
    # main in place instead (`fetch origin main:main` refuses a non-fast-forward
    # and never touches the working tree); the template rendered below is still
    # the one in the checked-out branch.
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ "$CURRENT_BRANCH" != "main" ]; then
        log_message "On '$CURRENT_BRANCH', not main; leaving it checked out and fast-forwarding main in place..."
        if git fetch origin main:main; then
            log_message "SUCCESS: main up to date (still on '$CURRENT_BRANCH')"
        else
            log_message "WARN: could not fast-forward main (offline, diverged, or checked out elsewhere); continuing"
        fi
    elif [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        log_message "WARN: working tree not clean; skipping pull (will still converge ~/.gitconfig)"
    else
        log_message "Fetching and fast-forwarding..."
        if git pull --ff-only; then
            log_message "SUCCESS: repo up to date"
        else
            log_message "WARN: pull failed (offline or diverged); continuing with the local template"
        fi
    fi

    # --- Converge ~/.gitconfig to the template (always) --------------------
    # generate_gitconfig is idempotent: it writes only when the rendered template
    # differs from ~/.gitconfig, so this self-heals from any state (stale,
    # hand-edited, deleted, or a no-op pull) and is safe to run on every login.
    # shellcheck source=functions.sh
    source "$SCRIPT_DIR/functions.sh"
    if generate_gitconfig "$REPO_PATH" "$HOME" true; then
        log_message "SUCCESS: ~/.gitconfig converged to template"
    else
        log_message "ERROR: could not converge ~/.gitconfig from template"
        EXIT_CODE=1
    fi

    # Ensure the declared Python deps are present (rich required; textual optional,
    # for the interactive `git alias` browser). Single source of truth: the shared
    # install_python_deps routine reads pyproject.toml and installs only what is
    # missing. Best-effort and idempotent — never fails the update.
    log_message "Checking Python dependencies (rich + optional textual)..."
    install_python_deps "$REPO_PATH"

    # Prune merged branches: drop stale remote-tracking refs, then delete local
    # branches whose upstream remote has been deleted. Mirrors the `git cleanup`
    # alias. We don't recreate local branches for every remote here; the
    # on-demand `git branches` alias covers that when wanted.
    #
    # Branch state comes from `git for-each-ref`, not `git branch -vv`: that
    # text includes each branch's last commit subject, so a subject containing
    # ": gone]" used to get a live branch deleted. Fields are separated by the
    # ASCII unit separator (0x1f), which never appears in a ref name and, unlike
    # a tab, isn't IFS whitespace, so empty fields survive `read`.
    log_message "Pruning merged branches..."
    if FETCH_RESULT=$(git fetch --prune 2>&1); then
        log_message "SUCCESS: git fetch --prune completed"
        while IFS=$'\x1f' read -r BRANCH IS_HEAD TRACK WORKTREE TIP; do
            # Skip the current branch.
            [ "$IS_HEAD" = "*" ] && continue
            # Only delete branches whose upstream remote is gone.
            [ "$TRACK" = "[gone]" ] || continue
            # Skip branches checked out in another worktree; git refuses to
            # delete them until the worktree is removed.
            if [ -n "$WORKTREE" ]; then
                log_message "Skipped merged branch checked out in a worktree: $BRANCH"
                continue
            fi
            # -d first: it succeeds when the branch is merged into HEAD. A
            # squash-merged PR branch never is, so fall back to -D for a gone
            # branch, and log its tip so it can be restored.
            if git branch -d "$BRANCH" >/dev/null 2>&1; then
                log_message "Deleted merged branch: $BRANCH (was $TIP)"
            elif DELETE_RESULT=$(git branch -D "$BRANCH" 2>&1); then
                log_message "Deleted gone branch with commits not in HEAD (-D): $BRANCH (was $TIP; restore with: git branch $BRANCH $TIP)"
            else
                log_message "WARNING: Failed to delete branch: $BRANCH"
                log_message "Output: $DELETE_RESULT"
                EXIT_CODE=1
            fi
        done < <(git for-each-ref --format='%(refname:short)%1f%(HEAD)%1f%(upstream:track)%1f%(worktreepath)%1f%(objectname:short)' refs/heads/)
        log_message "SUCCESS: Merged branches pruned"
    else
        # Offline at login is routine: warn, but don't fail the run for it.
        log_message "WARN: git fetch --prune failed (offline?); skipping prune"
        log_message "Output: $FETCH_RESULT"
    fi

    log_message "Repository synchronization completed"

} >> "$LOG_FILE" 2>&1

# The block above is a brace group, not a subshell, so EXIT_CODE set inside it
# is visible here. Non-zero when ~/.gitconfig could not be converged or a
# branch could not be deleted; a failed pull or fetch (offline) is only a WARN.
exit "$EXIT_CODE"
