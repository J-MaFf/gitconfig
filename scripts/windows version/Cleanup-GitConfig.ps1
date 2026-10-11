# GitConfig Cleanup Script
# Removes all gitconfig-related symlinks, config files, and scheduled tasks
# Useful for testing fresh setup

param(
    [switch]$Help = $false,
    [switch]$Force = $false,
    [switch]$KeepLocal = $false,
    [switch]$KeepTask = $false,
    # Set by the elevated relaunch, not by hand (#240): the account that started
    # the cleanup and its profile and Documents folders, so elevating with an
    # administrator's password still cleans up the account that ran the script.
    [string]$InvokingUser = "",
    [string]$InvokingUserProfile = "",
    [string]$InvokingDocuments = "",
    # Also set by the relaunch: pause before the elevated window closes.
    [switch]$Elevated = $false
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
    -KeepTask   Leave the "GitConfig Pull at Login" scheduled task registered.
                Used by install.ps1 -Reinstall -NoTask, which does not register
                the task again.
    -Help       Display this help message

DESCRIPTION:
    Removes all gitconfig-related setup:
    1. Moves .gitconfig, .gitignore_global and gitconfig_helper.py away
    2. Moves .gitconfig.local away (unless -KeepLocal)
    3. Removes the Ctrl-G git-alias browser keybinding from your profile
    4. Deletes the "GitConfig Pull at Login" scheduled task (if it exists,
       and unless -KeepTask)
    5. Verifies the cleanup

    Removed files are kept as timestamped backups (<file>.bak.yyyyMMdd-HHmmss,
    newest 5 per file; set GITCONFIG_BACKUP_KEEP to change, 0 keeps all).
    The first backup of a file also keeps your original as
    <file>.pre-gitconfig, which is never pruned.
    Symlinks into this repo are removed without a backup.

    Exit status: 0 when everything was removed, 1 when the verification found
    something left behind. Run without elevation, the script relaunches itself
    as administrator and exits with the elevated run's status.

NOTE: Requires administrator privileges
"@
    exit 0
}

# Check if running as administrator - elevate if needed. The check is a
# function so the relaunch tests can stub it (tests/Backups.Tests.ps1).
function Test-IsAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Shared helpers: timestamped backups (Backup-UserFile), and the invoking-user
# handoff the relaunch below needs.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "Functions.ps1")

$isAdmin = Test-IsAdministrator
if (-not $isAdmin) {
    Write-Host "GitConfig Cleanup - Elevation Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This script requires administrator privileges to remove scheduled task." -ForegroundColor Yellow
    Write-Host ""

    # No -NoExit: the elevated window would then outlive the script and its
    # exit code would be lost. -Elevated makes it pause at the end instead.
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-Elevated")

    if ($Force) { $scriptArgs += "-Force" }
    if ($KeepLocal) { $scriptArgs += "-KeepLocal" }
    if ($KeepTask) { $scriptArgs += "-KeepTask" }
    # Who is running this, so an elevation with another account's password
    # still cleans up this account (#240).
    $scriptArgs += Get-InvokingUserArguments

    Write-Host "Relaunching with administrator privileges..." -ForegroundColor Cyan
    Write-Host ""

    try {
        $elevatedRun = Start-Process powershell -ArgumentList $scriptArgs -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-Host "Error: Could not elevate privileges: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    # Pass the elevated run's result on, so a caller sees an incomplete cleanup.
    if ($null -eq $elevatedRun -or $null -eq $elevatedRun.ExitCode) {
        Write-Host "Error: Could not read the elevated cleanup's exit code." -ForegroundColor Red
        exit 1
    }
    exit $elevatedRun.ExitCode
}

# Every exit from here on: the elevated relaunch runs in its own window, which
# closes as soon as the script ends, so pause first to keep the output readable.
function Exit-Cleanup([int]$Code) {
    if ($Elevated) {
        Write-Host ""
        Read-Host "Press Enter to close this window" | Out-Null
    }
    exit $Code
}

# Elevated with a different account's password: clean up the account that
# started the cleanup, not the administrator's (#240).
$cleanupUser = Use-InvokingUser -InvokingUser $InvokingUser -InvokingUserProfile $InvokingUserProfile -InvokingDocuments $InvokingDocuments

Write-Host "GitConfig Cleanup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
    Write-Host "WARNING: This will remove all gitconfig-related files and tasks." -ForegroundColor Yellow
    $confirm = Read-Host "Continue? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Exit-Cleanup 0
    }
}

