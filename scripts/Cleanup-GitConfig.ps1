# GitConfig Cleanup Script
# Removes all gitconfig-related symlinks, config files, and scheduled tasks
# Useful for testing fresh setup

param(
    [switch]$Help = $false,
    [switch]$Force = $false
)

if ($Help) {
    Write-Host @"
GitConfig Cleanup Script

USAGE: .\Cleanup-GitConfig.ps1 [OPTIONS]

OPTIONS:
    -Force   Skip confirmation prompts
    -Help    Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Backs up and removes .gitconfig (generated file)
    2. Removes symlinks (.gitignore_global and gitconfig_helper.py)
    3. Removes .gitconfig.local
    4. Deletes scheduled task (if it exists)
    5. Clears git SSH signing config

NOTE: Requires administrator privileges
"@
    exit 0
}

# Check if running as administrator - elevate if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "GitConfig Cleanup - Elevation Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This script requires administrator privileges to remove scheduled task." -ForegroundColor Yellow
    Write-Host ""

    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$scriptPath`"")

    if ($Force) { $scriptArgs += "-Force" }

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

Write-Host "GitConfig Cleanup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
    Write-Host "WARNING: This will remove all gitconfig-related files and tasks." -ForegroundColor Yellow
    $confirm = Read-Host "Continue? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$homeDir = $env:USERPROFILE
$removed = 0

# STEP 1: Remove Symlinks
Write-Host "[STEP 1] Removing symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$filesToRemove = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py")

foreach ($file in $filesToRemove) {
    $path = Join-Path $homeDir $file
    if (Test-Path $path) {
        try {
            $backupName = "Existing.$file.bak"
            $backupPath = Join-Path $homeDir $backupName
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force | Out-Null
            }
            Rename-Item -Path $path -NewName $backupName -Force | Out-Null
            Write-Host "[OK] Backed up $file to $backupName" -ForegroundColor Green
            $removed++
        }
        catch {
            Write-Host "[FAIL] Could not backup $file" -ForegroundColor Red
            Write-Host "  Error: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "[SKIP] $file not found" -ForegroundColor Yellow
    }
}

Write-Host ""

# STEP 2: Remove .gitconfig.local
Write-Host "[STEP 2] Removing .gitconfig.local..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$localConfigPath = "$homeDir\.gitconfig.local"
if (Test-Path $localConfigPath) {
    try {
        $backupName = "Existing.gitconfig.local.bak"
        $backupPath = Join-Path $homeDir $backupName
        if (Test-Path $backupPath) {
            Remove-Item $backupPath -Force | Out-Null
        }
        Rename-Item -Path $localConfigPath -NewName $backupName -Force | Out-Null
        Write-Host "[OK] Backed up .gitconfig.local to $backupName" -ForegroundColor Green
        $removed++
    }
    catch {
        Write-Host "[FAIL] Could not backup .gitconfig.local" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "[SKIP] .gitconfig.local not found" -ForegroundColor Yellow
}

Write-Host ""

# STEP 3: Remove Scheduled Task
Write-Host "[STEP 3] Removing scheduled task..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$taskName = "GitConfig Pull at Login"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($task) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        Write-Host "[OK] Removed scheduled task" -ForegroundColor Green
        $removed++
    }
    catch {
        Write-Host "[FAIL] Could not remove scheduled task" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "[SKIP] Scheduled task not found" -ForegroundColor Yellow
}

Write-Host ""

# STEP 4: Verify Cleanup Success
Write-Host "[STEP 4] Verifying cleanup..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$verifyErrors = 0

# Check symlinks were removed
foreach ($file in $filesToRemove) {
    $path = Join-Path $homeDir $file
    if (Test-Path $path) {
        Write-Host "[FAIL] $file still exists!" -ForegroundColor Red
        $verifyErrors++
    }
    else {
        Write-Host "[OK] $file removed" -ForegroundColor Green
    }
}

# Check .gitconfig.local was removed
if (Test-Path $localConfigPath) {
    Write-Host "[FAIL] .gitconfig.local still exists!" -ForegroundColor Red
    $verifyErrors++
}
else {
    Write-Host "[OK] .gitconfig.local removed" -ForegroundColor Green
}

# Check scheduled task was removed
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "[FAIL] Scheduled task still exists!" -ForegroundColor Red
    $verifyErrors++
}
else {
    Write-Host "[OK] Scheduled task removed" -ForegroundColor Green
}

# Check git still works
try {
    $gitVersion = & git --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git still functional" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Git may be unavailable" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[WARN] Could not verify git" -ForegroundColor Yellow
}

# Check custom aliases are not available
# (custom aliases are defined in .gitconfig, so if it's removed, aliases won't work)
$gitconfigPath = Join-Path $homeDir ".gitconfig"
if (-not (Test-Path $gitconfigPath)) {
    Write-Host "[OK] Custom aliases not available (.gitconfig removed)" -ForegroundColor Green
}
else {
    Write-Host "[WARN] .gitconfig still exists - custom aliases may be available" -ForegroundColor Yellow
}

Write-Host ""

# STEP 5: Summary
Write-Host "[SUMMARY]" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

if ($verifyErrors -eq 0) {
    Write-Host "Cleanup SUCCESSFUL!" -ForegroundColor Green
    Write-Host "All gitconfig-related files and tasks removed." -ForegroundColor Green
    Write-Host ""
    Write-Host "Ready to test fresh setup:" -ForegroundColor Cyan
    Write-Host "  .\Setup-GitConfig.ps1 -Force" -ForegroundColor Cyan
}
else {
    Write-Host "Cleanup INCOMPLETE - $verifyErrors items still present" -ForegroundColor Red
}
Write-Host ""
