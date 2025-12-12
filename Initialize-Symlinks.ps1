# Dotfiles Symlink Setup Script
# This script creates symbolic links from the home directory to the dotfiles repository
# Usage: .\setup-symlinks.ps1
# Note: Requires admin privileges to create symlinks on Windows

param(
    [switch]$Force = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
Dotfiles Symlink Setup Script

USAGE:
    .\setup-symlinks.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing files without prompting
    -Help       Display this help message

DESCRIPTION:
    Creates symbolic links from your home directory (~) to the dotfiles repository.

REQUIREMENTS:
    - Administrator privileges (for creating symlinks on Windows)
    - PowerShell 7+ recommended, but works with Windows PowerShell 5.1+

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    .\setup-symlinks.ps1

    # Force mode (overwrites without prompting)
    .\setup-symlinks.ps1 -Force

FILES LINKED:
    - .gitconfig
    - gitconfig_helper.py
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

# Get the repository root (script's directory)
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
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
        Write-Host "✓ Created symlink: $LinkPath -> $TargetPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Failed to create symlink for $LinkPath" -ForegroundColor Red
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
        Write-Host "✗ Source file not found: $targetPath" -ForegroundColor Red
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
Write-Host "Your .gitconfig and .gitconfig_helper.py are now symlinked from the repository." -ForegroundColor Cyan
Write-Host "Any changes pushed to the repository will be reflected in your home directory." -ForegroundColor Cyan
