# Behavioural tests for the Windows install and cleanup flow (#240): install.ps1
# reports failed steps and exits 1, -NoTask is honoured end to end (no task
# prompt, the task survives -Reinstall), Cleanup-GitConfig.ps1 exits 1 when it
# leaves something behind, and an elevation with another account's password
# still configures the account that started the script.
#
# Every script runs in a child pwsh with the elevation check stubbed to "admin",
# a sandboxed USERPROFILE/HOME/git config and $PROFILE, and the ScheduledTasks
# cmdlets stubbed, so nothing touches the real machine and the tests run on any
# platform. install.ps1 runs from a copy whose step scripts are stubs that log
# how they were called and exit with a code the test picks.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:winDir = Join-Path (Join-Path $script:repoRoot "scripts") "windows version"
    $script:pwshPath = (Get-Process -Id $PID).Path

    # Lines run in the child before the script under test: stubs plus sandbox.
    function New-ChildPrelude([string]$HomeDir, [string]$ProfilePath, [string]$PromptLog, [string]$GitConfig) {
        @"
function Test-AsAdministrator { `$true }
Set-Alias -Name Test-IsAdministrator -Value Test-AsAdministrator
function Read-Host { param([string]`$Prompt) Add-Content -LiteralPath '$PromptLog' -Value `$Prompt; 'n' }
`$env:USERPROFILE = '$HomeDir'; `$env:HOME = '$HomeDir'
`$env:USERDOMAIN = 'CORP'; `$env:USERNAME = 'alice'
`$env:GIT_CONFIG_GLOBAL = '$GitConfig'; `$env:GIT_CONFIG_SYSTEM = '$GitConfig.none'
`$global:PROFILE = [pscustomobject]@{ CurrentUserAllHosts = '$ProfilePath' }
"@
    }

    # Run Command in a child PowerShell of the same edition. -EncodedCommand,
    # because Windows PowerShell 5.1 strips the double quotes inside a native
    # command's argument, which would mangle the command text.
    # Its stderr must not stop the test under a caller's ErrorActionPreference
    # of Stop (5.1 turns redirected native stderr into error records).
    function Invoke-Child([string]$Command) {
        $ErrorActionPreference = 'Continue'
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
        & $script:pwshPath -NoProfile -NonInteractive -EncodedCommand $encoded
    }

    function New-Sandbox {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sandboxHome = Join-Path $root "home"
        New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null
        $result = [pscustomobject]@{
            Root      = $root
            Home      = $sandboxHome
            Profile   = Join-Path (Join-Path $root "own-profile") "profile.ps1"
            PromptLog = Join-Path $root "prompts.txt"
            # 'git alias' must work for install.ps1's STEP 7.
            GitConfig = Join-Path $root "global.gitconfig"
        }
        Set-Content -LiteralPath $result.GitConfig -Value "[alias]`n`talias = !true"
        $result
    }

    # --- install.ps1 harness -------------------------------------------------

    # A step-script stub: logs "<name>|<bound parameters>|USERPROFILE=<value>"
    # and exits with $env:STUB_EXIT_<name without punctuation> (default 0).
    $script:stepStub = @'
param([switch]$Force, [switch]$KeepLocal, [switch]$KeepTask, [string]$TaskUser,
    [string]$InvokingUser, [string]$InvokingUserProfile, [string]$InvokingDocuments)
