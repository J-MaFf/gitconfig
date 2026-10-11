# GitConfig Setup Wrapper
# Orchestrates complete setup of portable git configuration
# Requires administrator privileges

param(
    [switch]$Force = $false,
    [switch]$NoTask = $false,
    [switch]$Reinstall = $false,
    [switch]$Help = $false,
    # Set by the elevated relaunch, not by hand (#240): the account that started
    # the install and its profile and Documents folders, so elevating with an
    # administrator's password still sets up the account that ran the script.
    [string]$InvokingUser = "",
    [string]$InvokingUserProfile = "",
    [string]$InvokingDocuments = "",
    # Also set by the relaunch: pause before the elevated window closes.
    [switch]$Elevated = $false
)

if ($Help) {
    Write-Host @"
GitConfig Setup Wrapper

USAGE: .\install.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing files without prompting
    -NoTask     Skip Windows scheduled task creation (and, with -Reinstall,
                keep the task that is already registered)
    -Reinstall  Tear down the existing install first (Cleanup-GitConfig.ps1
                -Force -KeepLocal), which also removes the scheduled task
                unless -NoTask is given.
                Without it, existing files are kept and only replaced after a
                timestamped backup (<file>.bak.yyyyMMdd-HHmmss).
    -Help       Display this help message

DESCRIPTION:
    0. With -Reinstall only: removes the previous install
    1. Generates machine-specific .gitconfig from template
    2. Creates symlinks (.gitignore_global, gitconfig_helper.py)
    3. Generates machine-specific .gitconfig.local (kept if it exists)
    5. Creates Windows scheduled task for auto-sync (optional)
    6. Installs Python dependencies and the Ctrl-G alias browser
    7. Verifies the complete setup

    Put your own git settings in ~/.gitconfig.local: ~/.gitconfig is regenerated
    from the template, and settings added to it (git config --global ...) are
    dropped at the next login sync (they stay in the timestamped backup).

    Backups: the newest 5 per file are kept; set GITCONFIG_BACKUP_KEEP to change
    that (0 keeps them all). The first backup of a file also keeps your original
    as <file>.pre-gitconfig, which is never pruned.

    Exit status: 0 when every step succeeded, 1 when a step failed (they are
    listed at the end). Run without elevation, the script relaunches itself as
    administrator and exits with the elevated run's status.

REQUIREMENTS: Administrator privileges
"@
    exit 0
}

# Preflight: git is required throughout (this whole tool configures git). A clear
# "install git" beats a cryptic mid-run failure. Python is checked later by
# Install-PythonDeps, which degrades gracefully if it's missing.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error 'git not found on PATH. Install Git for Windows (winget install Git.Git), then re-run.'
    exit 1
}

# Check if running as administrator - elevate if needed. The check is a
# function so the relaunch tests can stub it (tests/Backups.Tests.ps1).
function Test-IsAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Shared helpers (Resolve-Python, backups, and the invoking-user handoff the
# relaunch below needs).
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'Functions.ps1')

$isAdmin = Test-IsAdministrator
if (-not $isAdmin) {
    Write-Host "GitConfig Setup - Elevation Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This script requires administrator privileges to create symlinks and scheduled task." -ForegroundColor Yellow
    Write-Host ""

    # No -NoExit: the elevated window would then outlive the script and its
    # exit code would be lost. -Elevated makes it pause at the end instead.
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-Elevated")
    if ($Force)  { $scriptArgs += "-Force" }
    if ($NoTask) { $scriptArgs += "-NoTask" }
    if ($Reinstall) { $scriptArgs += "-Reinstall" }
    # Who is running this, so an elevation with another account's password
    # still configures this account (#240).
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
    # Pass the elevated run's result on, so a caller sees a failed install (#240).
    if ($null -eq $elevatedRun -or $null -eq $elevatedRun.ExitCode) {
        Write-Host "Error: Could not read the elevated setup's exit code." -ForegroundColor Red
        exit 1
    }
    exit $elevatedRun.ExitCode
}

# Every exit from here on: the elevated relaunch runs in its own window, which
# closes as soon as the script ends, so pause first to keep the output readable.
function Exit-Install([int]$Code) {
    if ($Elevated) {
        Write-Host ""
        Read-Host "Press Enter to close this window" | Out-Null
    }
    exit $Code
}

