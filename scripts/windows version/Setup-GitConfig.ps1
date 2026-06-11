# GitConfig Setup Wrapper
# Orchestrates complete setup of portable git configuration
# Requires administrator privileges

param(
    [switch]$Force = $false,
    [switch]$NoTask = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
GitConfig Setup Wrapper

USAGE: .\Setup-GitConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing files without prompting
    -NoTask     Skip Windows scheduled task creation
    -Help       Display this help message

DESCRIPTION:
    1. Generates machine-specific .gitconfig from template
    2. Creates symlinks (.gitconfig, .gitignore_global, gitconfig_helper.py)
    3. Generates machine-specific .gitconfig.local
    4. Creates Windows scheduled task for auto-sync (optional)
    5. Verifies the complete setup

REQUIREMENTS: Administrator privileges
"@
    exit 0
}

# Check if running as administrator - elevate if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "GitConfig Setup - Elevation Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This script requires administrator privileges to create symlinks and scheduled task." -ForegroundColor Yellow
    Write-Host ""

    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$scriptPath`"")
    if ($Force)  { $scriptArgs += "-Force" }
    if ($NoTask) { $scriptArgs += "-NoTask" }

    Write-Host "Relaunching with administrator privileges..." -ForegroundColor Cyan
    Write-Host ""

    try {
        Start-Process powershell -ArgumentList $scriptArgs -Verb RunAs -Wait -ErrorAction Stop
        exit 0
    }
    catch {
        Write-Host "Error: Could not elevate privileges." -ForegroundColor Red
        exit 1
    }
}

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot    = Split-Path -Parent (Split-Path -Parent $scriptDir)
$homeDir     = $env:USERPROFILE
$scriptsDir  = $scriptDir
$cleanupScript     = Join-Path $scriptsDir "Cleanup-GitConfig.ps1"
$initGitScript     = Join-Path $scriptsDir "Initialize-GitConfig.ps1"
$initLocalScript   = Join-Path $scriptsDir "Initialize-LocalConfig.ps1"
$initSymlinksScript = Join-Path $scriptsDir "Initialize-Symlinks.ps1"
$registerTaskScript = Join-Path $scriptsDir "Register-LoginTask.ps1"

Write-Host "GitConfig Setup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host ""

# STEP 0: Clean up any existing installation first
Write-Host "[STEP 0] Cleaning up previous installation..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    & $cleanupScript -Force -ErrorAction Stop | Out-Null
    Write-Host "[OK] Previous installation cleaned up" -ForegroundColor Green
}
catch {
    Write-Host "[WARN] No previous installation found or cleanup failed (this is OK)" -ForegroundColor Yellow
}
Write-Host ""

# STEP 1: Generate .gitconfig from template
Write-Host "[STEP 1] Generating .gitconfig from template..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    if ($Force) { & $initGitScript -Force | Out-Null } else { & $initGitScript | Out-Null }
    Write-Host "[OK] Generated .gitconfig" -ForegroundColor Green
}
catch {
    Write-Host "[FAIL] Could not generate .gitconfig: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# STEP 2: Create symlinks (delegates to Initialize-Symlinks.ps1)
Write-Host "[STEP 2] Creating symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    if ($Force) { & $initSymlinksScript -Force } else { & $initSymlinksScript }
}
catch {
    Write-Host "[FAIL] Symlink setup failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# STEP 3: Generate local config
Write-Host "[STEP 3] Generating machine-specific configuration..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    if ($Force) { & $initLocalScript -Force | Out-Null } else { & $initLocalScript | Out-Null }
    Write-Host "[OK] Generated .gitconfig.local" -ForegroundColor Green
}
catch {
    Write-Host "[FAIL] Could not generate .gitconfig.local: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# STEP 4: Configure global gitignore
Write-Host "[STEP 4] Configuring global gitignore..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
$gitignoreGlobalPath = "$homeDir\.gitignore_global"
if (Test-Path $gitignoreGlobalPath) {
    try {
        $gitignoreGlobalForward = $gitignoreGlobalPath -replace '\\', '/'
        & git config --global core.excludesfile $gitignoreGlobalForward
        Write-Host "[OK] Configured global excludesfile" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] Could not configure global excludesfile" -ForegroundColor Red
    }
}
else {
    Write-Host "[WARN] .gitignore_global symlink not found" -ForegroundColor Yellow
}
Write-Host ""

# STEP 5: Create scheduled task (delegates to Register-LoginTask.ps1)
if (-not $NoTask) {
    Write-Host "[STEP 5] Setting up scheduled task..." -ForegroundColor Cyan
    Write-Host "-----" -ForegroundColor Cyan
    try {
        if ($Force) { & $registerTaskScript -Force } else { & $registerTaskScript }
    }
    catch {
        Write-Host "[FAIL] Scheduled task setup failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
}

# STEP 6: Verify setup
Write-Host "[STEP 6] Verifying setup..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$verifyFiles = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py", ".gitconfig.local")
foreach ($file in $verifyFiles) {
    $path = Join-Path $homeDir $file
    if (Test-Path $path) { Write-Host "[OK] $file verified" -ForegroundColor Green }
    else                  { Write-Host "[FAIL] $file missing" -ForegroundColor Red }
}

try {
    & git alias | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Git aliases working" -ForegroundColor Green }
}
catch {
    Write-Host "[WARN] Could not verify git aliases" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup Complete!" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
