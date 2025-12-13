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
    1. Deletes symlinks (.gitconfig and gitconfig_helper.py)
    2. Removes .gitconfig.local
    3. Deletes scheduled task (if it exists)
    4. Clears git SSH signing config

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

$filesToRemove = @(".gitconfig", "gitconfig_helper.py")

foreach ($file in $filesToRemove) {
    $path = Join-Path $homeDir $file
    if (Test-Path $path) {
        try {
            Remove-Item $path -Force
            Write-Host "[OK] Removed $file" -ForegroundColor Green
            $removed++
        }
        catch {
            Write-Host "[FAIL] Could not remove $file" -ForegroundColor Red
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
        Remove-Item $localConfigPath -Force
        Write-Host "[OK] Removed .gitconfig.local" -ForegroundColor Green
        $removed++
    }
    catch {
        Write-Host "[FAIL] Could not remove .gitconfig.local" -ForegroundColor Red
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

# STEP 4: Summary
Write-Host "[SUMMARY]" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Removed: $removed items" -ForegroundColor Green
Write-Host ""
Write-Host "Git config files still in repository are untouched." -ForegroundColor Cyan
Write-Host "You can now test the setup process from scratch." -ForegroundColor Cyan
Write-Host ""
