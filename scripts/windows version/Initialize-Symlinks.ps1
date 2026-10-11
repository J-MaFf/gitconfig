# Dotfiles Symlink Setup Script
# This script creates symbolic links from the home directory to the dotfiles repository
# Usage: .\Initialize-Symlinks.ps1
# Note: Requires admin privileges to create symlinks on Windows

param(
    [switch]$Force = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
Dotfiles Symlink Setup Script

USAGE:
    .\Initialize-Symlinks.ps1 [OPTIONS]

OPTIONS:
    -Force      Replace existing files without prompting (each is first moved
                to a timestamped backup, <file>.bak.yyyyMMdd-HHmmss)
    -Help       Display this help message

DESCRIPTION:
    Creates symbolic links from your home directory (~) to the dotfiles repository.
    Also optionally creates a scheduled task to run 'git pull' at login.

REQUIREMENTS:
    - Administrator privileges (for creating symlinks on Windows)
    - Administrator privileges (for creating scheduled task)
    - PowerShell 7+ recommended, but works with Windows PowerShell 5.1+

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    .\Initialize-Symlinks.ps1

    # Force mode (overwrites without prompting)
    .\Initialize-Symlinks.ps1 -Force

FILES LINKED:
    - .gitignore_global
    - gitconfig_helper.py

SCHEDULED TASKS:
    - GitConfig Pull at Login (optional, runs Update-GitConfig.ps1 at user login)
"@
    exit 0
}

# Check if running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[WARNING] This script should ideally run with administrator privileges to create symlinks." -ForegroundColor Yellow
    Write-Host "Attempting to continue, but symlink creation may fail if not admin." -ForegroundColor Yellow
    Write-Host ""
}

# Get the repository root (two levels up from scripts\windows version\)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)
$homeDir = $env:USERPROFILE

# Shared helpers: timestamped backups and symlink checks.
. (Join-Path $scriptDir "Functions.ps1")

Write-Host "Dotfiles Setup" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host ""

# Define files to symlink
# .gitconfig is generated from .gitconfig.template into ~/ and must NOT be symlinked
$filesToLink = @(
    ".gitignore_global",
    "gitconfig_helper.py"
)

# Function to create symlink. Returns 'Linked', 'Skipped' (the user said no)
# or 'Failed'.
#
# The new link is made under a temporary name first and only then swapped in,
# so a link that can't be made (no admin or Developer Mode, a repo on a share
# or exFAT) leaves the existing file where it was (#255). The old order moved
# the file aside first, so a failed link left nothing in place and
# core.excludesfile pointed at a missing file.
function New-Symlink {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [bool]$Force
    )

    # Already the right link: nothing to do.
    if (Test-LinkPointsTo -Path $LinkPath -Target $TargetPath) {
        Write-Host "[OK] Already linked: $LinkPath" -ForegroundColor Green
        return 'Linked'
    }

    $name = Split-Path -Leaf $LinkPath
    # Get-LinkAwareItem (not Test-Path) so a dangling symlink still counts.
    $existing = Get-LinkAwareItem -Path $LinkPath
    # An old link of ours into the repo holds no user data: it is replaced
    # without a prompt or a backup.
    $ours = $existing -and (Test-LinkIntoDirectory -Path $LinkPath -Directory $repoRoot)
    if ($existing -and -not $ours -and -not $Force) {
        $response = Read-Host "'$LinkPath' already exists. Overwrite? (y/n)"
        if ($response -ne "y") {
            Write-Host "Skipped: $LinkPath" -ForegroundColor Yellow
            return 'Skipped'
        }
    }

    # 1. Make the link under a temporary name. Nothing has been touched yet, so
    #    if this fails the existing file stays as it was. -ErrorAction Stop:
    #    New-Item reports a missing privilege as a non-terminating error.
    $tempLink = "$LinkPath.tmp-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        New-Item -ItemType SymbolicLink -Path $tempLink -Target $TargetPath -ErrorAction Stop | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $tempLink -Force -ErrorAction SilentlyContinue
        Write-Host "[FAIL] Failed to create symlink for $LinkPath" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($existing) { Write-Host "  Left the existing $name in place" -ForegroundColor Yellow }
        return 'Failed'
    }

    # 2. Clear the way: delete our old link (remembering its target), or move a
    #    real file (or someone else's link) to a timestamped backup.
    $oldTarget = $null
    $backupPath = $null
    if ($existing) {
        try {
            if ($ours) {
                $oldTarget = @($existing.Target)[0]
                Remove-Item -LiteralPath $LinkPath -Force -ErrorAction Stop
            }
            else {
                $backupPath = Backup-UserFile -Path $LinkPath -Move
                Write-Host "[OK] Backed up existing $name to $(Split-Path -Leaf $backupPath)" -ForegroundColor Yellow
            }
            if (Get-LinkAwareItem -Path $LinkPath) { throw "$LinkPath is still there" }
        }
        catch {
            Remove-Item -LiteralPath $tempLink -Force -ErrorAction SilentlyContinue
            Write-Host "[FAIL] Could not back up $LinkPath; leaving it in place" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            return 'Failed'
        }
    }

    # 3. Swap the new link in. If even that fails, put the old item back.
    try {
        Move-Item -LiteralPath $tempLink -Destination $LinkPath -ErrorAction Stop
    }
    catch {
        $err = $_.Exception.Message
        Remove-Item -LiteralPath $tempLink -Force -ErrorAction SilentlyContinue
        Write-Host "[FAIL] Failed to create symlink for $LinkPath" -ForegroundColor Red
        Write-Host "  Error: $err" -ForegroundColor Red
        if (-not (Get-LinkAwareItem -Path $LinkPath)) {
            try {
                if ($backupPath) {
                    Move-Item -LiteralPath $backupPath -Destination $LinkPath -ErrorAction Stop
                    Write-Host "  Restored the existing $name from its backup" -ForegroundColor Yellow
                }
                elseif ($oldTarget) {
                    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $oldTarget -ErrorAction Stop | Out-Null
                    Write-Host "  Restored the previous $name link" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "  Could not restore $name : $($_.Exception.Message)" -ForegroundColor Red
                if ($backupPath) { Write-Host "  Your file is at $backupPath" -ForegroundColor Red }
            }
        }
        return 'Failed'
    }

    Write-Host "[OK] Created symlink: $LinkPath -> $TargetPath" -ForegroundColor Green
    return 'Linked'
}

