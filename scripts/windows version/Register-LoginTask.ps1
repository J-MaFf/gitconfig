# Register Windows Scheduled Task for Git Pull at Login
# This script creates a scheduled task to run Update-GitConfig.ps1 when the user logs in

param(
    [string]$ScriptPath = "$env:USERPROFILE\Documents\Scripts\gitconfig\scripts\Update-GitConfig.ps1",
    [switch]$Force
)

# Task configuration
$taskName = "GitConfig Pull at Login"
$taskDescription = "Automatically pull latest changes from gitconfig repository at user login"

# Check if script exists
if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: Script not found at $ScriptPath" -ForegroundColor Red
    exit 1
}

# Check if task already exists
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask -and -not $Force) {
    Write-Host "Scheduled task '$taskName' already exists." -ForegroundColor Yellow
    Write-Host "Use -Force flag to replace the existing task."
    exit 0
}

try {
    # Create task action (run PowerShell with the script)
    $action = New-ScheduledTaskAction `
        -Execute "PowerShell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -File `"$ScriptPath`""

    # Create task trigger (at login)
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    # Create task settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    # Register the task
    if ($existingTask -and $Force) {
        Write-Host "Removing existing task..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description $taskDescription `
        -Force | Out-Null

    Write-Host "SUCCESS: Scheduled task '$taskName' created." -ForegroundColor Green
    Write-Host "The script will run automatically at next login."
}
catch {
    Write-Host "ERROR: Failed to create scheduled task" -ForegroundColor Red
    Write-Host "Exception: $_" -ForegroundColor Red
    exit 1
}
