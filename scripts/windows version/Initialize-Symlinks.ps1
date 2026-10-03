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

# Function to create symlink
function New-Symlink {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [bool]$Force
    )

    # Already the right link: nothing to do.
    if (Test-LinkPointsTo -Path $LinkPath -Target $TargetPath) {
        Write-Host "[OK] Already linked: $LinkPath" -ForegroundColor Green
        return $true
    }

    # Get-LinkAwareItem (not Test-Path) so a dangling symlink still counts.
    if (Get-LinkAwareItem -Path $LinkPath) {
        if (Test-LinkIntoDirectory -Path $LinkPath -Directory $repoRoot) {
            # An old link of ours into the repo holds no user data: replace it
            # without a backup.
            Remove-Item -LiteralPath $LinkPath -Force
        }
        else {
            if (-not $Force) {
                $response = Read-Host "'$LinkPath' already exists. Overwrite? (y/n)"
                if ($response -ne "y") {
                    Write-Host "Skipped: $LinkPath" -ForegroundColor Yellow
                    return $false
                }
            }
            # A real file (or someone else's link): move it to a timestamped
            # backup rather than deleting it.
            try {
                $backupPath = Backup-UserFile -Path $LinkPath -Move
                Write-Host "[OK] Backed up existing $(Split-Path -Leaf $LinkPath) to $(Split-Path -Leaf $backupPath)" -ForegroundColor Yellow
            }
            catch {
                Write-Host "[FAIL] Could not back up $LinkPath; leaving it in place" -ForegroundColor Red
                Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -Force | Out-Null
        Write-Host "[OK] Created symlink: $LinkPath -> $TargetPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[FAIL] Failed to create symlink for $LinkPath" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
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
foreach ($file in $filesToLink) {
    $targetPath = Join-Path $repoRoot $file
    $linkPath = Join-Path $homeDir $file

    if (-not (Test-Path $targetPath)) {
        Write-Host "[FAIL] Source file not found: $targetPath" -ForegroundColor Red
        continue
    }

    if (New-Symlink -LinkPath $linkPath -TargetPath $targetPath -Force $Force) {
        $successCount++
    }
}

Write-Host ""
Write-Host "Setup Complete!" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Successfully linked $successCount file(s)" -ForegroundColor Green
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

Write-Host "Your .gitignore_global and gitconfig_helper.py are now symlinked from the repository." -ForegroundColor Cyan
Write-Host "Any changes pushed to the repository will be reflected in your home directory." -ForegroundColor Cyan
Write-Host ""

# Test the symlink by running 'git alias'
Write-Host "Testing symlink setup..." -ForegroundColor Cyan
try {
    git alias 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Symlinks verified! Git aliases are working." -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] git alias command failed. Verify symlinks manually with: git alias" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[WARN] Could not test symlinks. Verify manually with: git alias" -ForegroundColor Yellow
}