# Function to create scheduled task for git pull at login. Delegates to
# Register-LoginTask.ps1 so both install paths register the same task (repo
# path, -ExecutionPolicy Bypass, per-user trigger, time limit); that script
# keeps an up-to-date task and replaces a stale one on its own.
function Register-LoginTask {
    param(
        [string]$RepoRoot,
        [bool]$Force
    )

    $registerScript = Join-Path $RepoRoot "scripts\windows version\Register-LoginTask.ps1"
    if (-not (Test-Path $registerScript)) {
        Write-Host "[WARN] Register-LoginTask.ps1 not found at $registerScript" -ForegroundColor Yellow
        Write-Host "  Skipping scheduled task creation." -ForegroundColor Yellow
        return $false
    }

    if ($Force) { & $registerScript -RepoPath $RepoRoot -Force } else { & $registerScript -RepoPath $RepoRoot }
    return ($LASTEXITCODE -eq 0)
}

# Create symlinks
$successCount = 0
$failCount = 0
foreach ($file in $filesToLink) {
    $targetPath = Join-Path $repoRoot $file
    $linkPath = Join-Path $homeDir $file

    if (-not (Test-Path $targetPath)) {
        Write-Host "[FAIL] Source file not found: $targetPath" -ForegroundColor Red
        $failCount++
        continue
    }

    switch (New-Symlink -LinkPath $linkPath -TargetPath $targetPath -Force $Force) {
        'Linked' { $successCount++ }
        'Failed' { $failCount++ }
    }
}

Write-Host ""
if ($failCount -eq 0) {
    Write-Host "Setup Complete!" -ForegroundColor Cyan
}
else {
    Write-Host "Setup finished with errors" -ForegroundColor Red
}
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Successfully linked $successCount file(s)" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host "[FAIL] Could not link $failCount file(s); see the [FAIL] lines above" -ForegroundColor Red
}
Write-Host ""

# Offer to create scheduled task
Write-Host "Would you like to set up automatic 'git pull' at login?" -ForegroundColor Cyan
$taskResponse = Read-Host "Create 'GitConfig Pull at Login' scheduled task? (y/n)"
if ($taskResponse -eq "y") {
    Write-Host ""
    if (-not $isAdmin) {
        Write-Host "[ERROR] Creating a scheduled task requires administrator privileges." -ForegroundColor Red
        Write-Host "Please run this script as administrator to enable this feature." -ForegroundColor Red
    }
    else {
        if (Register-LoginTask -RepoRoot $repoRoot -Force $Force) {
            Write-Host "[OK] Scheduled task created successfully!" -ForegroundColor Green
        }
    }
    Write-Host ""
}

if ($failCount -gt 0) {
    # Exit non-zero so a caller can tell the links are not all in place (#255).
    Write-Host "Not every file is symlinked. Creating symlinks on Windows needs an" -ForegroundColor Red
    Write-Host "administrator prompt or Developer Mode; fix that and run this script again." -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host "Your .gitignore_global and gitconfig_helper.py are now symlinked from the repository." -ForegroundColor Cyan
Write-Host "Any changes pushed to the repository will be reflected in your home directory." -ForegroundColor Cyan
Write-Host ""

