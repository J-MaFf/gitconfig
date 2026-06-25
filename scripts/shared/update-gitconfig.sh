#!/bin/bash
# Shared git repository auto-update script for mac and linux.
# Pulls the gitconfig repo, reinstalls ~/.gitconfig if the template changed, and
# prunes merged branches; triggered by launchd/cron at login.

REPO_PATH="${1:-$HOME/Documents/Scripts/gitconfig}"
LOG_FILE="$REPO_PATH/docs/update-gitconfig.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

mkdir -p "$(dirname "$LOG_FILE")"

{
    log_message "Starting git repository synchronization..."

    if [ ! -d "$REPO_PATH" ]; then
        log_message "ERROR: Repository path not found: $REPO_PATH"
        exit 1
    fi

    cd "$REPO_PATH" || exit 1

    # --- Update the repo (best-effort; never fatal) ------------------------
    # A dirty tree, offline state, or diverged history must not stop us from
    # converging ~/.gitconfig below. --untracked-files=no: the log we just wrote
    # under docs/ is untracked and must not count as "dirty" (untracked files
    # don't block a checkout or ff-only pull).
    if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        log_message "WARN: working tree not clean; skipping pull (will still converge ~/.gitconfig)"
    else
        if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "main" ]; then
            git checkout main >/dev/null 2>&1 || log_message "WARN: could not switch to main; pulling current branch"
        fi
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
    fi

    # Ensure the declared Python deps are present (rich required; textual optional,
    # for the interactive `git alias` browser). Single source of truth: the shared
    # install_python_deps routine reads pyproject.toml and installs only what is
    # missing. Best-effort and idempotent — never fails the update.
    log_message "Checking Python dependencies (rich + optional textual)..."
    install_python_deps "$REPO_PATH"

    # Prune merged branches: drop stale remote-tracking refs, then delete local
    # branches whose upstream remote has been deleted (": gone]"). Mirrors the
    # `git cleanup` alias. We don't recreate local branches for every remote here;
    # the on-demand `git branches` alias covers that when wanted.
    log_message "Pruning merged branches..."
    FETCH_RESULT=$(git fetch --prune 2>&1)
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: git fetch --prune completed"
        while IFS= read -r line; do
            # Skip the current branch (marked with a leading '*').
            [[ "$line" == \** ]] && continue
            # Only delete branches whose upstream remote is gone.
            [[ "$line" == *": gone]"* ]] || continue
            GONE_BRANCH=$(awk '{print $1}' <<< "$line")
            DELETE_RESULT=$(git branch -D "$GONE_BRANCH" 2>&1)
            if [ $? -eq 0 ]; then
                log_message "Deleted merged branch: $GONE_BRANCH"
            else
                log_message "WARNING: Failed to delete branch: $GONE_BRANCH"
                log_message "Output: $DELETE_RESULT"
            fi
        done < <(git branch -vv)
        log_message "SUCCESS: Merged branches pruned"
    else
        log_message "WARN: git fetch --prune failed (offline?); skipping prune"
        log_message "Output: $FETCH_RESULT"
    fi

    log_message "Repository synchronization completed"

} >> "$LOG_FILE" 2>&1

exit $?
