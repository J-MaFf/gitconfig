#!/bin/bash

# Git Repository Auto-Update Script - Linux/Unix Version
# This script runs 'git pull' in the gitconfig repository
# Scheduled to run via cron or manually

REPO_PATH="${1:$HOME/.gitconfig}"
LOG_FILE="$REPO_PATH/../docs/update-gitconfig.log"

# Function to log messages with timestamp
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

{
    log_message "Starting git repository synchronization..."

    # Verify repo directory exists
    if [ ! -d "$REPO_PATH" ]; then
        log_message "ERROR: Repository path not found: $REPO_PATH"
        exit 1
    fi

    # Change to repo directory
    cd "$REPO_PATH"

    # Step 1: Switch to main branch
    log_message "Switching to main branch..."
    SWITCH_RESULT=$(git checkout main 2>&1)
    SWITCH_CODE=$?

    if [ $SWITCH_CODE -ne 0 ]; then
        log_message "ERROR: Failed to switch to main branch"
        log_message "Output: $SWITCH_RESULT"
        exit 1
    fi

    # Step 2: Pull latest changes on main
    log_message "Pulling latest changes from main..."
    PULL_RESULT=$(git pull 2>&1)
    PULL_CODE=$?

    if [ $PULL_CODE -eq 0 ]; then
        log_message "SUCCESS: git pull completed on main"
        log_message "Output: $PULL_RESULT"
    else
        log_message "ERROR: git pull failed with exit code $PULL_CODE"
        log_message "Output: $PULL_RESULT"
        exit 1
    fi

    # Step 3: Sync all remote tracking branches
    log_message "Synchronizing remote tracking branches..."
    FETCH_RESULT=$(git fetch 2>&1)
    FETCH_CODE=$?

    if [ $FETCH_CODE -eq 0 ]; then
        log_message "SUCCESS: git fetch completed"

        # Create local tracking branches for all remotes
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
                        log_message "Output: $TRACK_RESULT"
                    fi
                fi
            fi
        done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin/)

        log_message "SUCCESS: Remote tracking branches synchronized"
    else
        log_message "ERROR: git fetch failed with exit code $FETCH_CODE"
        log_message "Output: $FETCH_RESULT"
        exit 1
    fi

    log_message "Repository synchronization process completed"

} >> "$LOG_FILE" 2>&1

exit $?
