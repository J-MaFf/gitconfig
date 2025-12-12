# GitConfig Setup Wrapper
# This script orchestrates the complete setup of the portable git configuration system
# Requires administrator privileges
# Usage: .\Setup-GitConfig.ps1 [-Force] [-NoTask]

param(
    [switch]$Force = $false,
    [switch]$NoTask = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
GitConfig Setup Wrapper

USAGE:
    .\Setup-GitConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing files without prompting
    -NoTask     Skip Windows scheduled task creation
    -Help       Display this help message

DESCRIPTION:
    Orchestrates complete setup of the portable git configuration system:
    1. Creates symlinks for .gitconfig and gitconfig_helper.py
    2. Generates machine-specific .gitconfig.local
    3. Creates Windows scheduled task for auto-sync (optional)
    4. Verifies the complete setup

REQUIREMENTS:
    - Administrator privileges (required)
    - PowerShell 5.1+ or PowerShell 7+
    - Git 2.x+

EXAMPLE:
    # Complete setup with prompts
    .\Setup-GitConfig.ps1

    # Force setup without prompts, skip scheduled task
    .\Setup-GitConfig.ps1 -Force -NoTask

NEXT STEPS AFTER SETUP:
    - Test with: git alias
    - Edit machine paths: git localconfig
    - Verify SSH signing: git config gpg.ssh.program
"@
    exit 0
}

# Check if running as administrator - elevate if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "GitConfig Setup - Elevation Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This script requires administrator privileges to:" -ForegroundColor Yellow
    Write-Host "  - Create symbolic links" -ForegroundColor Gray
    Write-Host "  - Create Windows scheduled task" -ForegroundColor Gray
    Write-Host ""

    # Re-run script as administrator
    $scriptPath = $MyInvocation.MyCommand.Path
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")

    # Preserve script arguments
    if ($Force) { $args += "-Force" }
    if ($NoTask) { $args += "-NoTask" }    if ($NoTask) { $args += "-NoTask" }

    Write-Host "Relaunching with administrator privileges..." -ForegroundColor Cyanelaunching with administrator privileges..." -ForegroundColor Cyan
    Write-Host ""    Write-Host ""

    try {
        Start-Process powershell -ArgumentList $args -Verb RunAs -Wait -ErrorAction StopProcess powershell -ArgumentList $args -Verb RunAs -Wait -ErrorAction Stop
        exit 0   exit 0
    }
    catch {
        Write-Host "Error: Could not elevate privileges. Please run as administrator." -ForegroundColor RedHost "Error: Could not elevate privileges. Please run as administrator." -ForegroundColor Red
        exit 1   exit 1
    }   }
}}

# Get paths
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)ent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$homeDir = $env:USERPROFILE
$scriptsDir = Join-Path $repoRoot "scripts"$scriptsDir = Join-Path $repoRoot "scripts"

Write-Host "GitConfig Setup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor CyanroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Greenome Directory: $homeDir" -ForegroundColor Green
    Write-Host ""Write-Host ""

    # Define files to symlink
    $filesToLink = @(
        @{ File = ".gitconfig"; Description = "Git configuration" }, @{ File = ".gitconfig"; Description = "Git configuration" },
        @{ File = "gitconfig_helper.py"; Description = "Git helper script" }tconfig_helper.py"; Description = "Git helper script" }
)

