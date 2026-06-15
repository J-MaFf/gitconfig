# Git Repository Auto-Update Script
# Pulls the gitconfig repository, reinstalls ~/.gitconfig if the template changed,
# and prunes merged branches.
# Scheduled to run at user login via Windows Task Scheduler

param(
    [string]$RepoPath = "$env:USERPROFILE\Documents\Scripts\gitconfig"
)

# Log file location
$logFile = "$RepoPath\docs\update-gitconfig.log"

# Function to log messages with timestamp
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

try {
    Write-Log "Starting git repository synchronization..."

    # Verify repo directory exists
    if (-not (Test-Path $RepoPath)) {
        Write-Log "ERROR: Repository path not found: $RepoPath"
        exit 1
    }

    # Change to repo directory
    Push-Location $RepoPath

    # Step 1: Switch to main branch
    Write-Log "Switching to main branch..."
    $switchResult = git checkout main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Failed to switch to main branch"
        Write-Log "Output: $switchResult"
        exit 1
    }

    # Step 2: Pull latest changes on main
    Write-Log "Pulling latest changes from main..."
    $headBefore = (git rev-parse HEAD 2>$null)
    $pullResult = git pull 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: git pull completed on main"
        Write-Log "Output: $pullResult"
    }
    else {
        Write-Log "ERROR: git pull failed with exit code $LASTEXITCODE"
        Write-Log "Output: $pullResult"
    }
    $headAfter = (git rev-parse HEAD 2>$null)

    # Step 2b: Reinstall ~/.gitconfig if the template changed during this pull.
    # ~/.gitconfig is rendered from .gitconfig.template, so template changes
    # download on pull but only take effect after regeneration.
    if ($headBefore -ne $headAfter) {
        $templateChanged = git diff --name-only $headBefore $headAfter -- .gitconfig.template
        if ($templateChanged) {
            Write-Log ".gitconfig.template changed; regenerating ~/.gitconfig..."
            $initScript = Join-Path $PSScriptRoot "Initialize-GitConfig.ps1"
            & $initScript -Force 2>&1 | ForEach-Object { Write-Log $_ }
            if ($LASTEXITCODE -eq 0) {
                Write-Log "SUCCESS: ~/.gitconfig regenerated from template (previous saved to ~/.gitconfig.bak)"
            }
            else {
                Write-Log "ERROR: Failed to regenerate ~/.gitconfig from template (exit code $LASTEXITCODE)"
            }
        }
        else {
            Write-Log "No .gitconfig.template changes; skipping regeneration"
        }
    }
    else {
        Write-Log "No new commits pulled; skipping regeneration"
    }

    # Step 3: Prune merged branches. Drop stale remote-tracking refs, then delete
    # local branches whose upstream remote has been deleted (": gone]"). Mirrors
    # the `git cleanup` alias. We don't recreate local branches for every remote
    # here; the on-demand `git branches` alias covers that when wanted.
    Write-Log "Pruning merged branches..."
    $fetchResult = git fetch --prune 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: git fetch --prune completed"
        $branchLines = git branch -vv
        foreach ($line in $branchLines) {
            # Skip the current branch (marked with a leading '*').
            if ($line -match '^\*') { continue }
            # Only delete branches whose upstream remote is gone.
            if ($line -notmatch ': gone\]') { continue }
            $goneBranch = ($line.Trim() -split '\s+')[0]
            $deleteResult = git branch -D $goneBranch 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Deleted merged branch: $goneBranch"
            }
            else {
                Write-Log "WARNING: Failed to delete branch: $goneBranch"
                Write-Log "Output: $deleteResult"
            }
        }
        Write-Log "SUCCESS: Merged branches pruned"
    }
    else {
        Write-Log "ERROR: git fetch --prune failed with exit code $LASTEXITCODE"
        Write-Log "Output: $fetchResult"
    }

    Write-Log "Repository synchronization process completed"

    Pop-Location
}
catch {
    Write-Log "EXCEPTION: $_"
    exit 1
}
