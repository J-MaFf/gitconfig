# Git Repository Auto-Update Script
# Pulls the gitconfig repository, reinstalls ~/.gitconfig if the template changed,
# and prunes merged branches.
# Scheduled to run at user login via Windows Task Scheduler

# RepoPath defaults to the repo this script lives in (scripts\windows version ->
# repo root), not a fixed Documents path, so a clone anywhere still syncs.
# Register-LoginTask.ps1 also passes the path explicitly.
param(
    [string]$RepoPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

# Log file location
$logFile = Join-Path $RepoPath "docs\update-gitconfig.log"

# Function to log messages with timestamp
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

# Check the path BEFORE logging: the log lives inside the repo, so with a wrong
# path every Write-Log would throw (and the old order also hid the real error).
# Report to stderr and exit 1 instead; Task Scheduler records the exit code.
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    [Console]::Error.WriteLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ERROR: Repository path not found: $RepoPath")
    exit 1
}
$logDir = Split-Path -Parent $logFile
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# Headless (login task): a git credential prompt would block forever with nobody
# to answer it. Fail the network step instead; it is best-effort. Restored in
# `finally` because a direct `& .\Update-GitConfig.ps1` runs in the caller's
# session and must not leave the variable behind.
$previousTerminalPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = '0'

try {
    Write-Log "Starting git repository synchronization..."

    # Change to repo directory
    Push-Location $RepoPath

    # Step 1+2: Update the repo (best-effort; never fatal). A dirty tree, offline
    # state, or diverged history must not stop the convergence step below.
    # --untracked-files=no: the log we just wrote under docs/ is untracked and must
    # not count as "dirty" (untracked files don't block an ff-only pull).
    # Never switch branches: a feature branch is someone's work in progress, and
    # checking out main under them at login is a surprise. Off main, fast-forward
    # main in place instead (`fetch origin main:main` refuses a non-fast-forward
    # and never touches the working tree); the template rendered below is still
    # the one in the checked-out branch.
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($currentBranch -ne "main") {
        Write-Log "On '$currentBranch', not main; leaving it checked out and fast-forwarding main in place..."
        $fetchMainResult = git fetch origin main:main 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "SUCCESS: main up to date (still on '$currentBranch')"
        }
        else {
            Write-Log "WARN: could not fast-forward main (offline, diverged, or checked out elsewhere); continuing. Output: $fetchMainResult"
        }
    }
    elseif (git status --porcelain --untracked-files=no 2>$null) {
        Write-Log "WARN: working tree not clean; skipping pull (will still converge ~/.gitconfig)"
    }
    else {
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

    # Step 2c: Ensure the declared Python deps are present (rich required; textual
    # optional, for the interactive `git alias` browser). Single source of truth:
    # the shared Install-PythonDeps routine reads pyproject.toml and installs only
    # what is missing. Best-effort and idempotent - never fails the update.
    . (Join-Path $PSScriptRoot 'Functions.ps1')
    Install-PythonDeps -RepoRoot $RepoPath -Logger { param($m) Write-Log $m }

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
            # Skip branches checked out in another worktree (leading '+');
            # git refuses to delete them until the worktree is removed.
            if ($line -match '^\+\s+(\S+)') {
                Write-Log "Skipped merged branch checked out in a worktree: $($Matches[1])"
                continue
            }
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
finally {
    $env:GIT_TERMINAL_PROMPT = $previousTerminalPrompt
}
