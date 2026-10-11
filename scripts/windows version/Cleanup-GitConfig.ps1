# GitConfig Cleanup Script
# Removes all gitconfig-related symlinks, config files, and scheduled tasks
# Useful for testing fresh setup

param(
    [switch]$Help = $false,
    [switch]$Force = $false,
    [switch]$KeepLocal = $false
)

if ($Help) {
    Write-Host @"
GitConfig Cleanup Script

USAGE: .\Cleanup-GitConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Skip confirmation prompts
    -KeepLocal  Preserve ~/.gitconfig.local (machine-specific user config).
                Used by install.ps1 -Reinstall so re-running setup never wipes
                hand-tuned safe.directory entries, etc.
    -Help       Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Moves .gitconfig, .gitignore_global and gitconfig_helper.py away
    2. Moves .gitconfig.local away (unless -KeepLocal)
    3. Removes the Ctrl-G git-alias browser keybinding from your profile
    4. Deletes the "GitConfig Pull at Login" scheduled task (if it exists)
    5. Verifies the cleanup

    Removed files are kept as timestamped backups (<file>.bak.yyyyMMdd-HHmmss,
    newest 5 per file; set GITCONFIG_BACKUP_KEEP to change, 0 keeps all).
    The first backup of a file also keeps your original as
    <file>.pre-gitconfig, which is never pruned.
    Symlinks into this repo are removed without a backup.

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
    if ($KeepLocal) { $scriptArgs += "-KeepLocal" }

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
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

# Shared helpers: timestamped backups (Backup-UserFile).
. (Join-Path $scriptDir "Functions.ps1")

# Move Path to a timestamped backup (or just remove it if it is a symlink into
# the repo) and report what happened. Returns $true if Path is gone.
function Remove-WithBackup {
    param([string]$Path)
    $file = Split-Path -Leaf $Path
    try {
        $backupPath = Backup-UserFile -Path $Path -Move -RepoRoot $repoRoot
        if ($backupPath) {
            Write-Host "[OK] Backed up $file to $(Split-Path -Leaf $backupPath)" -ForegroundColor Green
        }
        else {
            Write-Host "[OK] Removed $file (symlink into the repo; no backup needed)" -ForegroundColor Green
        }
        return $true
    }
    catch {
        Write-Host "[FAIL] Could not backup $file" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        return $false
    }
}

# STEP 1: Remove Symlinks
Write-Host "[STEP 1] Removing symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$filesToRemove = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py")

foreach ($file in $filesToRemove) {
    $path = Join-Path $homeDir $file
    if (Get-LinkAwareItem -Path $path) {
        if (Remove-WithBackup -Path $path) { $removed++ }
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
if ($KeepLocal) {
    Write-Host "[SKIP] Preserving .gitconfig.local (-KeepLocal)" -ForegroundColor Yellow
}
elseif (Get-LinkAwareItem -Path $localConfigPath) {
    if (Remove-WithBackup -Path $localConfigPath) { $removed++ }
}
else {
    Write-Host "[SKIP] .gitconfig.local not found" -ForegroundColor Yellow
}

Write-Host ""

# STEP 2b: Remove the git-alias browser keybinding from the PowerShell profile
Write-Host "[STEP 2b] Removing git-alias browser keybinding..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    $beginMarker = "# >>> gitconfig git-alias browser (Ctrl-G) >>>"
    $endMarker = "# <<< gitconfig git-alias browser <<<"
    $profilePath = $PROFILE.CurrentUserAllHosts
    if ((Test-Path $profilePath) -and ((Get-Content -Raw $profilePath).Contains($beginMarker))) {
        $kept = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($line in Get-Content $profilePath) {
            if ($line -eq $beginMarker) { $skip = $true; continue }
            if ($skip -and $line -eq $endMarker) { $skip = $false; continue }
            if (-not $skip) { $kept.Add($line) }
        }
        Set-Content -Path $profilePath -Value $kept
        Write-Host "[OK] Removed git-alias keybinding from profile" -ForegroundColor Green
        $removed++
    }
    else {
        Write-Host "[SKIP] git-alias keybinding not present" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[WARN] Could not remove git-alias keybinding: $($_.Exception.Message)" -ForegroundColor Yellow
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

# Check .gitconfig.local was removed (skipped when intentionally preserved)
if ($KeepLocal) {
    Write-Host "[OK] .gitconfig.local preserved (-KeepLocal)" -ForegroundColor Green
}
elseif (Test-Path $localConfigPath) {
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
    & git --version > $null 2>&1
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
    Write-Host "  .\install.ps1 -Force" -ForegroundColor Cyan
}
else {
    Write-Host "Cleanup INCOMPLETE - $verifyErrors items still present" -ForegroundColor Red
}
Write-Host ""
