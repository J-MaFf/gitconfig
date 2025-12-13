# Initialize Machine-Specific Git Configuration
# This script creates ~/.gitconfig.local with machine-specific paths and safe directories
# Usage: .\Initialize-LocalConfig.ps1

param(
    [switch]$Force = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
Initialize Machine-Specific Git Configuration

USAGE:
    .\Initialize-LocalConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing .gitconfig.local without prompting
    -Help       Display this help message

DESCRIPTION:
    Creates ~/.gitconfig.local with machine-specific safe directories and paths.
    This file is included by the main .gitconfig and should NOT be version controlled.

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    .\Initialize-LocalConfig.ps1

    # Force mode (overwrites without prompting)
    .\Initialize-LocalConfig.ps1 -Force

SAFE DIRECTORIES:
    Add network locations and local paths that git should trust.
    Common examples:
    - Network shares (e.g., \\server\share\repo)
    - Local development directories
    - Work-specific repositories
"@
    exit 0
}

$homeDir = $env:USERPROFILE
$localConfigPath = "$homeDir\.gitconfig.local"

Write-Host "Git Local Configuration Setup" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host "Local Config Path: $localConfigPath" -ForegroundColor Green
Write-Host ""

# Check if .gitconfig.local already exists
if ((Test-Path $localConfigPath) -and -not $Force) {
    Write-Host ".gitconfig.local already exists." -ForegroundColor Yellow
    $response = Read-Host "Overwrite? (y/n)"
    if ($response -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

try {
    $configContent = @"
# Machine-Specific Git Configuration
# This file is automatically included by .gitconfig and should NOT be committed

[gpg "ssh"]
	# Machine-specific SSH signing program path
	program = $($homeDir -replace '\\', '/')/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe

[safe]
	# Network locations (make sure these paths exist on this machine)
	directory = %(prefix)///10.210.3.10/dept/IT/PC Setup/winget-app-setup
	directory = %(prefix)///10.210.3.10/dept/IT/Programs/Office/OfficeConfigs
	directory = %(prefix)///KFWS9BDC01/DEPT/IT/Programs/Office/OfficeConfigs

	# Local development directories
	directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-app-setup
	directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-install
"@

    # Create or overwrite the local config file
    Set-Content -Path $localConfigPath -Value $configContent -Force
    Write-Host "[OK] Created .gitconfig.local" -ForegroundColor Green
    Write-Host ""
    Write-Host "Local configuration includes:" -ForegroundColor Cyan
    Write-Host "  - SSH signing program path (op-ssh-sign.exe)" -ForegroundColor Gray
    Write-Host "  - Network safe directories (10.210.3.10, KFWS9BDC01)" -ForegroundColor Gray
    Write-Host "  - Local development directories" -ForegroundColor Gray
    Write-Host ""
    Write-Host "To customize safe directories:" -ForegroundColor Cyan
    Write-Host "  1. Edit $localConfigPath" -ForegroundColor Gray
    Write-Host "  2. Add or modify entries in the [safe] section" -ForegroundColor Gray
    Write-Host "  3. Save and reload git" -ForegroundColor Gray
    Write-Host ""

    # Verify git can read the config
    Write-Host "Verifying git configuration..." -ForegroundColor Cyan
    $gitTest = & git config --local --list 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git configuration verified!" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Git may have issues reading the configuration" -ForegroundColor Yellow
        Write-Host "  Run: git config --list to diagnose" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[FAIL] Error creating .gitconfig.local" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