# Elevated with a different account's password: set up the account that started
# the install, not the administrator's (#240). $installUser.Documents is that
# account's Documents folder (for the PowerShell profiles), or $null when none
# was passed (use this account's).
$installUser = Use-InvokingUser -InvokingUser $InvokingUser -InvokingUserProfile $InvokingUserProfile -InvokingDocuments $InvokingDocuments

$repoRoot    = Split-Path -Parent (Split-Path -Parent $scriptDir)
$homeDir     = $env:USERPROFILE
$scriptsDir  = $scriptDir
$cleanupScript     = Join-Path $scriptsDir "Cleanup-GitConfig.ps1"
$initGitScript     = Join-Path $scriptsDir "Initialize-GitConfig.ps1"
$initLocalScript   = Join-Path $scriptsDir "Initialize-LocalConfig.ps1"
$initSymlinksScript = Join-Path $scriptsDir "Initialize-Symlinks.ps1"
$registerTaskScript = Join-Path $scriptsDir "Register-LoginTask.ps1"

# Preflight: Python powers the 'git alias' browser (its rich/textual
# dependencies); the core gitconfig install works fine without it. Detect
# it once, up front, before touching any files, so a missing interpreter is
# a single clear choice instead of scattered warnings later in the run.
# Resolve-Python comes from Functions.ps1, dot-sourced above.
if (-not (Resolve-Python)) {
    Write-Host "[WARN] Python not found - it powers the 'git alias' browser (rich/textual); the core gitconfig install works fine without it." -ForegroundColor Yellow
    if ($Force) {
        Write-Host "[OK] Continuing without Python (-Force)" -ForegroundColor Green
    }
    else {
        $pythonResponse = Read-Host "Continue anyway? (y/n)"
        if ($pythonResponse -ne "y") {
            Write-Host "Setup cancelled." -ForegroundColor Yellow
            Exit-Install 0
        }
    }
    Write-Host ""
}

Write-Host "GitConfig Setup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host ""

# Each step that fails is recorded here; the summary lists them and the script
# exits 1 (#240). It used to print "Setup Complete!" and exit 0 whatever happened.
$failures = New-Object System.Collections.Generic.List[string]

# Run a step's script and return its exit code. The scripts report failure with
# "exit 1", which & does not turn into an error, so the code is the only signal.
# $LASTEXITCODE is reset first: a script that ends without "exit" leaves it as
# the last native command set it. -Quiet drops the script's pipeline output
# (its Write-Host lines still show).
function Invoke-Step {
    param([string]$Path, [hashtable]$Arguments = @{}, [switch]$Quiet)
    $global:LASTEXITCODE = 0
    if ($Quiet) { & $Path @Arguments | Out-Null } else { & $Path @Arguments | Out-Host }
    return $global:LASTEXITCODE
}

# After an account switch the child scripts are told about it too, so they use
# the invoking account's PowerShell profile.
$invokingArgs = @{}
if ($installUser.Switched) {
    $invokingArgs = @{ InvokingUser = $installUser.User; InvokingUserProfile = $homeDir; InvokingDocuments = $installUser.Documents }
}

# STEP 0: Clean up the existing installation, only when asked (-Reinstall). An
# unconditional teardown used to run here; it moved every file away before the
# later steps could ask "Overwrite?", and running install twice replaced the
# backup of the user's original files. The steps below back up what they replace.
if ($Reinstall) {
    Write-Host "[STEP 0] Cleaning up previous installation..." -ForegroundColor Cyan
    Write-Host "-----" -ForegroundColor Cyan
    try {
        # -KeepLocal: the teardown must not delete ~/.gitconfig.local, which holds
        # user-owned machine state (safe.directory entries, etc.). A full reset is
        # available via the standalone Cleanup-GitConfig.ps1 (without -KeepLocal).
        # -KeepTask with -NoTask: STEP 5 won't register the task again, so
        # removing it here would turn the login sync off (#240).
        $cleanupArgs = @{ Force = $true; KeepLocal = $true; KeepTask = [bool]$NoTask } + $invokingArgs
        $code = Invoke-Step -Path $cleanupScript -Arguments $cleanupArgs -Quiet
        if ($code -eq 0) {
            Write-Host "[OK] Previous installation cleaned up" -ForegroundColor Green
        }
        else {
            # Not a failure of the install: the steps below back up and replace
            # whatever the cleanup left.
            Write-Host "[WARN] Cleanup did not remove everything (exit code $code); the steps below replace what is left" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[WARN] No previous installation found or cleanup failed (this is OK)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# STEP 1: Generate .gitconfig from template
Write-Host "[STEP 1] Generating .gitconfig from template..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    $code = Invoke-Step -Path $initGitScript -Arguments @{ Force = [bool]$Force } -Quiet
    if ($code -eq 0) {
        Write-Host "[OK] Generated .gitconfig" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] Could not generate .gitconfig (exit code $code)" -ForegroundColor Red
        $failures.Add("STEP 1: generate .gitconfig")
    }
}
catch {
    Write-Host "[FAIL] Could not generate .gitconfig: $($_.Exception.Message)" -ForegroundColor Red
    $failures.Add("STEP 1: generate .gitconfig")
}
Write-Host ""

# STEP 2: Create symlinks (delegates to Initialize-Symlinks.ps1)
Write-Host "[STEP 2] Creating symlinks..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    $code = Invoke-Step -Path $initSymlinksScript -Arguments @{ Force = [bool]$Force }
    if ($code -ne 0) {
        Write-Host "[FAIL] Symlink setup failed (exit code $code)" -ForegroundColor Red
        $failures.Add("STEP 2: create symlinks")
    }
}
catch {
    Write-Host "[FAIL] Symlink setup failed: $($_.Exception.Message)" -ForegroundColor Red
    $failures.Add("STEP 2: create symlinks")
}
Write-Host ""

