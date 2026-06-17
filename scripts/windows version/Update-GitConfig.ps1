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

    # Step 1+2: Update the repo (best-effort; never fatal). A dirty tree, offline
    # state, or diverged history must not stop the convergence step below.
    # --untracked-files=no: the log we just wrote under docs/ is untracked and must
    # not count as "dirty" (untracked files don't block a checkout or ff-only pull).
    if (git status --porcelain --untracked-files=no 2>$null) {
        Write-Log "WARN: working tree not clean; skipping pull (will still converge ~/.gitconfig)"
    }
    else {
        if ((git rev-parse --abbrev-ref HEAD 2>$null) -ne "main") {
            git checkout main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log "WARN: could not switch to main; pulling current branch" }
        }
        Write-Log "Fetching and fast-forwarding..."
        $pullResult = git pull --ff-only 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "SUCCESS: repo up to date"
        }
        else {
            Write-Log "WARN: pull failed (offline or diverged); continuing with the local template. Output: $pullResult"
        }
    }

    # Step 2b: Converge ~/.gitconfig to the template (always). Initialize-GitConfig
    # is idempotent - it writes only when the rendered template differs from
    # ~/.gitconfig - so this self-heals from any state (stale, hand-edited, deleted,
    # or a no-op pull) and is safe to run on every login.
    Write-Log "Converging ~/.gitconfig to template..."
    $initScript = Join-Path $PSScriptRoot "Initialize-GitConfig.ps1"
    # *>&1 (not 2>&1): Initialize-GitConfig reports via Write-Host (information
    # stream), so capture all streams to fold its output into our log.
    & $initScript -Force *>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "SUCCESS: ~/.gitconfig converged to template"
    }
    else {
        Write-Log "ERROR: convergence failed (exit code $LASTEXITCODE)"
    }

    # Step 2c: Ensure the optional 'textual' dependency (for the interactive
    # `git alias` browser) is present. Best-effort and idempotent: resolves the
    # interpreter py -> python3 -> python (avoiding the Microsoft Store stub),
    # only installs when missing, and never fails the update if it cannot.
    $pyCmd = if (Get-Command py -ErrorAction SilentlyContinue)          { "py" }
             elseif (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
             elseif (Get-Command python -ErrorAction SilentlyContinue)  { "python" }
             else { $null }
    if (-not $pyCmd) {
        Write-Log "Skipping 'textual' check: no Python interpreter found"
    }
    else {
        & $pyCmd -c "import textual" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Optional dependency 'textual' already present"
        }
        else {
            Write-Log "Installing optional dependency 'textual' for the interactive 'git alias' browser..."
            & $pyCmd -m pip install textual --quiet 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "SUCCESS: installed 'textual'"
            }
            else {
                Write-Log "WARNING: could not install 'textual'; 'git alias' will use the static table (install manually: pip install textual)"
            }
        }
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
