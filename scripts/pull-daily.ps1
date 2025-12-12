# Daily Git Pull Script
# This script runs 'git pull' in the gitconfig repository
# Scheduled to run daily in the morning via Windows Task Scheduler

param(
    [string]$RepoPath = "C:\Users\jmaffiola\Documents\Scripts\gitconfig"
)

# Log file location
$logFile = "$RepoPath\pull-daily.log"

# Function to log messages with timestamp
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

try {
    Write-Log "Starting daily git pull..."

    # Verify repo directory exists
    if (-not (Test-Path $RepoPath)) {
        Write-Log "ERROR: Repository path not found: $RepoPath"
        exit 1
    }

    # Change to repo directory
    Push-Location $RepoPath

    # Run git pull
    $result = git pull 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: git pull completed"
        Write-Log "Output: $result"
    }
    else {
        Write-Log "ERROR: git pull failed with exit code $LASTEXITCODE"
        Write-Log "Output: $result"
    }

    Pop-Location
}
catch {
    Write-Log "EXCEPTION: $_"
    exit 1
}
