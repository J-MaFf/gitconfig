# Git Repository Auto-Update Script
# This script runs 'git pull' in the gitconfig repository
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
        Write-Log "WARNING: Failed to switch to main branch"
        Write-Log "Output: $switchResult"
    }

    # Step 2: Pull latest changes on main
    Write-Log "Pulling latest changes from main..."
    $pullResult = git pull 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: git pull completed on main"
        Write-Log "Output: $pullResult"
    }
    else {
        Write-Log "ERROR: git pull failed with exit code $LASTEXITCODE"
        Write-Log "Output: $pullResult"
    }

    # Step 3: Sync all remote tracking branches
    Write-Log "Synchronizing remote tracking branches..."
    $branchesResult = git fetch 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: git fetch completed"
        # Create local tracking branches for all remotes
        $remoteBranches = git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | Where-Object { $_ -notmatch '^origin/HEAD' }
        foreach ($branch in $remoteBranches) {
            $localBranch = $branch -replace '^origin/', ''
            $trackingCheck = git branch --track $localBranch $branch 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Created tracking branch: $localBranch"
            }
        }
        Write-Log "SUCCESS: Remote tracking branches synchronized"
    }
    else {
        Write-Log "ERROR: git fetch failed with exit code $LASTEXITCODE"
        Write-Log "Output: $branchesResult"
    }

    Write-Log "Repository synchronization completed successfully"

    Pop-Location
}
catch {
    Write-Log "EXCEPTION: $_"
    exit 1
}
