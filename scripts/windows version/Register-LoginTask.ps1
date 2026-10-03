# Register Windows Scheduled Task for Git Pull at Login
# This script creates a scheduled task to run Update-GitConfig.ps1 when the user logs in

param(
    [string]$ScriptPath = "",
    # Repo the task syncs. Defaults to the repo this script lives in, so a clone
    # outside ~/Documents/Scripts/gitconfig is synced too.
    [string]$RepoPath = "",
    [switch]$Force
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptPath) {
    $ScriptPath = Join-Path $scriptDir "Update-GitConfig.ps1"
}
if (-not $RepoPath) {
    $RepoPath = Split-Path -Parent (Split-Path -Parent $scriptDir)
}

# Task configuration
$taskName = "GitConfig Pull at Login"
$taskDescription = "Automatically pull latest changes from gitconfig repository at user login"
$taskUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }

# -ExecutionPolicy Bypass: Windows client editions default to Restricted, under
# which -File refuses to run the script at all. -RepoPath: pass the repo
# explicitly instead of relying on the updater's default.
$taskExecute = "PowerShell.exe"
$taskArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -RepoPath `"$RepoPath`""

# Check if script exists
if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: Script not found at $ScriptPath" -ForegroundColor Red
    exit 1
}

# Check if task already exists
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask -and -not $Force) {
    # Keep the task only if it already runs exactly what we would register. A
    # task left by an older install (moved repo, or arguments without
    # -ExecutionPolicy Bypass / -RepoPath) never works, so replace it.
    $existingAction = @($existingTask.Actions)[0]
    if ($existingAction -and $existingAction.Execute -eq $taskExecute -and $existingAction.Arguments -eq $taskArguments) {
        Write-Host "Scheduled task '$taskName' already exists and is up to date." -ForegroundColor Yellow
        Write-Host "Use -Force flag to replace the existing task."
        exit 0
    }
    Write-Host "Scheduled task '$taskName' points at an old path or uses old arguments; replacing it." -ForegroundColor Yellow
}

try {
    # Create task action (run PowerShell with the script)
    $action = New-ScheduledTaskAction `
        -Execute $taskExecute `
        -Argument $taskArguments

    # Create task trigger: at THIS user's logon (without -User it fires on any
    # user's logon), one minute late so the network is usually up for the pull.
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $trigger.Delay = 'PT1M'

    # Create task settings. A run is a pull plus a config render: stop it after
    # 10 minutes instead of the 72-hour default, and skip it when offline.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    # Register the task
    if ($existingTask) {
        Write-Host "Removing existing task..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description $taskDescription `
        -Force -ErrorAction Stop | Out-Null

    Write-Host "SUCCESS: Scheduled task '$taskName' created." -ForegroundColor Green
    Write-Host "The script will run automatically at next login."
    exit 0
}
catch {
    Write-Host "ERROR: Failed to create scheduled task" -ForegroundColor Red
    Write-Host "Exception: $_" -ForegroundColor Red
    exit 1
}
