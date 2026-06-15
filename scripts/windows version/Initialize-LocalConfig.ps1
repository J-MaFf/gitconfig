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

function Update-AllowedSigners {
    # Upserts the current signing identity into ~/.ssh/allowed_signers so git can
    # verify SSH commit signatures locally. Reads the signing key and email from
    # the already-generated ~/.gitconfig (git config). Idempotent: re-running does
    # not duplicate the line, and existing entries for other identities are kept.
    param([Parameter(Mandatory)][string]$AllowedSignersPath)

    $signingKey = (& git config --get user.signingkey 2>$null)
    $signerEmail = (& git config --get user.email 2>$null)

    if ([string]::IsNullOrWhiteSpace($signingKey) -or [string]::IsNullOrWhiteSpace($signerEmail)) {
        Write-Host "[WARN] No user.signingkey/user.email configured; skipped allowed_signers" -ForegroundColor Yellow
        return
    }

    # Resolve the public key: either the literal key (1Password) or a *.pub file.
    $pubKey = $null
    if ($signingKey -match '^(ssh-|sk-ssh-|ecdsa-)') {
        $pubKey = $signingKey.Trim()
    }
    else {
        $candidate = if ($signingKey -match '\.pub$') { $signingKey } else { "$signingKey.pub" }
        if (Test-Path $candidate) {
            $pubKey = (Get-Content $candidate -Raw).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($pubKey)) {
        Write-Host "[WARN] Could not resolve signing public key; skipped allowed_signers" -ForegroundColor Yellow
        return
    }

    # Normalize to "<keytype> <base64>" - drop any trailing comment so the line is
    # valid allowed_signers syntax.
    $parts = $pubKey -split '\s+'
    if ($parts.Count -ge 2) {
        $pubKey = "$($parts[0]) $($parts[1])"
    }

    $sshDir = Split-Path -Parent $AllowedSignersPath
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $line = "$signerEmail namespaces=`"git`" $pubKey"
    $existing = @()
    if (Test-Path $AllowedSignersPath) {
        $existing = @(Get-Content $AllowedSignersPath)
    }
    if ($existing -contains $line) {
        Write-Host "[OK] allowed_signers already up to date" -ForegroundColor Green
    }
    else {
        Add-Content -Path $AllowedSignersPath -Value $line
        Write-Host "[OK] Updated $AllowedSignersPath" -ForegroundColor Green
    }
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

[core]
	# Use global gitignore file
	excludesfile = $($homeDir -replace '\\', '/')/.gitignore_global

[gpg "ssh"]
	# Machine-specific SSH signing program path
	program = $($homeDir -replace '\\', '/')/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe
	# Lets git verify SSH commit signatures locally (git log --show-signature, verify-commit)
	allowedSignersFile = $($homeDir -replace '\\', '/')/.ssh/allowed_signers

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

    # Build ~/.ssh/allowed_signers so git can verify SSH commit signatures locally.
    # Without this file, `git log --show-signature` and `git verify-commit` report
    # "No signature" even though commits are signed (and GitHub shows Verified).
    $allowedSignersPath = Join-Path $homeDir ".ssh\allowed_signers"
    Update-AllowedSigners -AllowedSignersPath $allowedSignersPath

    Write-Host ""
    Write-Host "Local configuration includes:" -ForegroundColor Cyan
    Write-Host "  - SSH signing program path (op-ssh-sign.exe)" -ForegroundColor Gray
    Write-Host "  - Allowed signers file for local signature verification" -ForegroundColor Gray
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
    & git config --local --list 2>&1 | Out-Null
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