# STEP 3: Generate machine-specific config (create-if-missing). .gitconfig.local
# is user-owned state, so an existing one is preserved (never overwritten on
# re-install, even with -Force); regenerate deliberately with
# Initialize-LocalConfig.ps1 -Force.
Write-Host "[STEP 3] Generating machine-specific configuration..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    $localExisted = Test-Path (Join-Path $homeDir ".gitconfig.local")
    $code = Invoke-Step -Path $initLocalScript -Quiet
    if ($code -ne 0) {
        Write-Host "[FAIL] Could not set up .gitconfig.local (exit code $code)" -ForegroundColor Red
        $failures.Add("STEP 3: set up .gitconfig.local")
    }
    elseif ($localExisted) {
        Write-Host "[OK] Preserved existing .gitconfig.local" -ForegroundColor Green
    }
    else {
        Write-Host "[OK] Generated .gitconfig.local" -ForegroundColor Green
    }
}
catch {
    Write-Host "[FAIL] Could not set up .gitconfig.local: $($_.Exception.Message)" -ForegroundColor Red
    $failures.Add("STEP 3: set up .gitconfig.local")
}
Write-Host ""

# (No STEP 4: core.excludesfile is set by ~/.gitconfig.local. Writing it again
# with git config --global made ~/.gitconfig differ from the template, so the
# next login sync regenerated it.)

# STEP 5: Create scheduled task (delegates to Register-LoginTask.ps1, the only
# place the task is registered). -TaskUser: the account being set up, which is
# not this process's account after an over-the-shoulder elevation (#240).
if (-not $NoTask) {
    Write-Host "[STEP 5] Setting up scheduled task..." -ForegroundColor Cyan
    Write-Host "-----" -ForegroundColor Cyan
    try {
        $code = Invoke-Step -Path $registerTaskScript -Arguments @{ TaskUser = $installUser.User; Force = [bool]$Force }
        if ($code -ne 0) {
            Write-Host "[FAIL] Scheduled task setup failed (exit code $code)" -ForegroundColor Red
            $failures.Add("STEP 5: register the login task")
        }
    }
    catch {
        Write-Host "[FAIL] Scheduled task setup failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("STEP 5: register the login task")
    }
    Write-Host ""
}

# STEP 6: Install Python dependencies (rich required; textual optional, for the
# interactive 'git alias' browser). Declared in pyproject.toml and installed by
# the shared Install-PythonDeps routine (single source of truth across Windows
# install + the login auto-update). Best effort: it warns, and the login sync
# retries, so it never fails the install.
Write-Host "[STEP 6] Installing Python dependencies..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
Install-PythonDeps -RepoRoot $repoRoot
Write-Host ""

