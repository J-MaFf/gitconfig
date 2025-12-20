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
    1. Creates symlinks for .gitconfig and gitconfig_helper.py
    2. Generates machine-specific .gitconfig.local
    3. Creates Windows scheduled task for auto-sync (optional)
    4. Verifies the complete setup

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

    if ($Force) { $scriptArgs += "-Force" }
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

# Get paths
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$homeDir = $env:USERPROFILE
$scriptsDir = Join-Path $repoRoot "scripts"
$cleanupScript = Join-Path $scriptsDir "Cleanup-GitConfig.ps1"

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

# Define files to symlink (removed .gitconfig - now generated)
$filesToLink = @(
    @{ File = ".gitignore_global" },
    @{ File = "gitconfig_helper.py" }
)

# STEP 1: Generate .gitconfig from template
Write-Host "[STEP 1] Generating .gitconfig from template..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$generateScript = Join-Path $scriptsDir "Initialize-GitConfig.ps1"
if (Test-Path $generateScript) {
    try {
        if ($Force) {
            & $generateScript -Force | Out-Null
        }
        else {
            & $generateScript | Out-Null
        }
        Write-Host "[OK] Generated .gitconfig" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] Could not generate .gitconfig" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
else {
    Write-Host "[ERROR] Generator script not found: $generateScript" -ForegroundColor Red
}

Write-Host ""

# STEP 2: Create Symlinks
Write-Host "[STEP 2] Creating symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$linkErrors = 0
foreach ($item in $filesToLink) {
    $sourceFile = Join-Path $repoRoot $item.File
    $linkPath = Join-Path $homeDir $item.File

    if (-not (Test-Path $sourceFile)) {
        Write-Host "[ERROR] Source not found: $sourceFile" -ForegroundColor Red
        $linkErrors++
        continue
    }

    if (Test-Path $linkPath) {
        if (-not $Force) {
            $response = Read-Host "$($item.File) exists. Overwrite? (y/n)"
            if ($response -ne "y") {
                Write-Host "Skipped: $($item.File)" -ForegroundColor Yellow
                continue
            }
        }
        $backupName = "Existing.$($item.File).bak"
        $backupPath = Join-Path $homeDir $backupName
        try {
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force | Out-Null
            }
            Rename-Item -Path $linkPath -NewName $backupName -Force | Out-Null
            Write-Host "Backed up existing $($item.File) to $backupName" -ForegroundColor Yellow
        }
        catch {
            Write-Host "[WARN] Could not backup existing $($item.File), removing instead" -ForegroundColor Yellow
            Remove-Item $linkPath -Force | Out-Null
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceFile -Force | Out-Null
        Write-Host "[OK] Linked $($item.File)" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] Could not create symlink for $($item.File)" -ForegroundColor Red
        $linkErrors++
    }
}

Write-Host ""

# STEP 3: Generate Local Config
Write-Host "[STEP 3] Generating machine-specific configuration..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$localConfigPath = "$homeDir\.gitconfig.local"

if ((Test-Path $localConfigPath) -and -not $Force) {
    $response = Read-Host ".gitconfig.local exists. Overwrite? (y/n)"
    if ($response -ne "y") {
        Write-Host "Skipped: .gitconfig.local" -ForegroundColor Yellow
    }
}
else {
    try {
        $configContent = @"
# Machine-Specific Git Configuration
[core]
	excludesfile = $($homeDir -replace '\\', '/')/.gitignore_global

[gpg]
	format = ssh

[gpg "ssh"]
	program = $($homeDir -replace '\\', '/')/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe

[commit]
	gpgsign = true

[user]
	signingKey = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGjNJEhPFIZHo3t9aIb8Q2P4sY2AVV37/4eJoeDdREgB

[safe]
	directory = %(prefix)///10.210.3.10/dept/IT/PC Setup/winget-app-setup
	directory = %(prefix)///10.210.3.10/dept/IT/Programs/Office/OfficeConfigs
	directory = %(prefix)///KFWS9BDC01/DEPT/IT/Programs/Office/OfficeConfigs
	directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-app-setup
	directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-install
"@
        Set-Content -Path $localConfigPath -Value $configContent -Force
        Write-Host "[OK] Created .gitconfig.local" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] Could not create .gitconfig.local" -ForegroundColor Red
    }
}

Write-Host ""

# STEP 4: Configure Global Gitignore
Write-Host "[STEP 4] Configuring global gitignore..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$gitignoreGlobalPath = "$homeDir\.gitignore_global"
if (Test-Path $gitignoreGlobalPath) {
    try {
        # Convert path to forward slashes for git config
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

# STEP 5: Create Scheduled Task
if (-not $NoTask) {
    Write-Host "[STEP 5] Setting up scheduled task..." -ForegroundColor Cyan
    Write-Host "-----" -ForegroundColor Cyan

    $taskName = "GitConfig Pull at Login"
    $scriptPath = Join-Path $scriptsDir "Update-GitConfig.ps1"

    if (-not (Test-Path $scriptPath)) {
        Write-Host "[WARN] Update-GitConfig.ps1 not found" -ForegroundColor Yellow
    }
    else {
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($existingTask -and -not $Force) {
            $response = Read-Host "Task exists. Replace? (y/n)"
            if ($response -ne "y") {
                Write-Host "Skipped: Scheduled task" -ForegroundColor Yellow
            }
            else {
                try {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
                    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
                    $trigger = New-ScheduledTaskTrigger -AtLogOn
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
                    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Auto-pull gitconfig at login" -Force | Out-Null
                    Write-Host "[OK] Created scheduled task" -ForegroundColor Green
                }
                catch {
                    Write-Host "[FAIL] Could not create scheduled task" -ForegroundColor Red
                }
            }
        }
        else {
            try {
                if ($existingTask) {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
                }
                $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Auto-pull gitconfig at login" -Force | Out-Null
                Write-Host "[OK] Created scheduled task" -ForegroundColor Green
            }
            catch {
                Write-Host "[FAIL] Could not create scheduled task" -ForegroundColor Red
            }
        }
    }
    Write-Host ""
}

# STEP 6: Verify Setup
Write-Host "[STEP 6] Verifying setup..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

# Verify generated .gitconfig
$gitconfigPath = Join-Path $homeDir ".gitconfig"
if (Test-Path $gitconfigPath) {
    Write-Host "[OK] .gitconfig verified" -ForegroundColor Green
}
else {
    Write-Host "[FAIL] .gitconfig missing" -ForegroundColor Red
}

# Verify symlinks
foreach ($item in $filesToLink) {
    $linkPath = Join-Path $homeDir $item.File
    if (Test-Path $linkPath) {
        Write-Host "[OK] $($item.File) verified" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $($item.File) missing" -ForegroundColor Red
    }
}

if (Test-Path $localConfigPath) {
    Write-Host "[OK] .gitconfig.local verified" -ForegroundColor Green
}
else {
    Write-Host "[FAIL] .gitconfig.local missing" -ForegroundColor Red
}

try {
    &git alias | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git aliases working" -ForegroundColor Green
    }
}
catch {
    Write-Host "[WARN] Could not verify git aliases" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup Complete!" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