# Step 1: Create Symlinks Step 1: Create Symlinks
Write-Host "[STEP 1] Creating symlinks..." -ForegroundColor CyanWrite-Host "[STEP 1] Creating symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan--" -ForegroundColor Cyan

        $linkErrors = 0
        foreach ($item in $filesToLink) {
            $sourceFile = Join-Path $repoRoot $item.File    $sourceFile = Join-Path $repoRoot $item.File
            $linkPath = Join-Path $homeDir $item.Filem.File

            if (-not (Test-Path $sourceFile)) {
                th $sourceFile)) {
            Write-Host "[ERROR] Source not found: $sourceFile" -ForegroundColor Redst "[ERROR] Source not found: $sourceFile" -ForegroundColor Red
            $linkErrors++   $linkErrors++
            continue        continue
        }

        if (Test-Path $linkPath) {
            if (-not $Force) {
                $response = Read-Host "$($item.File) exists. Overwrite? (y/n)"
                if ($response -ne "y") {
                    e -ne "y") {
                    Write-Host "Skipped: $($item.File)" -ForegroundColor Yellow   Write-Host "Skipped: $($item.File)" -ForegroundColor Yellow
                    continue       continue
                }
            }   
        }
        Remove-Item $linkPath -Force | Out-Null        Remove-Item $linkPath -Force | Out-Null
    }

    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceFile -Force | Out-Null   New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceFile -Force | Out-Null
        Write-Host "[OK] Linked $($item.File)" -ForegroundColor Greente-Host "[OK] Linked $($item.File)" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] Could not create symlink for $($item.File)" -ForegroundColor RedoundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Redrite-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $linkErrors++rrors++
    }
}

if ($linkErrors -gt 0) {
    linkErrors -gt 0) {
    Write-Host ""   Write-Host ""
    Write-Host "[WARNING] Some symlinks failed. Check permissions above." -ForegroundColor Yellow    Write-Host "[WARNING] Some symlinks failed. Check permissions above." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host ""

# Step 2: Generate Local Config# Step 2: Generate Local Config
Write-Host "[STEP 2] Generating machine-specific configuration..." -ForegroundColor CyanSTEP 2] Generating machine-specific configuration..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor CyanWrite-Host "-----" -ForegroundColor Cyan

$localConfigPath = "$homeDir\.gitconfig.local"