$name = Split-Path -Leaf $PSCommandPath
$bound = ($PSBoundParameters.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
Add-Content -LiteralPath $env:STUB_LOG -Value "$name|$bound|USERPROFILE=$env:USERPROFILE"
$code = [Environment]::GetEnvironmentVariable('STUB_EXIT_' + ($name -replace '[^A-Za-z]', ''))
if ($code) { exit ([int]$code) }
'@

    # Copy install.ps1 next to stub step scripts. The stub Functions.ps1 loads
    # the real one, then makes Python "missing" and the pip step a no-op.
    function New-InstallCopy([string]$Root) {
        $dir = Join-Path (Join-Path (Join-Path $Root "repo") "scripts") "windows version"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:winDir "install.ps1") -Destination $dir
        foreach ($s in 'Cleanup-GitConfig.ps1', 'Initialize-GitConfig.ps1', 'Initialize-Symlinks.ps1',
            'Initialize-LocalConfig.ps1', 'Register-LoginTask.ps1') {
            Set-Content -LiteralPath (Join-Path $dir $s) -Value $script:stepStub
        }
        $realFunctions = Join-Path $script:winDir "Functions.ps1"
        Set-Content -LiteralPath (Join-Path $dir "Functions.ps1") -Value @"
. '$realFunctions'
function Resolve-Python { `$null }
function Install-PythonDeps { param(`$RepoRoot) }
"@
        Join-Path $dir "install.ps1"
    }

    # Run the install copy. -Exit sets step exit codes, e.g. @{ InitializeSymlinksps = 1 }.
    # -Missing names files STEP 7 should not find in the home folder
    # (-FilesHome, default the sandbox home).
    function Invoke-Install {
        param([string[]]$ScriptArgs = @(), [hashtable]$Exit = @{}, [string[]]$Missing = @(), $Sandbox, [string]$FilesHome)
        $sb = if ($Sandbox) { $Sandbox } else { New-Sandbox }
        $install = New-InstallCopy -Root $sb.Root
        $filesDir = if ($FilesHome) { $FilesHome } else { $sb.Home }
        foreach ($f in ".gitconfig", ".gitignore_global", "gitconfig_helper.py", ".gitconfig.local") {
            if ($Missing -notcontains $f) { Set-Content -LiteralPath (Join-Path $filesDir $f) -Value "" }
        }
        $log = Join-Path $sb.Root "steps.log"
        $exitLines = ($Exit.GetEnumerator() | ForEach-Object { "`$env:STUB_EXIT_$($_.Key) = '$($_.Value)'" }) -join "`n"
        $cmd = @"
$(New-ChildPrelude -HomeDir $sb.Home -ProfilePath $sb.Profile -PromptLog $sb.PromptLog -GitConfig $sb.GitConfig)
`$env:STUB_LOG = '$log'
$exitLines
& '$install' $($ScriptArgs -join ' ')
exit `$LASTEXITCODE
"@
        $out = Invoke-Child $cmd *>&1 | Out-String
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Output   = $out
            Steps    = if (Test-Path $log) { @(Get-Content -LiteralPath $log) } else { @() }
            Prompts  = if (Test-Path $sb.PromptLog) { @(Get-Content -LiteralPath $sb.PromptLog) } else { @() }
            Sandbox  = $sb
        }
    }

    function Get-StepCall($Result, [string]$Name) {
        $Result.Steps | Where-Object { $_ -like "$Name|*" }
    }

    # --- Cleanup-GitConfig.ps1 harness ---------------------------------------

    # Run the real cleanup. The task "exists" while the marker file does;
    # Unregister-ScheduledTask deletes the marker unless -TaskStuck.
    function Invoke-Cleanup {
        param([string[]]$ScriptArgs = @('-Force'), [switch]$TaskExists, [switch]$TaskStuck, $Sandbox)
        $sb = if ($Sandbox) { $Sandbox } else { New-Sandbox }
        $marker = Join-Path $sb.Root "task-exists"
        $calls = Join-Path $sb.Root "task-calls.txt"
        if ($TaskExists) { Set-Content -LiteralPath $marker -Value "" }
        $stuck = if ($TaskStuck) { '$true' } else { '$false' }
        $script = Join-Path $script:winDir "Cleanup-GitConfig.ps1"
        $cmd = @"
$(New-ChildPrelude -HomeDir $sb.Home -ProfilePath $sb.Profile -PromptLog $sb.PromptLog -GitConfig $sb.GitConfig)
function Get-ScheduledTask { param([string]`$TaskName, `$ErrorAction) Add-Content -LiteralPath '$calls' -Value "Get `$TaskName"; if (Test-Path '$marker') { [pscustomobject]@{ TaskName = `$TaskName } } }
function Unregister-ScheduledTask { param([string]`$TaskName, [switch]`$Confirm) Add-Content -LiteralPath '$calls' -Value "Unregister `$TaskName"; if (-not $stuck) { Remove-Item -LiteralPath '$marker' } }
& '$script' $($ScriptArgs -join ' ')
exit `$LASTEXITCODE
"@
        $out = Invoke-Child $cmd *>&1 | Out-String
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode   = $code
            Output     = $out
            TaskCalls  = if (Test-Path $calls) { @(Get-Content -LiteralPath $calls) } else { @() }
            TaskExists = Test-Path $marker
            Sandbox    = $sb
        }
    }

    $script:beginMarker = "# >>> gitconfig git-alias browser (Ctrl-G) >>>"
    $script:endMarker = "# <<< gitconfig git-alias browser <<<"
    $script:edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
}

Describe "install.ps1 reports failed steps (#240)" -Tag 'Unit' {

    It "exits 0 and says Setup Complete when every step succeeds" {
        $r = Invoke-Install -ScriptArgs @('-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Setup Complete!'
        $r.Output | Should -Not -Match '\[FAIL\]'
        foreach ($s in 'Initialize-GitConfig.ps1', 'Initialize-Symlinks.ps1', 'Initialize-LocalConfig.ps1', 'Register-LoginTask.ps1') {
            Get-StepCall $r $s | Should -Not -BeNullOrEmpty
        }
    }

    It "exits 1 and names the step when <Step> exits 1, and still runs the later steps" -ForEach @(
        @{ Step = 'Initialize-GitConfig.ps1'; Key = 'InitializeGitConfigps'; Label = 'STEP 1' }
        @{ Step = 'Initialize-Symlinks.ps1'; Key = 'InitializeSymlinksps'; Label = 'STEP 2' }
        @{ Step = 'Initialize-LocalConfig.ps1'; Key = 'InitializeLocalConfigps'; Label = 'STEP 3' }
        @{ Step = 'Register-LoginTask.ps1'; Key = 'RegisterLoginTaskps'; Label = 'STEP 5' }
    ) {
        $r = Invoke-Install -ScriptArgs @('-Force') -Exit @{ $Key = 1 }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Not -Match 'Setup Complete!'
        $r.Output | Should -Match 'Setup finished with errors'
        $r.Output | Should -Match ("\[FAIL\] " + $Label)
        Get-StepCall $r 'Register-LoginTask.ps1' | Should -Not -BeNullOrEmpty
    }

    It "does not report Generated .gitconfig when Initialize-GitConfig.ps1 fails" {
        $r = Invoke-Install -ScriptArgs @('-Force') -Exit @{ InitializeGitConfigps = 1 }
        $r.Output | Should -Not -Match '\[OK\] Generated \.gitconfig'
        $r.Output | Should -Match '\[FAIL\] Could not generate \.gitconfig \(exit code 1\)'
    }

    It "exits 1 when a file is missing at verification" {
        $r = Invoke-Install -ScriptArgs @('-Force') -Missing @('gitconfig_helper.py')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[FAIL\] STEP 7: gitconfig_helper\.py missing'
    }

    It "treats an incomplete -Reinstall cleanup as a warning, not a failure" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-Reinstall') -Exit @{ CleanupGitConfigps = 1 }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[WARN\] Cleanup did not remove everything'
    }

    It "pauses before exiting when it is the elevated relaunch (-Elevated)" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-Elevated') -Exit @{ InitializeSymlinksps = 1 }
        $r.ExitCode | Should -Be 1
        $r.Prompts | Should -Contain 'Press Enter to close this window'
    }

    It "does not pause when run directly" {
        $r = Invoke-Install -ScriptArgs @('-Force')
        $r.Prompts | Should -Not -Contain 'Press Enter to close this window'
    }
}

Describe "install.ps1 -NoTask (#240)" -Tag 'Unit' {

    It "-NoTask does not register the task" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-NoTask')
        $r.ExitCode | Should -Be 0
        Get-StepCall $r 'Register-LoginTask.ps1' | Should -BeNullOrEmpty
    }

    It "-Reinstall -NoTask passes -KeepTask to the cleanup, so the task survives" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-Reinstall', '-NoTask')
        Get-StepCall $r 'Cleanup-GitConfig.ps1' | Should -Match '(^|[|;])KeepTask=True([;|]|$)'
        Get-StepCall $r 'Cleanup-GitConfig.ps1' | Should -Match 'KeepLocal=True'
    }

    It "-Reinstall without -NoTask lets the cleanup remove the task (STEP 5 registers it again)" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-Reinstall')
        Get-StepCall $r 'Cleanup-GitConfig.ps1' | Should -Not -Match 'KeepTask=True'
        Get-StepCall $r 'Register-LoginTask.ps1' | Should -Not -BeNullOrEmpty
    }

    It "never asks about the scheduled task with -Force -NoTask" {
        $r = Invoke-Install -ScriptArgs @('-Force', '-NoTask')
        $r.Prompts | Where-Object { $_ -match 'task' } | Should -BeNullOrEmpty
    }
}

Describe "install.ps1 elevated as another account (#240)" -Tag 'Unit' {
    # The child runs as CORP\alice (USERDOMAIN/USERNAME). Passing
    # -InvokingUser CORP\bob is what the relaunch does when bob typed alice's
    # administrator password.

    BeforeEach {
        $script:sb = New-Sandbox
        $script:bobHome = Join-Path $script:sb.Root "bob"
        $script:bobDocs = Join-Path $script:bobHome "OneDrive Documents"
        New-Item -ItemType Directory -Path $script:bobHome | Out-Null
    }

    It "configures the invoking account: its profile folder, its task, its PowerShell profile" {
        $r = Invoke-Install -Sandbox $script:sb -FilesHome $script:bobHome -ScriptArgs @(
            '-Force', '-Reinstall', '-InvokingUser', '"CORP\bob"',
            '-InvokingUserProfile', "`"$script:bobHome`"", '-InvokingDocuments', "`"$script:bobDocs`""
        )
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[WARN\] Elevated as CORP\\alice, but started by CORP\\bob'

        # Every step sees bob's profile folder.
        foreach ($line in $r.Steps) { $line | Should -Match ([regex]::Escape("USERPROFILE=$script:bobHome") + '$') }
        Get-StepCall $r 'Register-LoginTask.ps1' | Should -Match 'TaskUser=CORP\\bob'
        Get-StepCall $r 'Cleanup-GitConfig.ps1' | Should -Match 'InvokingUser=CORP\\bob'

        # The Ctrl-G block goes into bob's profile, not the elevated account's.
        $bobProfile = Join-Path (Join-Path $script:bobDocs $script:edition) "profile.ps1"
        $bobProfile | Should -Exist
        (Get-Content -LiteralPath $bobProfile -Raw) | Should -Match ([regex]::Escape($script:beginMarker))
        $script:sb.Profile | Should -Not -Exist
    }

    It "registers the task for the current account when it was not elevated as another one" {
        $r = Invoke-Install -Sandbox $script:sb -ScriptArgs @('-Force', '-InvokingUser', '"CORP\alice"')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'Elevated as'
        Get-StepCall $r 'Register-LoginTask.ps1' | Should -Match 'TaskUser=CORP\\alice'
        $script:sb.Profile | Should -Exist
    }
}

Describe "Cleanup-GitConfig.ps1 -KeepTask and exit status (#240)" -Tag 'Unit' {

    It "-KeepTask leaves the scheduled task alone and exits 0" {
        $r = Invoke-Cleanup -ScriptArgs @('-Force', '-KeepTask') -TaskExists
        $r.ExitCode | Should -Be 0
        $r.TaskExists | Should -BeTrue
        $r.TaskCalls | Where-Object { $_ -like 'Unregister*' } | Should -BeNullOrEmpty
        $r.Output | Should -Match 'Scheduled task kept \(-KeepTask\)'
    }

    It "removes the task without -KeepTask and exits 0" {
        $r = Invoke-Cleanup -ScriptArgs @('-Force') -TaskExists
        $r.ExitCode | Should -Be 0
        $r.TaskExists | Should -BeFalse
        $r.TaskCalls | Should -Contain 'Unregister GitConfig Pull at Login'
    }

    It "exits 1 when the task is still there afterwards" {
        $r = Invoke-Cleanup -ScriptArgs @('-Force') -TaskExists -TaskStuck
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Cleanup INCOMPLETE'
    }

    It "removes the Ctrl-G block from the invoking account's profile after an account switch" {
        $sb = New-Sandbox
        $bobHome = Join-Path $sb.Root "bob"
        $bobDocs = Join-Path $bobHome "Documents"
        $bobProfile = Join-Path (Join-Path $bobDocs $script:edition) "profile.ps1"
        New-Item -ItemType Directory -Path (Split-Path -Parent $bobProfile) -Force | Out-Null
        Set-Content -LiteralPath $bobProfile -Value "# mine`n$script:beginMarker`n. 'widget'`n$script:endMarker"
        $r = Invoke-Cleanup -Sandbox $sb -ScriptArgs @(
            '-Force', '-InvokingUser', '"CORP\bob"', '-InvokingUserProfile', "`"$bobHome`"", '-InvokingDocuments', "`"$bobDocs`""
        )
        $r.Output | Should -Match 'Elevated as CORP\\alice, but started by CORP\\bob'
        $content = Get-Content -LiteralPath $bobProfile -Raw
        $content | Should -Not -Match ([regex]::Escape($script:beginMarker))
        $content | Should -Match '# mine'
    }
}

Describe "Initialize-Symlinks.ps1 does not deal with the scheduled task (#240)" -Tag 'Unit' {

    It "never prompts about a scheduled task" {
        $sb = New-Sandbox
        $script = Join-Path $script:winDir "Initialize-Symlinks.ps1"
        $cmd = @"
$(New-ChildPrelude -HomeDir $sb.Home -ProfilePath $sb.Profile -PromptLog $sb.PromptLog -GitConfig $sb.GitConfig)
function Register-ScheduledTask { throw 'Initialize-Symlinks.ps1 registered a task' }
& '$script' -Force
"@
        $out = Invoke-Child $cmd *>&1 | Out-String
        $prompts = if (Test-Path $sb.PromptLog) { @(Get-Content -LiteralPath $sb.PromptLog) } else { @() }
        $prompts | Where-Object { $_ -match 'task' } | Should -BeNullOrEmpty
        $out | Should -Not -Match 'scheduled task'
    }

    It "has no copy of the task registration" {
        $content = Get-Content -LiteralPath (Join-Path $script:winDir "Initialize-Symlinks.ps1") -Raw
        $content | Should -Not -Match 'function Register-LoginTask'
        $content | Should -Not -Match '(Register|New)-ScheduledTask'
    }
}