# STEP 6b: Enable the interactive git-alias browser keybinding (Ctrl-G)
Write-Host "[STEP 6b] Enabling git-alias browser keybinding..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan
try {
    $widgetPath = Join-Path $repoRoot "scripts\shell\git-alias-widget.ps1"
    $beginMarker = "# >>> gitconfig git-alias browser (Ctrl-G) >>>"
    $endMarker = "# <<< gitconfig git-alias browser <<<"
    # Single quotes so a '$' or '`' in the repo path is not expanded.
    $loadLine = ". '{0}'" -f $widgetPath.Replace("'", "''")
    # Both editions' profiles (#230): the elevated relaunch runs Windows
    # PowerShell 5.1, but the user may work in PowerShell 7, or the reverse. Set
    # them under the invoking account's Documents after an account switch, else
    # this account's (OneDrive-aware, not $PROFILE).
    foreach ($profilePath in @(Get-ProfileScriptPath -Documents $installUser.Documents)) {
        # One profile failing (locked, no access) should not skip the other.
        try {
            # Set-MarkedBlock rewrites an existing block in place (a moved repo
            # updates the path) and keeps the profile's encoding and BOM.
            switch (Set-MarkedBlock -Path $profilePath -BeginMarker $beginMarker -EndMarker $endMarker -Body $loadLine) {
                'Added' { Write-Host "[OK] Enabled git-alias keybinding (Ctrl-G) in $profilePath" -ForegroundColor Green }
                'Updated' { Write-Host "[OK] Updated git-alias keybinding in $profilePath" -ForegroundColor Green }
                'Unchanged' { Write-Host "[OK] git-alias keybinding already enabled in $profilePath" -ForegroundColor Green }
                'Unterminated' {
                    Write-Host "[WARN] Found '$beginMarker' in $profilePath but no end marker; left the profile unchanged" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "[WARN] Could not enable git-alias keybinding in ${profilePath}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Host "[WARN] Could not enable git-alias keybinding: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ""

# STEP 7: Verify setup
Write-Host "[STEP 7] Verifying setup..." -ForegroundColor Cyan
Write-Host "-----" -ForegroundColor Cyan

$verifyFiles = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py", ".gitconfig.local")
foreach ($file in $verifyFiles) {
    $path = Join-Path $homeDir $file
    if (Test-Path $path) { Write-Host "[OK] $file verified" -ForegroundColor Green }
    else {
        Write-Host "[FAIL] $file missing" -ForegroundColor Red
        $failures.Add("STEP 7: $file missing")
    }
}

# Resolve-Python (Functions.ps1) treats 0-byte
# WindowsApps app-execution-alias stubs specially (deprioritized or skipped
# depending on what else is available), unlike a plain first-hit Get-Command
# chain, which would happily return one. Reuse it here instead of
# re-resolving with weaker logic, so verification can't fail against a
# candidate STEP 6 already knew to avoid (#200).
$pyCmd = Resolve-Python
$richImportable = $false

if ($pyCmd) {
    try {
        & $pyCmd -c "import rich" 2>$null
        $richImportable = ($LASTEXITCODE -eq 0)
        if ($richImportable) { Write-Host "[OK] Python 'rich' importable" -ForegroundColor Green }
        else                     { Write-Host "[WARN] Python 'rich' not importable" -ForegroundColor Yellow }
        & $pyCmd -c "import textual" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Python 'textual' importable" -ForegroundColor Green }
        else                     { Write-Host "[WARN] Python 'textual' not importable ('git alias' uses the static table)" -ForegroundColor Yellow }
    }
    catch {
        Write-Host "[WARN] Could not verify Python 'rich'" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[WARN] Python not found - cannot verify 'rich'" -ForegroundColor Yellow
}

# 'git alias' runs the Python helper, which needs 'rich'. Without them it can
# only fail, and that is already reported above (Python is optional, and the
# login sync retries the packages), so only a failure with both present counts.
try {
    & git alias *> $null
    $aliasCode = $LASTEXITCODE
    if ($aliasCode -eq 0) { Write-Host "[OK] Git aliases working" -ForegroundColor Green }
    elseif ($richImportable) {
        Write-Host "[FAIL] 'git alias' failed (exit code $aliasCode)" -ForegroundColor Red
        $failures.Add("STEP 7: 'git alias' failed")
    }
    else { Write-Host "[WARN] 'git alias' needs Python with 'rich', which is not available yet" -ForegroundColor Yellow }
}
catch {
    Write-Host "[WARN] Could not verify git aliases" -ForegroundColor Yellow
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Setup Complete!" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Exit-Install 0
}
Write-Host "Setup finished with errors:" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  [FAIL] $failure" -ForegroundColor Red }
Write-Host "=====================================" -ForegroundColor Red
Write-Host "Fix the [FAIL] lines above and run install.ps1 again." -ForegroundColor Red
Write-Host ""
Exit-Install 1
