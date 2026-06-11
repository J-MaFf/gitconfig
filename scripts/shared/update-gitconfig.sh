#!/bin/bash
# Shared git repository auto-update script for mac and linux.
# Runs 'git pull' in the gitconfig repo; triggered by launchd/cron at login.

REPO_PATH="${1:-$HOME/Documents/Scripts/gitconfig}"
LOG_FILE="$REPO_PATH/docs/update-gitconfig.log"

log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
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
    PULL_RESULT=$(git pull 2>&1)
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: git pull completed"
        log_message "Output: $PULL_RESULT"
    else
        log_message "ERROR: git pull failed"
        log_message "Output: $PULL_RESULT"
        exit 1
    fi

    log_message "Synchronizing remote tracking branches..."
    FETCH_RESULT=$(git fetch 2>&1)
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: git fetch completed"
        while IFS= read -r branch; do
            if [[ ! "$branch" =~ "HEAD" ]]; then
                LOCAL_BRANCH="${branch#origin/}"
                if git show-ref --verify --quiet "refs/heads/$LOCAL_BRANCH"; then
                    log_message "Tracking branch already exists: $LOCAL_BRANCH"
                else
                    TRACK_RESULT=$(git branch --track "$LOCAL_BRANCH" "$branch" 2>&1)
                    if [ $? -eq 0 ]; then
                        log_message "Created tracking branch: $LOCAL_BRANCH"
                    else
                        log_message "WARNING: Failed to create tracking branch: $LOCAL_BRANCH"
                    fi
                fi
            fi
        done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin/)
        log_message "SUCCESS: Remote tracking branches synchronized"
    else
        log_message "ERROR: git fetch failed"
        log_message "Output: $FETCH_RESULT"
        exit 1
    fi

    log_message "Repository synchronization completed"

} >> "$LOG_FILE" 2>&1

exit $?