if ((Test-Path $localConfigPath) -and -not $Force) {if ((Test-Path $localConfigPath) -and -not $Force) {
    $response = Read-Host ".gitconfig.local exists. Overwrite? (y/n)"ists. Overwrite? (y/n)"
if ($response -ne "y") {
    if ($response -ne "y") {
        Write-Host "Skipped: .gitconfig.local" -ForegroundColor YellowgroundColor Yellow
    }
}
else {
    try {
        ry {
            $configContent = @"       $configContent = @"
            # Machine-Specific Git Configurationine-Specific Git Configuration
            # This file is automatically included by .gitconfig and should NOT be committedle is automatically included by .gitconfig and should NOT be committed

            [gpg "ssh"]
            # Machine-specific SSH signing program path
            program = $($homeDir -replace '\\', '/')/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe	program = $($homeDir -replace '\\', '/')/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe

            [safe]
            # Network locations (make sure these paths exist on this machine)
            directory = %(prefix)///10.210.3.10/dept/IT/PC Setup/winget-app-setup	directory = %(prefix)///10.210.3.10/dept/IT/PC Setup/winget-app-setup
            directory = %(prefix)///10.210.3.10/dept/IT/Programs/Office/OfficeConfigstory = %(prefix)///10.210.3.10/dept/IT/Programs/Office/OfficeConfigs
            directory = %(prefix)///KFWS9BDC01/DEPT/IT/Programs/Office/OfficeConfigsConfigs

            # Local development directories
            directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-app-setupsetup
            directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-install	directory = $($homeDir -replace '\\', '/')/Documents/Scripts/winget-install
            "@
        Set-Content -Path $localConfigPath -Value $configContent -Force
        Write-Host "[OK] Created .gitconfig.local" -ForegroundColor Green
    }  }
    catch {
        Write-Host "[FAIL] Could not create .gitconfig.local" -ForegroundColor RedColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red   Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "[INFO] SSH program: op-ssh-sign.exe (from 1Password)" -ForegroundColor Gray-Host "[INFO] SSH program: op-ssh-sign.exe (from 1Password)" -ForegroundColor Gray
Write-Host "[INFO] Safe directories: Network shares and local repos" -ForegroundColor Grayrite-Host "[INFO] Safe directories: Network shares and local repos" -ForegroundColor Gray
Write-Host ""Write-Host ""

# Step 3: Create Scheduled Task (optional)
if (-not $NoTask) {ask) {
    Write-Host "[STEP 3] Setting up scheduled task..." -ForegroundColor Cyan    Write-Host "[STEP 3] Setting up scheduled task..." -ForegroundColor Cyan
    Write-Host "-----" -ForegroundColor Cyanan

    $taskName = "GitConfig Pull at Login"
    $scriptPath = Join-Path $scriptsDir "Update-GitConfig.ps1"ate-GitConfig.ps1"
    
            if (-not (Test-Path $scriptPath)) {
                Write-Host "[WARN] Update-GitConfig.ps1 not found" -ForegroundColor YellowregroundColor Yellow
            } }
        else {
            $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinueyContinue
   
            if ($existingTask -and -not $Force) {
                ($existingTask -and -not $Force) {
                    $response = Read-Host "Scheduled task exists. Replace? (y/n)"eduled task exists. Replace? (y/n)"
            if ($response -ne "y") {
                Write-Host "Skipped: Scheduled task" -ForegroundColor Yellow                Write-Host "Skipped: Scheduled task" -ForegroundColor Yellow
            }
            else {
                try {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Nullalse | Out-Null
       
                    $action = New-ScheduledTaskAction `  $action = New-ScheduledTaskAction `
                        -Execute "PowerShell.exe" `   -Execute "PowerShell.exe" `
                        -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
                    $trigger = New-ScheduledTaskTrigger -AtLogOn$trigger = New-ScheduledTaskTrigger -AtLogOn
                    $settings = New-ScheduledTaskSettingsSet `gsSet `
                        -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable                        -StartWhenAvailable

                    Register-ScheduledTask `                    Register-ScheduledTask `
                        -TaskName $taskName `
                        -Action $action `
                        -Trigger $trigger `
                        -Settings $settings ` `
                        -Description "Automatically pull latest changes from gitconfig repository at user login" `                        -Description "Automatically pull latest changes from gitconfig repository at user login" `
                        -Force | Out-Null

                    Write-Host "[OK] Created scheduled task" -ForegroundColor Greented scheduled task" -ForegroundColor Green
                    Write-Host "[INFO] Task runs at user login" -ForegroundColor Gray runs at user login" -ForegroundColor Gray
                }
                catch {
                    Write-Host "[FAIL] Could not create scheduled task" -ForegroundColor Reduld not create scheduled task" -ForegroundColor Red
                    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red                    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        else {
            try {
                if ($existingTask) {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null   Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
                }   
            }
       
            $action = New-ScheduledTaskAction `  $action = New-ScheduledTaskAction `
                -Execute "PowerShell.exe" `   -Execute "PowerShell.exe" `
                -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""ofile -WindowStyle Hidden -File `"$scriptPath`""
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $settings = New-ScheduledTaskSettingsSet `settings = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable

                Register-ScheduledTask `                Register-ScheduledTask `
                    -TaskName $taskName `
                    -Action $action `                    -Action $action `
                    -Trigger $trigger `
                    -Settings $settings `
                    -Description "Automatically pull latest changes from gitconfig repository at user login" `ull latest changes from gitconfig repository at user login" `
                -Force | Out-Null
                
            Write-Host "[OK] Created scheduled task" -ForegroundColor Green scheduled task" -ForegroundColor Green
                Write-Host "[INFO] Task runs at user login" -ForegroundColor Grayuns at user login" -ForegroundColor Gray
        }
        catch {
            Write-Host "[FAIL] Could not create scheduled task" -ForegroundColor Rednot create scheduled task" -ForegroundColor Red
                Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }        }
    }
    Write-Host ""
}

# Step 4: Verify Setup
Write-Host "[STEP 4] Verifying setup..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan-" -ForegroundColor Cyan

            $verifyErrors = 0

            # Check symlinks
            foreach ($item in $filesToLink) {
                ch ($item in $filesToLink) {
                    $linkPath = Join-Path $homeDir $item.Fileath = Join-Path $homeDir $item.File
                    if (Test-Path $linkPath) {
                        Write-Host "[OK] Symlink verified: $($item.File)" -ForegroundColor Green] Symlink verified: $($item.File)" -ForegroundColor Green
    }
    else {   else {
        Write-Host "[FAIL] Symlink missing: $($item.File)" -ForegroundColor Red        Write-Host "[FAIL] Symlink missing: $($item.File)" -ForegroundColor Red
        $verifyErrors++s++
    }
}

# Check local configk local config
if (Test-Path $localConfigPath) {
    Write-Host "[OK] Local config verified: .gitconfig.local" -ForegroundColor Green] Local config verified: .gitconfig.local" -ForegroundColor Green
                    }
                    else {
                        else {
                            Write-Host "[FAIL] Local config missing: .gitconfig.local" -ForegroundColor Red[FAIL] Local config missing: .gitconfig.local" -ForegroundColor Red
    $verifyErrors++verifyErrors++
}

# Test git alias
try {
    $gitTest = & git alias 2>&1st = & git alias 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git aliases working" -ForegroundColor Green] Git aliases working" -ForegroundColor Green
                        }
                        else { else {
                                Write-Host "[WARN] Git aliases not responding" -ForegroundColor Yellow Write-Host "[WARN] Git aliases not responding" -ForegroundColor Yellow
                                $verifyErrors++
                            } }
                    } }
                catch {
                    Write-Host "[WARN] Could not verify git aliases" -ForegroundColor Yellowrite-Host "[WARN] Could not verify git aliases" -ForegroundColor Yellow
                }

                # Verify SSH config
                try {
                    $sshPath = git config gpg.ssh.programig gpg.ssh.program
                    if ($sshPath -and (Test-Path $sshPath)) {
                        Write-Host "[OK] SSH signing configured" -ForegroundColor Green   Write-Host "[OK] SSH signing configured" -ForegroundColor Green
                    }
                    elseif ($sshPath) {
                        Write-Host "[WARN] SSH signing path not accessible: $sshPath" -ForegroundColor Yellow   Write-Host "[WARN] SSH signing path not accessible: $sshPath" -ForegroundColor Yellow
                    }   
                }
                else { e {
                        Write-Host "[WARN] SSH signing not configured" -ForegroundColor Yellowow
                    } }
            }
        }
        catch {
            Write-Host "[WARN] Could not verify SSH signing" -ForegroundColor Yellow    Write-Host "[WARN] Could not verify SSH signing" -ForegroundColor Yellow
        }

        Write-Host ""

        # Summary
        Write-Host "Setup Complete!" -ForegroundColor Cyan
        Write-Host "=====================================" -ForegroundColor Cyanrite-Host "=====================================" -ForegroundColor Cyan

        if ($verifyErrors -eq 0) {
            Write-Host "All checks passed. Git configuration is ready!" -ForegroundColor Green   Write-Host "All checks passed. Git configuration is ready!" -ForegroundColor Green
        }
    }
    else {
        Write-Host "Some checks failed. Review above for details." -ForegroundColor Yellowve for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyanext Steps:" -ForegroundColor Cyan
        Write-Host "  1. Test aliases: git alias" -ForegroundColor GrayWrite-Host "  1. Test aliases: git alias" -ForegroundColor Gray
        Write-Host "  2. Customize paths: git localconfig" -ForegroundColor Grayustomize paths: git localconfig" -ForegroundColor Gray
Write-Host "  3. Verify SSH: git config gpg.ssh.program" -ForegroundColor Gray
Write-Host ""

exit $verifyErrors
Write-Host "  3. Verify SSH: git config gpg.ssh.program" -ForegroundColor Gray
Write-Host ""

exit $verifyErrors