$homeDir = $env:USERPROFILE
$removed = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

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
    # Both editions' profiles (#230), under the invoking account's Documents
    # after an account switch, else this account's.
    $widgetSeen = $false
    foreach ($profilePath in @(Get-ProfileScriptPath -Documents $cleanupUser.Documents)) {
        try {
            # Remove-MarkedBlock keeps the profile's encoding, BOM and line
            # endings (Set-Content under Windows PowerShell 5.1 rewrote it as ANSI).
            switch (Remove-MarkedBlock -Path $profilePath -BeginMarker $beginMarker -EndMarker $endMarker) {
                'Removed' {
                    Write-Host "[OK] Removed git-alias keybinding from $profilePath" -ForegroundColor Green
                    $removed++
                    $widgetSeen = $true
                }
                'Unterminated' {
                    Write-Host "[WARN] Found '$beginMarker' in $profilePath but no end marker; left the profile unchanged" -ForegroundColor Yellow
                    $widgetSeen = $true
                }
            }
        }
        catch {
            Write-Host "[WARN] Could not remove git-alias keybinding from ${profilePath}: $($_.Exception.Message)" -ForegroundColor Yellow
            $widgetSeen = $true
        }
    }
    if (-not $widgetSeen) {
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
$task = if ($KeepTask) { $null } else { Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }

if ($KeepTask) {
    Write-Host "[SKIP] Keeping the scheduled task (-KeepTask)" -ForegroundColor Yellow
}
elseif ($task) {
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

# Check symlinks were removed. Get-LinkAwareItem, not Test-Path: depending on
# the PowerShell version, Test-Path follows a symlink, so a dangling link that
# is still there would count as removed (#255). STEP 1 and 2 find the files
# the same way.
foreach ($file in $filesToRemove) {
    $path = Join-Path $homeDir $file
    if (Get-LinkAwareItem -Path $path) {
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
elseif (Get-LinkAwareItem -Path $localConfigPath) {
    Write-Host "[FAIL] .gitconfig.local still exists!" -ForegroundColor Red
    $verifyErrors++
}
else {
    Write-Host "[OK] .gitconfig.local removed" -ForegroundColor Green
}

# Check scheduled task was removed (skipped when intentionally kept)
if ($KeepTask) {
    Write-Host "[OK] Scheduled task kept (-KeepTask)" -ForegroundColor Green
}
elseif (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
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
if (-not (Get-LinkAwareItem -Path $gitconfigPath)) {
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
    if ($KeepTask) { Write-Host "All gitconfig-related files removed; the scheduled task was kept." -ForegroundColor Green }
    else { Write-Host "All gitconfig-related files and tasks removed." -ForegroundColor Green }
    Write-Host ""
    Write-Host "Ready to test fresh setup:" -ForegroundColor Cyan
    Write-Host "  .\install.ps1 -Force" -ForegroundColor Cyan
}
else {
    Write-Host "Cleanup INCOMPLETE - $verifyErrors items still present" -ForegroundColor Red
}
Write-Host ""

# Exit 1 when something was left behind, so a caller (install.ps1 -Reinstall,
# or a script) can tell (#240). It used to exit 0 either way.
if ($verifyErrors -gt 0) { Exit-Cleanup 1 }
Exit-Cleanup 0
