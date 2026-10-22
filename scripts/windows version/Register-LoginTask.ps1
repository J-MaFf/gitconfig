# Register Windows Scheduled Task for Git Pull at Login
# This script creates a scheduled task to run Update-GitConfig.ps1 when the user logs in

param(
    [string]$ScriptPath = "",
    # Repo the task syncs. Defaults to the repo this script lives in, so a clone
    # anywhere (not only ~/Scripts/gitconfig) is synced.
    [string]$RepoPath = "",
    # Account the task runs for (DOMAIN\user). Defaults to the current account;
    # install.ps1 passes the account that started it, which differs after an
    # elevation with another account's password (#240).
    [string]$TaskUser = "",
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
$taskUser = if ($TaskUser) { $TaskUser } elseif ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }

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
    # A task registered with "Start only if the network is available" (every
    # install before #256) is replaced too: that condition skipped the whole run
    # when the network came up late, including the offline-safe convergence.
    # A task that runs as another account is replaced too: one registered from
    # an elevation with an administrator's password ran as the administrator
    # (#240). Task Scheduler may report the user with or without the domain, so
    # compare the names after the last backslash.
    $existingAction = @($existingTask.Actions)[0]
    $needsNetwork = $existingTask.Settings -and $existingTask.Settings.RunOnlyIfNetworkAvailable
    $existingUser = if ($existingTask.Principal) { "$($existingTask.Principal.UserId)" } else { "" }
    $otherUser = $existingUser -and (($existingUser -split '\\')[-1] -ne ($taskUser -split '\\')[-1])
    if ($existingAction -and $existingAction.Execute -eq $taskExecute -and $existingAction.Arguments -eq $taskArguments -and -not $needsNetwork -and -not $otherUser) {
        Write-Host "Scheduled task '$taskName' already exists and is up to date." -ForegroundColor Yellow
        Write-Host "Use -Force flag to replace the existing task."
        exit 0
    }
    Write-Host "Scheduled task '$taskName' points at an old path, uses old arguments or settings, or runs as another account; replacing it." -ForegroundColor Yellow
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

    # Run as that user, only while they are logged on (no stored password).
    # Without -Principal the task ran as whoever registered it, which after an
    # elevation with another account's password is the administrator (#240).
    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive

    # Create task settings. A run is a pull plus a config render: stop it after
    # 10 minutes instead of the 72-hour default. No -RunOnlyIfNetworkAvailable:
    # rendering ~/.gitconfig from the local template needs no network, and the
    # updater already logs a failed pull or fetch and carries on (#256). With the
    # condition, a network that came up late skipped the whole run.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
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
        -Principal $principal `
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
