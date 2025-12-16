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
    -Force      Overwrite existing files without prompting
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
    - .gitconfig
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

# Get the repository root (parent of scripts directory)
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$homeDir = $env:USERPROFILE

Write-Host "Dotfiles Setup" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host ""

# Define files to symlink
$filesToLink = @(
    ".gitconfig",
    "gitconfig_helper.py"
)

# Function to create symlink
function New-Symlink {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [bool]$Force
    )

    if (Test-Path $LinkPath) {
        if (-not $Force) {
            $response = Read-Host "'$LinkPath' already exists. Overwrite? (y/n)"
            if ($response -ne "y") {
                Write-Host "Skipped: $LinkPath" -ForegroundColor Yellow
                return $false
            }
        }
        Remove-Item $LinkPath -Force | Out-Null
        Write-Host "Removed existing: $LinkPath" -ForegroundColor Yellow
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

# Function to create scheduled task for git pull at login
function Register-LoginTask {
    param(
        [string]$RepoRoot,
        [bool]$Force
    )

    $taskName = "GitConfig Pull at Login"
    $scriptPath = Join-Path $repoRoot "scripts\Update-GitConfig.ps1"

    # Check if script exists
    if (-not (Test-Path $scriptPath)) {
        Write-Host "[WARN] Update-GitConfig.ps1 not found at $scriptPath" -ForegroundColor Yellow
        Write-Host "  Skipping scheduled task creation." -ForegroundColor Yellow
        return $false
    }

    # Check if task already exists
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($existingTask) {
        if (-not $Force) {
            $response = Read-Host "Scheduled task '$taskName' already exists. Replace? (y/n)"
            if ($response -ne "y") {
                Write-Host "Skipped scheduled task" -ForegroundColor Yellow
                return $false
            }
        }
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
            Write-Host "Removed existing scheduled task: $taskName" -ForegroundColor Yellow
        }
        catch {
            Write-Host "[FAIL] Failed to remove existing scheduled task" -ForegroundColor Red
            return $false
        }
    }

    try {
        # Create task action
        $action = New-ScheduledTaskAction `
            -Execute "PowerShell.exe" `
            -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""

        # Create task trigger (at login)
        $trigger = New-ScheduledTaskTrigger -AtLogOn

        # Create task settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable

        # Register the task
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description "Automatically pull latest changes from gitconfig repository at user login" `
            -Force | Out-Null

        Write-Host "[OK] Created scheduled task: $taskName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[FAIL] Failed to create scheduled task" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
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

Write-Host "Your .gitconfig and gitconfig_helper.py are now symlinked from the repository." -ForegroundColor Cyan
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

