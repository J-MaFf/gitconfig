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

    log_message "Switching to main branch..."
    SWITCH_RESULT=$(git checkout main 2>&1)
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to switch to main branch"
        log_message "Output: $SWITCH_RESULT"
        exit 1
    fi

    log_message "Pulling latest changes from main..."
    HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null)
    PULL_RESULT=$(git pull 2>&1)
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: git pull completed"
        log_message "Output: $PULL_RESULT"
    else
        log_message "ERROR: git pull failed"
        log_message "Output: $PULL_RESULT"
        exit 1
    fi
    HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null)

    # Reinstall ~/.gitconfig if the template changed during this pull.
    # ~/.gitconfig is rendered from .gitconfig.template, so template changes
    # download on pull but only take effect after regeneration.
    if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && \
       [ -n "$(git diff --name-only "$HEAD_BEFORE" "$HEAD_AFTER" -- .gitconfig.template)" ]; then
        log_message ".gitconfig.template changed; regenerating ~/.gitconfig..."
        # shellcheck source=functions.sh
        source "$SCRIPT_DIR/functions.sh"
        if generate_gitconfig "$REPO_PATH" "$HOME" true; then
            log_message "SUCCESS: ~/.gitconfig regenerated from template (previous saved to ~/.gitconfig.bak)"
        else
            log_message "ERROR: Failed to regenerate ~/.gitconfig from template"
        fi
    else
        log_message "No .gitconfig.template changes; skipping regeneration"
    fi

    # Ensure the optional 'textual' dependency (for the interactive `git alias`
    # browser) is present. Best-effort and idempotent: resolves the interpreter
    # py -> python3 -> python like the aliases, only installs when textual is
    # missing, and never fails the update if the install does not succeed.
    PYTHON_BIN=""
    for p in py python3 python; do
        if command -v "$p" >/dev/null 2>&1 && "$p" -c '' >/dev/null 2>&1; then
            PYTHON_BIN="$p"
            break
        fi
    done
    if [ -z "$PYTHON_BIN" ]; then
        log_message "Skipping 'textual' check: no working Python interpreter found"
    elif "$PYTHON_BIN" -c "import textual" >/dev/null 2>&1; then
        log_message "Optional dependency 'textual' already present"
    else
        log_message "Installing optional dependency 'textual' for the interactive 'git alias' browser..."
        if "$PYTHON_BIN" -m pip install textual --quiet >/dev/null 2>&1 || \
           "$PYTHON_BIN" -m pip install textual --quiet --break-system-packages >/dev/null 2>&1; then
            log_message "SUCCESS: installed 'textual'"
        else
            log_message "WARNING: could not install 'textual'; 'git alias' will use the static table (install manually: pip3 install textual)"
        fi
    fi

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
        log_message "ERROR: git fetch --prune failed"
        log_message "Output: $FETCH_RESULT"
        exit 1
    fi

    log_message "Repository synchronization completed"

} >> "$LOG_FILE" 2>&1

exit $?
