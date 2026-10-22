# Tests for scripts/windows version/Move-ScriptsRoot.ps1 (#304): moving the
# Scripts root out of Documents and re-pointing everything that used it.
#
# Every run happens in a child PowerShell of the same edition, inside a
# TestDrive sandbox: USERPROFILE/HOME/APPDATA point into it, OneDrive is unset,
# git reads only the sandbox's config, and the system touchpoints are stubbed
# in the child before the tool runs:
#   - the ScheduledTasks cmdlets (functions win over cmdlets), backed by a JSON
#     file in the sandbox, logging every Set/Register call;
#   - Get-Process, so a Google Drive process can be faked;
#   - Read-Host, answering from MSR_ANSWER ('<none>' = no input);
#   - the environment variables, through the tool's GITCONFIG_MOVE_ENV_FILE
#     seam (a JSON file instead of the registry).
# The clone the tool runs from is a copy of this repo inside the sandbox's old
# root, so the generators it re-runs (Initialize-GitConfig.ps1 and friends) act
# on the sandbox too. Preflight tests run this checkout's copy of the tool with
# sandbox -From/-To; its generators are then skipped (the clone isn't under -To).
# Nothing here touches the real home folder, environment or Task Scheduler.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolRel = 'scripts\windows version\Move-ScriptsRoot.ps1'
    $script:realTool = Join-Path $script:repoRoot $script:toolRel
    $script:pwshPath = (Get-Process -Id $PID).Path

    # git in this process (building fixture repos) must not read the
    # developer's config either.
    $script:savedGitGlobal = $env:GIT_CONFIG_GLOBAL
    $script:savedGitNoSystem = $env:GIT_CONFIG_NOSYSTEM
    $script:gitGlobal = Join-Path $TestDrive 'test.gitconfig'
    Set-Content -LiteralPath $script:gitGlobal -Value "[user]`n`tname = Test`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n[init]`n`tdefaultBranch = main"
    $env:GIT_CONFIG_GLOBAL = $script:gitGlobal
    $env:GIT_CONFIG_NOSYSTEM = '1'

    # Creating symbolic links needs an elevated prompt or Developer Mode
    # (CI runs elevated). Junctions never do.
    $probe = Join-Path $TestDrive 'symlink-probe'
    try {
        New-Item -ItemType SymbolicLink -Path $probe -Target $TestDrive -ErrorAction Stop | Out-Null
        [IO.Directory]::Delete($probe, $false)
        $script:canSymlink = $true
    }
    catch { $script:canSymlink = $false }

    # Stubs and sandbox, run in the child before the tool.
    $script:prelude = @'
$ErrorActionPreference = 'Continue'
$env:USERPROFILE = $env:MSR_HOME; $env:HOME = $env:MSR_HOME
$env:APPDATA = Join-Path $env:MSR_HOME 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $env:MSR_HOME 'AppData\Local'
Remove-Item Env:OneDrive, Env:OneDriveCommercial, Env:OneDriveConsumer -ErrorAction SilentlyContinue
$env:USERDOMAIN = 'TESTDOM'; $env:USERNAME = 'tester'
$env:GIT_CONFIG_GLOBAL = Join-Path $env:MSR_HOME '.gitconfig'; $env:GIT_CONFIG_NOSYSTEM = '1'
$env:GITCONFIG_MOVE_ENV_FILE = Join-Path $env:MSR_ROOT 'env.json'
function global:Write-MsrLog([string]$Line) { Add-Content -LiteralPath (Join-Path $env:MSR_ROOT 'calls.log') -Value $Line }
function global:Read-Host { param([string]$Prompt) Write-MsrLog "prompt|$Prompt"; if ($env:MSR_ANSWER -eq '<none>') { return $null }; $env:MSR_ANSWER }
function global:Get-Process {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($env:MSR_DRIVE -and $Name -contains 'GoogleDriveFS') { [pscustomobject]@{ Name = 'GoogleDriveFS'; Id = 4242 } }
}
function global:Read-FakeTasks {
    $f = Join-Path $env:MSR_ROOT 'tasks.json'
    if (-not (Test-Path -LiteralPath $f)) { return }
    $parsed = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    foreach ($t in $parsed) { $t }
}
function global:Save-FakeTasks($Tasks) {
    Set-Content -LiteralPath (Join-Path $env:MSR_ROOT 'tasks.json') -Value (ConvertTo-Json -InputObject @($Tasks) -Depth 8)
}
function global:Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName)
    foreach ($t in @(Read-FakeTasks)) { if (-not $TaskName -or $t.TaskName -eq $TaskName) { $t } }
}
function global:Set-ScheduledTask {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject)
    Write-MsrLog ('set|' + (ConvertTo-Json -InputObject $InputObject -Depth 8 -Compress))
    if ($InputObject.Deny) { throw (New-Object System.UnauthorizedAccessException 'Access is denied.') }
    $key = "$($InputObject.TaskPath)$($InputObject.TaskName)"
    Save-FakeTasks (@(Read-FakeTasks | Where-Object { "$($_.TaskPath)$($_.TaskName)" -ne $key }) + $InputObject)
}
function global:New-ScheduledTaskAction { [CmdletBinding()] param([string]$Execute, [string]$Argument) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $null } }
function global:New-ScheduledTaskTrigger { [CmdletBinding()] param([switch]$AtLogOn, [string]$User) [pscustomobject]@{ AtLogOn = [bool]$AtLogOn; User = $User; Delay = $null } }
function global:New-ScheduledTaskPrincipal { [CmdletBinding()] param([string]$UserId, [string]$LogonType) [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType } }
function global:New-ScheduledTaskSettingsSet {
    [CmdletBinding()] param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, [timespan]$ExecutionTimeLimit)
    [pscustomobject]@{ RunOnlyIfNetworkAvailable = $false }
}
function global:Register-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, $Action, $Trigger, $Settings, $Principal, [string]$Description, [switch]$Force)
    Write-MsrLog "register|$TaskName|$($Action.Arguments)"
    $task = [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\'; Actions = @($Action); Triggers = @($Trigger); Principal = $Principal; Settings = $Settings }
    Save-FakeTasks (@(Read-FakeTasks | Where-Object { $_.TaskName -ne $TaskName }) + $task)
}
function global:Unregister-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [switch]$Confirm)
    Write-MsrLog "unregister|$TaskName"
    Save-FakeTasks @(Read-FakeTasks | Where-Object { $_.TaskName -ne $TaskName })
}
'@

    # The long form of an existing path. On CI the temp folder (and so
    # TestDrive) is an 8.3 short name (C:\Users\RUNNER~1\...), while git
    # records worktree paths in their long form.
    if (-not ('MsrTest.Native' -as [type])) {
        Add-Type -Namespace MsrTest -Name Native -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint size);'
    }
    function Get-LongPath([string]$Path) {
        $buffer = New-Object System.Text.StringBuilder 1024
        if ([MsrTest.Native]::GetLongPathName($Path, $buffer, 1024) -eq 0) { return $Path }
        $buffer.ToString()
    }

    # A sandbox: home folder, old root (From) and new root (To, not created).
    function New-MoveSandbox {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root = Get-LongPath $root
        $sandboxHome = Join-Path $root 'home'
        $from = Join-Path $sandboxHome 'Documents\Scripts'
        New-Item -ItemType Directory -Path $from -Force | Out-Null
        [pscustomobject]@{
            Root  = $root
            Home  = $sandboxHome
            From  = $from
            To    = Join-Path $sandboxHome 'Scripts'
            Clone = Join-Path $from 'gitconfig'
        }
    }

    function Invoke-Git([string[]]$GitArgs) {
        $ErrorActionPreference = 'Continue'
        $out = & git @GitArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
        $out
    }

    # A copy of this repo (what the tool and its generators need) as a git
    # repo at <From>\gitconfig.
    function Install-Clone($Sb) {
        New-Item -ItemType Directory -Path $Sb.Clone -Force | Out-Null
        foreach ($f in '.gitconfig.template', '.gitignore_global', 'gitconfig_helper.py', 'pyproject.toml') {
            Copy-Item -LiteralPath (Join-Path $script:repoRoot $f) -Destination $Sb.Clone
        }
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'scripts') -Destination $Sb.Clone -Recurse
        Invoke-Git @('-C', $Sb.Clone, 'init', '-q') | Out-Null
        Invoke-Git @('-C', $Sb.Clone, 'add', '-A') | Out-Null
        Invoke-Git @('-C', $Sb.Clone, 'commit', '-q', '-m', 'initial') | Out-Null
    }

    function Save-FakeTaskList($Sb, $Tasks) {
        Set-Content -LiteralPath (Join-Path $Sb.Root 'tasks.json') -Value (ConvertTo-Json -InputObject @($Tasks) -Depth 8)
    }

    function Get-FakeTaskList($Sb) {
        $f = Join-Path $Sb.Root 'tasks.json'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        $parsed = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        @(foreach ($t in $parsed) { $t })
    }

    function New-FakeTask([string]$Name, [string]$Execute, [string]$Arguments, [string]$WorkingDirectory, [string]$UserId = 'TESTDOM\tester', [switch]$Deny) {
        [pscustomobject]@{
            TaskName  = $Name
            TaskPath  = '\Tests\'
            Actions   = @([pscustomobject]@{ Execute = $Execute; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory })
            Triggers  = @([pscustomobject]@{ Kind = 'Daily'; StartBoundary = '2026-01-01T09:00:00'; DaysInterval = 1 })
            Principal = [pscustomobject]@{ UserId = $UserId; LogonType = 'Interactive' }
            Settings  = [pscustomobject]@{ RunOnlyIfNetworkAvailable = $false }
            Deny      = [bool]$Deny
        }
    }

    # What install.ps1 leaves behind, for a clone at <From>\gitconfig:
    # ~/.gitconfig rendered from the template, the two home links, both
    # editions' Ctrl-G profile blocks and the login task.
    function Set-InstalledState($Sb) {
        $fwd = $Sb.Clone -replace '\\', '/'
        $template = [IO.File]::ReadAllText((Join-Path $Sb.Clone '.gitconfig.template'))
        $rendered = $template.Replace('{{REPO_PATH}}', $fwd).Replace('{{HOME_DIR}}', ($Sb.Home -replace '\\', '/'))
        [IO.File]::WriteAllText((Join-Path $Sb.Home '.gitconfig'), $rendered)
        if ($script:canSymlink) {
            foreach ($f in '.gitignore_global', 'gitconfig_helper.py') {
                New-Item -ItemType SymbolicLink -Path (Join-Path $Sb.Home $f) -Target (Join-Path $Sb.Clone $f) | Out-Null
            }
        }
        foreach ($edition in 'PowerShell', 'WindowsPowerShell') {
            $dir = Join-Path $Sb.Home "Documents\$edition"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $block = "# my profile`r`n# >>> gitconfig git-alias browser (Ctrl-G) >>>`r`n. '$($Sb.Clone)\scripts\shell\git-alias-widget.ps1'`r`n# <<< gitconfig git-alias browser <<<`r`n"
            [IO.File]::WriteAllText((Join-Path $dir 'profile.ps1'), $block, (New-Object System.Text.UTF8Encoding($true)))
        }
        $updater = Join-Path $Sb.Clone 'scripts\windows version\Update-GitConfig.ps1'
        $login = New-FakeTask -Name 'GitConfig Pull at Login' -Execute 'PowerShell.exe' `
            -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updater`" -RepoPath `"$($Sb.Clone)`""
        $login.TaskPath = '\'
        Save-FakeTaskList $Sb @($login)
    }

    # Run the tool in a child PowerShell of this edition. -Arguments maps
    # parameter names to values ($true = a switch). Stdin is redirected and
    # closed, as in an unattended run.
    function Invoke-Move {
        param(
            $Sb,
            [System.Collections.IDictionary]$Arguments = @{},
            [string]$Answer = '<none>',
            [string]$Tool,
            [string]$WorkingDirectory,
            [switch]$DriveRunning,
            [switch]$RealReadHost
        )
        if (-not $Tool) { $Tool = Join-Path $Sb.Clone $script:toolRel }
        $argText = @(foreach ($k in $Arguments.Keys) {
                $v = $Arguments[$k]
                if ($v -is [bool]) { if ($v) { "-$k" } }
                else { "-$k '$($v.Replace("'", "''"))'" }
            }) -join ' '
        $prelude = $script:prelude
        if ($RealReadHost) { $prelude = $prelude -replace '(?m)^function global:Read-Host .*$', '' }
        # A parameter binding error (a mistyped option) leaves $LASTEXITCODE at
        # 0 but $? false: report it as 1, as pwsh -File does.
        $command = "$prelude`n`$global:LASTEXITCODE = 0`n& '$($Tool.Replace("'", "''"))' $argText`nif (-not `$? -and `$LASTEXITCODE -eq 0) { exit 1 }`nexit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $logPath = Join-Path $Sb.Root 'calls.log'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:pwshPath
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $Sb.Root }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['MSR_HOME'] = $Sb.Home
        $psi.EnvironmentVariables['MSR_ROOT'] = $Sb.Root
        $psi.EnvironmentVariables['MSR_ANSWER'] = $Answer
        $psi.EnvironmentVariables['MSR_DRIVE'] = if ($DriveRunning) { '1' } else { '' }
        $logBefore = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath).Count } else { 0 }
        $proc = [Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $log = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $logBefore) } else { @() }
        # With -EncodedCommand the child also serializes its streams to stderr
        # as CLIXML; the readable text is on stdout.
        $errText = $stderr.Result
        if ($errText.TrimStart().StartsWith('#< CLIXML')) { $errText = '' }
        [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Output   = $stdout.Result + $errText
            Log      = $log
        }
    }

    # Paths and link targets of everything under Root, with each file's size
    # and write time. (A folder's write time is left out: NTFS updates it
    # lazily, so it can change after a read with nothing written.)
    function Get-TreeSnapshot([string]$Root) {
        @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
                $stat = if ($_.PSIsContainer) { 'dir' } else { "$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
                "$($_.FullName.Substring($Root.Length))|$($_.LinkType)|$(@($_.Target)[0])|$stat"
            })
    }

    function Get-RunDir($Sb) { @(Get-ChildItem -LiteralPath $Sb.Home -Directory -Force -Filter '.scripts-move-*') }

    function Get-Report($Sb) {
        $dir = Get-RunDir $Sb | Select-Object -Last 1
        [IO.File]::ReadAllText((Join-Path $dir.FullName 'report.txt'))
    }

    function Get-FileHashText([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

    # A Claude Code project folder name for a path.
    function ConvertTo-ProjectName([string]$Path) { $Path -replace '[^A-Za-z0-9]', '-' }
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:savedGitGlobal
    $env:GIT_CONFIG_NOSYSTEM = $script:savedGitNoSystem
}

Describe 'Move-ScriptsRoot.ps1' {

    Context 'Options and help (R1)' {
        It 'declares -From, -To, -DryRun, -Yes and -AllowSyncedTarget with the documented defaults' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:realTool, [ref]$null, [ref]$null)
            $params = @{}
            foreach ($p in $ast.ParamBlock.Parameters) { $params[$p.Name.VariablePath.UserPath] = $p }
            foreach ($name in 'From', 'To', 'DryRun', 'Yes', 'AllowSyncedTarget') { $params.ContainsKey($name) | Should -BeTrue }
            $params['From'].DefaultValue.Extent.Text | Should -Be '"$env:USERPROFILE\Documents\Scripts"'
            $params['To'].DefaultValue.Extent.Text | Should -Be '"$env:USERPROFILE\Scripts"'
            foreach ($name in 'DryRun', 'Yes', 'AllowSyncedTarget') {
                $params[$name].StaticType | Should -Be ([System.Management.Automation.SwitchParameter])
            }
        }

        It 'prints usage for -Help and -h and exits 0' {
            foreach ($flag in '-Help', '-h') {
                $out = & $script:pwshPath -NoProfile -NonInteractive -File $script:realTool $flag | Out-String
                $LASTEXITCODE | Should -Be 0
                $out | Should -Match 'USAGE:'
                $out | Should -Match '-AllowSyncedTarget'
                $out | Should -Match ([regex]::Escape('$HOME\Documents\Scripts'))
            }
        }

        It 'prints help for -? and exits 0' {
            # From a PowerShell prompt (Windows PowerShell 5.1 ignores -? after -File).
            $out = & $script:pwshPath -NoProfile -NonInteractive -Command "& '$($script:realTool)' -?" | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'Move the Scripts root out of Documents'
        }

        It 'rejects a mistyped option instead of running (exit 1)' {
            $sb = New-MoveSandbox
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; DryRn = $true })
            $r.ExitCode | Should -Be 1
            Test-Path -LiteralPath $sb.From | Should -BeTrue
            Test-Path -LiteralPath $sb.To | Should -BeFalse
        }
    }

    Context 'Preflight (R3, R4)' {
        BeforeEach {
            $sb = New-MoveSandbox
            Set-Content -LiteralPath (Join-Path $sb.From 'keep.txt') -Value 'data'
            $before = Get-TreeSnapshot $sb.Home
        }

        It 'aborts with exit 1 when From and To are the same folder (R3a)' {
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $sb.From; Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'same folder, or one is inside the other'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'aborts with exit 1 when To is inside From (R3a)' {
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = (Join-Path $sb.From 'inner'); Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'one is inside the other'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'aborts with exit 1 when neither From nor To exists (R3b)' {
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = (Join-Path $sb.Home 'nope'); To = (Join-Path $sb.Home 'nope2'); Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Neither From .* nor To .* exists'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'aborts with exit 1 when both exist and To is not empty (R3c)' {
            New-Item -ItemType Directory -Path $sb.To | Out-Null
            Set-Content -LiteralPath (Join-Path $sb.To 'other.txt') -Value 'x'
            $before = Get-TreeSnapshot $sb.Home
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'is not an empty folder'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'aborts with exit 1 when To is on another volume (R3d)' {
            $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
            $letter = @([char[]](90..68) | Where-Object { $used -notcontains [string]$_ })[0]
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = "${letter}:\Scripts"; Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'different volumes'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'refuses a To under ~/Documents without -AllowSyncedTarget, and moves with it (R4)' {
            $to = Join-Path $sb.Home 'Documents\Scripts2'
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $to; Yes = $true })
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'cloud sync'
            Get-TreeSnapshot $sb.Home | Should -Be $before

            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $to; Yes = $true; AllowSyncedTarget = $true })
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $to 'keep.txt') | Should -BeTrue
            Test-Path -LiteralPath $sb.From | Should -BeFalse
            # This checkout's tool isn't in the moved root: generators skipped, and said so.
            $r.Output | Should -Match "generators were skipped"
        }
    }

    Context 'Google Drive (R5) and confirmation (R2, R6)' {
        BeforeEach {
            $sb = New-MoveSandbox
            Install-Clone $sb
            $before = Get-TreeSnapshot $sb.Home
        }

        It 'exits 2 with nothing changed when Drive is running and the answer is no' {
            $r = Invoke-Move -Sb $sb -DriveRunning -Answer 'n' -Arguments ([ordered]@{ From = $sb.From; To = $sb.To })
            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Google Drive for desktop is running'
            @($r.Log | Where-Object { $_ -like 'prompt|*' }).Count | Should -Be 1
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'exits 2 with nothing changed when Drive is running and there is no input' {
            $r = Invoke-Move -Sb $sb -DriveRunning -RealReadHost -Arguments ([ordered]@{ From = $sb.From; To = $sb.To })
            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'No answer'
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'exits 2 after printing the plan when the confirmation is declined' {
            $r = Invoke-Move -Sb $sb -Answer 'n' -Arguments ([ordered]@{ From = $sb.From; To = $sb.To })
            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'Plan'
            @($r.Log | Where-Object { $_ -like 'prompt|*' }).Count | Should -Be 1
            Get-TreeSnapshot $sb.Home | Should -Be $before
        }

        It 'moves after a yes to both questions' {
            $r = Invoke-Move -Sb $sb -DriveRunning -Answer 'y' -Arguments ([ordered]@{ From = $sb.From; To = $sb.To })
            $r.ExitCode | Should -Be 0
            @($r.Log | Where-Object { $_ -like 'prompt|*' }).Count | Should -Be 2
            Test-Path -LiteralPath $sb.To | Should -BeTrue
            Test-Path -LiteralPath $sb.From | Should -BeFalse
        }
    }

    Context 'Move (R8, R9, R10)' {
        It 'leaves everything in place and exits 1 when the rename fails (R8)' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            $before = Get-TreeSnapshot $sb.Home
            # A file held open under From blocks a directory rename on Windows.
            $held = [IO.File]::Open((Join-Path $sb.Clone 'pyproject.toml'), 'Open', 'Read', 'None')
            try {
                $r = Invoke-Move -Sb $sb -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            }
            finally { $held.Dispose() }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'Close the programs and terminals'
            Test-Path -LiteralPath $sb.To | Should -BeFalse
            Get-TreeSnapshot $sb.Home | Should -Be $before
            @(Get-RunDir $sb).Count | Should -Be 0
        }

        It 'renames with one Directory.Move call and never copies (R8)' {
            $source = Get-Content -LiteralPath $script:realTool -Raw
            ([regex]::Matches($source, '\[IO\.Directory\]::Move\(\$From, \$To\)')).Count | Should -Be 1
            $source | Should -Not -Match 'Copy-Item[^\r\n]*\$From'
            $source | Should -Not -Match 'robocopy'
        }

        It 'succeeds when started from its own copy with the working directory inside From (R9)' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            $r = Invoke-Move -Sb $sb -WorkingDirectory $sb.Clone -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $sb.To 'gitconfig\.gitconfig.template') | Should -BeTrue
            Test-Path -LiteralPath $sb.From | Should -BeFalse
        }

        It 'changes nothing on a second run and exits 0 (R10)' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            Set-InstalledState $sb
            $r = Invoke-Move -Sb $sb -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 0

            $tree = Get-TreeSnapshot $sb.Home
            $tasks = Get-Content -LiteralPath (Join-Path $sb.Root 'tasks.json') -Raw
            $r = Invoke-Move -Sb $sb -Tool (Join-Path $sb.To "gitconfig\$script:toolRel") -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'already moved; resuming repairs'
            $r.Output | Should -Match 'Nothing to do'
            Get-TreeSnapshot $sb.Home | Should -Be $tree
            Get-Content -LiteralPath (Join-Path $sb.Root 'tasks.json') -Raw | Should -Be $tasks
            @($r.Log | Where-Object { $_ -like 'set|*' -or $_ -like 'register|*' }).Count | Should -Be 0
        }

        It 'finishes the repairs after a manual move (R10)' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            Set-InstalledState $sb
            [IO.Directory]::Move($sb.From, $sb.To)
            $r = Invoke-Move -Sb $sb -Tool (Join-Path $sb.To "gitconfig\$script:toolRel") -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'already moved; resuming repairs'
            $gitconfig = [IO.File]::ReadAllText((Join-Path $sb.Home '.gitconfig'))
            $gitconfig | Should -Match ([regex]::Escape(($sb.To -replace '\\', '/') + '/gitconfig'))
            $gitconfig | Should -Not -Match ([regex]::Escape(($sb.From -replace '\\', '/')))
        }
    }

    Context 'Dry run (R7)' {
        It 'prints the plan and changes nothing at all' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            Set-InstalledState $sb
            New-Item -ItemType Directory -Path (Join-Path $sb.Home '.claude') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $sb.Home '.claude\settings.json'), "{`"dir`": `"$($sb.From -replace '\\', '\\')`"}")
            New-Item -ItemType Junction -Path (Join-Path $sb.Home '.claude\skills') -Target $sb.Clone | Out-Null
            $before = Get-TreeSnapshot $sb.Root
            $r = Invoke-Move -Sb $sb -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; DryRun = $true })
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Dry run: nothing was changed'
            $r.Output | Should -Match ([regex]::Escape('settings.json (1 match)'))
            # Everything under the sandbox root: home, tasks and environment files.
            Get-TreeSnapshot $sb.Root | Should -Be $before
            @(Get-RunDir $sb).Count | Should -Be 0
        }
    }

    Context 'Worktrees (R11)' {
        It 'repairs a worktree inside the repo and a sibling one' {
            $sb = New-MoveSandbox
            Install-Clone $sb
            $inside = Join-Path $sb.Clone '.claude\worktrees\wt-in'
            $sibling = Join-Path $sb.From 'gitconfig-wt'
            Invoke-Git @('-C', $sb.Clone, 'worktree', 'add', '-q', '-b', 'wt-in', $inside) | Out-Null
            Invoke-Git @('-C', $sb.Clone, 'worktree', 'add', '-q', '-b', 'wt-out', $sibling) | Out-Null

            $r = Invoke-Move -Sb $sb -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Repos and worktrees to repair:'

            $newClone = Join-Path $sb.To 'gitconfig'
            foreach ($wt in (Join-Path $newClone '.claude\worktrees\wt-in'), (Join-Path $sb.To 'gitconfig-wt')) {
                $ErrorActionPreference = 'Continue'
                & git -C $wt status --short 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
            }
            $list = Invoke-Git @('-C', $newClone, 'worktree', 'list', '--porcelain')
            $list | Should -Not -Match 'prunable'
            $list | Should -Not -Match ([regex]::Escape(($sb.From -replace '\\', '/')))
            $list | Should -Match ([regex]::Escape(($sb.To -replace '\\', '/') + '/gitconfig-wt'))
        }
    }

    Context 'Project folder collision (R17, R18)' {
        It 'leaves a folder whose new name is taken, reports it and exits 1' {
            $sb = New-MoveSandbox
            $projects = Join-Path $sb.Home '.claude\projects'
            $old = (ConvertTo-ProjectName $sb.From) + '-dup'
            $new = (ConvertTo-ProjectName $sb.To) + '-dup'
            New-Item -ItemType Directory -Path (Join-Path $projects $old), (Join-Path $projects $new) -Force | Out-Null
            $r = Invoke-Move -Sb $sb -Tool $script:realTool -Arguments ([ordered]@{ From = $sb.From; To = $sb.To; Yes = $true })
            $r.ExitCode | Should -Be 1
            Test-Path -LiteralPath (Join-Path $projects $old) | Should -BeTrue
            $report = Get-Report $sb
            $report | Should -Match '(?s)\(c\) Remaining references.*already exists, merge them by hand'
        }
    }

    Context 'A full run on an installed machine (R11-R20)' {
        BeforeAll {
            $sb = New-MoveSandbox
            Install-Clone $sb
            Set-InstalledState $sb
            $F = $sb.From
            $T = $sb.To
            $H = $sb.Home
            $Fj = $F -replace '\\', '\\'
            $Tj = $T -replace '\\', '\\'
            $Ff = $F -replace '\\', '/'
            $Tf = $T -replace '\\', '/'
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            $utf16 = New-Object System.Text.UnicodeEncoding($false, $true)

            # --- R14 fixtures: before and expected after, per encoding ---------
            $fixtures = @(
                [pscustomobject]@{
                    Rel = 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'; Encoding = $utf8Bom; NewLine = "`r`n"
                    Before = @(
                        "`$a = '$F\gitconfig'", "`$b = `"$F`"", "`$c = '$Ff/x'",
                        '$d = "$HOME\Documents\Scripts\y"', '$e = "$env:USERPROFILE\Documents\Scripts"',
                        "`$f = '~/Documents/Scripts/z'", "`$g = '%USERPROFILE%\Documents\Scripts\w'",
                        "`$h = '$($F.ToLowerInvariant())\lower'", "`$i = '${F}Old\q'", "# see $F"
                    )
                    After  = @(
                        "`$a = '$T\gitconfig'", "`$b = `"$T`"", "`$c = '$Tf/x'",
                        '$d = "$HOME\Scripts\y"', '$e = "$env:USERPROFILE\Scripts"',
                        "`$f = '~/Scripts/z'", "`$g = '%USERPROFILE%\Scripts\w'",
                        "`$h = '$T\lower'", "`$i = '${F}Old\q'", "# see $T"
                    )
                }
                [pscustomobject]@{
                    Rel = 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'; Encoding = $utf16; NewLine = "`r`n"
                    Before = @("Set-Location '$F\gitconfig'", "# ${F}Old stays")
                    After  = @("Set-Location '$T\gitconfig'", "# ${F}Old stays")
                }
                [pscustomobject]@{
                    Rel = '.claude\settings.json'; Encoding = $utf8; NewLine = "`n"
                    Before = @('{', "  `"a`": `"$Fj\\x`",", '  "b": "%USERPROFILE%\\Documents\\Scripts",', "  `"decoy`": `"${Fj}Old`"", '}')
                    After  = @('{', "  `"a`": `"$Tj\\x`",", '  "b": "%USERPROFILE%\\Scripts",', "  `"decoy`": `"${Fj}Old`"", '}')
                }
                [pscustomobject]@{
                    Rel = '.claude\scheduled-tasks\nightly\SKILL.md'; Encoding = $utf8; NewLine = "`n"
                    Before = @('# Nightly', "Run ``$Ff/tool/run.sh`` in $F\tool")
                    After  = @('# Nightly', "Run ``$Tf/tool/run.sh`` in $T\tool")
                }
                [pscustomobject]@{
                    Rel = '.vscode\workspaces\work.code-workspace'; Encoding = $utf8; NewLine = "`r`n"
                    Before = @('{', '  "folders": [', '    { "path": "../../Documents/Scripts/gitconfig" },', '    { "path": "..\\..\\Documents\\Scripts\\other" },', '    { "path": "../../Documents/ScriptsOld" }', '  ]', '}')
                    After  = @('{', '  "folders": [', '    { "path": "../../Scripts/gitconfig" },', '    { "path": "..\\..\\Scripts\\other" },', '    { "path": "../../Documents/ScriptsOld" }', '  ]', '}')
                }
                [pscustomobject]@{
                    Rel = '.vscode\agent-plugins\acme\nested\.mcp.json'; Encoding = $utf8; NewLine = "`n"
                    Before = @("{`"command`": `"$Fj\\mcp\\server.exe`", `"cwd`": `"$Ff/mcp`"}")
                    After  = @("{`"command`": `"$Tj\\mcp\\server.exe`", `"cwd`": `"$Tf/mcp`"}")
                }
                [pscustomobject]@{
                    Rel = '.gitconfig.local'; Encoding = $utf8; NewLine = "`n"
                    Before = @('[safe]', "`tdirectory = $Ff/gitconfig", "`tdirectory = $Ff/other")
                    After  = @('[safe]', "`tdirectory = $Tf/gitconfig", "`tdirectory = $Tf/other")
                }
                [pscustomobject]@{
                    Rel = '.config\gitconfig\safe-directories'; Encoding = $utf8; NewLine = "`r`n"
                    Before = @('# trusted', "$F\shared")
                    After  = @('# trusted', "$T\shared")
                }
                [pscustomobject]@{
                    Rel = '.bashrc'; Encoding = $utf8; NewLine = "`n"
                    Before = @('export PATH="$HOME/Documents/Scripts/bin:$PATH"')
                    After  = @('export PATH="$HOME/Scripts/bin:$PATH"')
                }
            )
            foreach ($fx in $fixtures) {
                $fx | Add-Member -NotePropertyName Path -NotePropertyValue (Join-Path $H $fx.Rel)
                $pre = $fx.Encoding.GetPreamble()
                $fx | Add-Member -NotePropertyName BeforeBytes -NotePropertyValue ([byte[]]($pre + $fx.Encoding.GetBytes(($fx.Before -join $fx.NewLine) + $fx.NewLine)))
                $fx | Add-Member -NotePropertyName AfterBytes -NotePropertyValue ([byte[]]($pre + $fx.Encoding.GetBytes(($fx.After -join $fx.NewLine) + $fx.NewLine)))
                New-Item -ItemType Directory -Path (Split-Path -Parent $fx.Path) -Force | Out-Null
                [IO.File]::WriteAllBytes($fx.Path, $fx.BeforeBytes)
            }

            # --- R13 links: a junction and a symbolic link into From ----------
            New-Item -ItemType Directory -Path (Join-Path $F 'agent-skills'), (Join-Path $F 'tools') -Force | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $H '.claude\skills') -Target (Join-Path $F 'agent-skills') | Out-Null
            if ($script:canSymlink) {
                New-Item -ItemType Directory -Path (Join-Path $H '.config\acme') -Force | Out-Null
                New-Item -ItemType SymbolicLink -Path (Join-Path $H '.config\acme\tools') -Target (Join-Path $F 'tools') | Out-Null
                # A dotfile linked into a repo: the link is re-pointed, the
                # repo's file is never edited (R20).
                New-Item -ItemType Directory -Path (Join-Path $F 'dotfiles') -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $F 'dotfiles\zshrc'), "source $Ff/dotfiles/aliases`n")
                New-Item -ItemType SymbolicLink -Path (Join-Path $H '.zshrc') -Target (Join-Path $F 'dotfiles\zshrc') | Out-Null
            }

            # --- R15 tasks ------------------------------------------------------
            $tasks = @(Get-FakeTaskList $sb)
            $tasks += New-FakeTask -Name 'Sync' -Execute "$F\tools\sync.cmd" -Arguments "-File `"$F\tools\sync.ps1`" -Log `"${F}Old\log`"" -WorkingDirectory $F
            $tasks += New-FakeTask -Name 'Machine' -Execute "$F\tools\m.cmd" -Arguments '' -WorkingDirectory '' -UserId 'SYSTEM'
            $tasks += New-FakeTask -Name 'Locked' -Execute "$F\tools\l.cmd" -Arguments '' -WorkingDirectory '' -Deny
            $tasks += New-FakeTask -Name 'Other' -Execute 'C:\Windows\notepad.exe' -Arguments '' -WorkingDirectory ''
            Save-FakeTaskList $sb $tasks
            $originalSync = $tasks | Where-Object { $_.TaskName -eq 'Sync' }

            # --- R16 environment and shortcuts ---------------------------------
            $envData = [ordered]@{
                User    = [ordered]@{
                    Path = [ordered]@{ Value = "C:\Windows;$F\bin;%USERPROFILE%\Documents\Scripts\tools;${F}Old"; Kind = 'ExpandString' }
                    TOOLS_HOME = [ordered]@{ Value = "$F\tools"; Kind = 'String' }
                    UNRELATED = [ordered]@{ Value = 'C:\Program Files\x'; Kind = 'String' }
                }
                Machine = [ordered]@{ PATH = [ordered]@{ Value = "C:\Windows;$F\machine-bin"; Kind = 'ExpandString' } }
            }
            [IO.File]::WriteAllText((Join-Path $sb.Root 'env.json'), ($envData | ConvertTo-Json -Depth 5))
            $script:realUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $script:realUserEnv = @(Get-Item -LiteralPath 'HKCU:\Environment' | ForEach-Object { foreach ($n in $_.GetValueNames()) { "$n=$($_.GetValue($n, $null, 'DoNotExpandEnvironmentNames'))" } })

            New-Item -ItemType Directory -Path (Join-Path $F 'tools') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $F 'tools\app.exe') -Value ''
            $shell = New-Object -ComObject WScript.Shell
            $lnkPaths = @((Join-Path $H 'Desktop\App.lnk'), (Join-Path $H 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Boot.lnk'))
            foreach ($p in $lnkPaths) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
                $lnk = $shell.CreateShortcut($p)
                $lnk.TargetPath = "$F\tools\app.exe"
                $lnk.Arguments = "--root `"$F`""
                $lnk.WorkingDirectory = "$F\tools"
                $lnk.IconLocation = "$F\tools\app.exe,0"
                $lnk.Save()
            }

            # --- R17 Claude project folders ------------------------------------
            $projects = Join-Path $H '.claude\projects'
            $encF = ConvertTo-ProjectName $F
            $encT = ConvertTo-ProjectName $T
            foreach ($n in $encF, "$encF-gitconfig", "${encF}Old", 'C--elsewhere') {
                New-Item -ItemType Directory -Path (Join-Path $projects $n) -Force | Out-Null
            }

            # --- R18 report-only and R20 untouchables --------------------------
            New-Item -ItemType Directory -Path (Join-Path $F 'pyproj\.venv') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $F 'pyproj\.venv\pyvenv.cfg') -Value "home = C:\Python312`ncommand = python -m venv $F\pyproj\.venv"
            [IO.File]::WriteAllText((Join-Path $H '.claude.json'), "{`"projects`": {`"$Fj\\gitconfig`": {}}}")
            $claudeJsonHash = Get-FileHashText (Join-Path $H '.claude.json')
            $other = Join-Path $F 'other-repo'
            New-Item -ItemType Directory -Path $other -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $other 'notes.txt'), "Lives in $F\other-repo`n")
            Invoke-Git @('-C', $other, 'init', '-q') | Out-Null
            Invoke-Git @('-C', $other, 'add', '-A') | Out-Null
            Invoke-Git @('-C', $other, 'commit', '-q', '-m', 'notes') | Out-Null
            $notesHash = Get-FileHashText (Join-Path $other 'notes.txt')

            $result = Invoke-Move -Sb $sb -Arguments ([ordered]@{ From = $F; To = $T; Yes = $true })
            $report = Get-Report $sb
            $runDir = (Get-RunDir $sb | Select-Object -Last 1).FullName
            $newClone = Join-Path $T 'gitconfig'
        }

        It 'exits 0 and prints every plan category before the changes (R2, R6)' {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            $planText = ($result.Output -split '\[OK\] Moved')[0]
            foreach ($header in 'Move:', 'Repos and worktrees to repair:', "This repo's generators to re-run", 'Files to rewrite:',
                'Links to re-point:', 'Scheduled tasks to update:', 'User environment variables to update:',
                'Shortcuts to update:', 'Claude project folders to rename:', 'Report only (not changed):') {
                $planText | Should -Match ([regex]::Escape($header))
            }
            $planText | Should -Match ([regex]::Escape("$F -> $T"))
            $planText | Should -Match ([regex]::Escape('settings.json (2 matches)'))
            $planText | Should -Match ([regex]::Escape("$H\.claude\skills [Junction] -> $T\agent-skills"))
            $planText | Should -Match ([regex]::Escape('\Tests\Sync'))
            $planText | Should -Match 'TOOLS_HOME'
            $planText | Should -Match ([regex]::Escape('App.lnk'))
            $planText | Should -Match ([regex]::Escape("$projects\$encF-gitconfig"))
            $planText | Should -Match 'Python venv to recreate'
        }

        It 'moves the root with no link left at the old path (R8)' {
            Test-Path -LiteralPath $F | Should -BeFalse
            Get-Item -LiteralPath $F -Force -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $newClone '.gitconfig.template') | Should -BeTrue
        }

        It "re-runs this repo's generators from the new clone (R12)" {
            $gitconfig = [IO.File]::ReadAllText((Join-Path $H '.gitconfig'))
            $gitconfig | Should -Match ([regex]::Escape("$Tf/gitconfig/gitconfig_helper.py"))
            $gitconfig | Should -Not -Match ([regex]::Escape($Ff))
            if ($script:canSymlink) {
                foreach ($f in '.gitignore_global', 'gitconfig_helper.py') {
                    $link = Get-Item -LiteralPath (Join-Path $H $f) -Force
                    $link.LinkType | Should -Be 'SymbolicLink'
                    @($link.Target)[0] | Should -Be (Join-Path $newClone $f)
                }
            }
            $login = Get-FakeTaskList $sb | Where-Object { $_.TaskName -eq 'GitConfig Pull at Login' }
            $login.Actions[0].Arguments | Should -Match ([regex]::Escape("-RepoPath `"$newClone`""))
            $login.Actions[0].Arguments | Should -Not -Match ([regex]::Escape($F))
            foreach ($edition in 'PowerShell', 'WindowsPowerShell') {
                $profileText = [IO.File]::ReadAllText((Join-Path $H "Documents\$edition\profile.ps1"))
                $profileText | Should -Match ([regex]::Escape(". '$newClone\scripts\shell\git-alias-widget.ps1'"))
                $profileText | Should -Not -Match ([regex]::Escape($F))
            }
        }

        It 'keeps each link type and points it under To (R13)' {
            $junction = Get-Item -LiteralPath (Join-Path $H '.claude\skills') -Force
            $junction.LinkType | Should -Be 'Junction'
            @($junction.Target)[0] | Should -Be (Join-Path $T 'agent-skills')
            if ($script:canSymlink) {
                $symlink = Get-Item -LiteralPath (Join-Path $H '.config\acme\tools') -Force
                $symlink.LinkType | Should -Be 'SymbolicLink'
                @($symlink.Target)[0] | Should -Be (Join-Path $T 'tools')
            }
        }

        It 'rewrites every path form, leaves the decoys, and keeps encoding and line endings byte for byte (R14)' {
            foreach ($fx in $fixtures) {
                $actual = [IO.File]::ReadAllBytes($fx.Path)
                [Convert]::ToBase64String($actual) | Should -Be ([Convert]::ToBase64String($fx.AfterBytes)) -Because $fx.Rel
            }
        }

        It 'updates the actions of its own task and passes triggers and principal through (R15)' {
            $sets = @($result.Log | Where-Object { $_ -like 'set|*' } | ForEach-Object { $_.Substring(4) | ConvertFrom-Json })
            $sync = @($sets | Where-Object { $_.TaskName -eq 'Sync' })
            $sync.Count | Should -Be 1
            $sync[0].Actions[0].Execute | Should -Be "$T\tools\sync.cmd"
            $sync[0].Actions[0].Arguments | Should -Be "-File `"$T\tools\sync.ps1`" -Log `"${F}Old\log`""
            $sync[0].Actions[0].WorkingDirectory | Should -Be $T
            ($sync[0].Triggers | ConvertTo-Json -Depth 5 -Compress) | Should -Be ($originalSync.Triggers | ConvertTo-Json -Depth 5 -Compress)
            ($sync[0].Principal | ConvertTo-Json -Compress) | Should -Be ($originalSync.Principal | ConvertTo-Json -Compress)
            @($sets | Where-Object { $_.TaskName -in 'Machine', 'Other' }).Count | Should -Be 0
            $report | Should -Match '(?s)\(d\) Report only.*\\Tests\\Machine'
            $report | Should -Match '(?s)\(d\) Report only.*\\Tests\\Locked'
        }

        It 'rewrites user environment variables through the env layer only (R16)' {
            $data = [IO.File]::ReadAllText((Join-Path $sb.Root 'env.json')) | ConvertFrom-Json
            $data.User.Path.Value | Should -Be "C:\Windows;$T\bin;%USERPROFILE%\Scripts\tools;${F}Old"
            $data.User.Path.Kind | Should -Be 'ExpandString'
            $data.User.TOOLS_HOME.Value | Should -Be "$T\tools"
            $data.User.UNRELATED.Value | Should -Be 'C:\Program Files\x'
            $data.Machine.PATH.Value | Should -Be "C:\Windows;$F\machine-bin"
            $report | Should -Match '(?s)\(d\) Report only.*machine environment variable PATH'
            # The runner's own environment is untouched.
            [Environment]::GetEnvironmentVariable('Path', 'User') | Should -Be $script:realUserPath
            @(Get-Item -LiteralPath 'HKCU:\Environment' | ForEach-Object { foreach ($n in $_.GetValueNames()) { "$n=$($_.GetValue($n, $null, 'DoNotExpandEnvironmentNames'))" } }) |
                Should -Be $script:realUserEnv
        }

        It 'rewrites .lnk shortcuts on the Desktop and in Startup (R16)' {
            $shell = New-Object -ComObject WScript.Shell
            foreach ($p in $lnkPaths) {
                $lnk = $shell.CreateShortcut($p)
                $lnk.TargetPath | Should -Be "$T\tools\app.exe"
                $lnk.Arguments | Should -Be "--root `"$T`""
                $lnk.WorkingDirectory | Should -Be "$T\tools"
                $lnk.IconLocation | Should -Be "$T\tools\app.exe,0"
            }
        }

        It 'renames only the Claude project folders of the old root (R17)' {
            Test-Path -LiteralPath (Join-Path $projects $encT) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $projects "$encT-gitconfig") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $projects $encF) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $projects "$encF-gitconfig") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $projects "${encF}Old") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $projects 'C--elsewhere') | Should -BeTrue
        }

        It 'writes the report with sections (a)-(d); report-only items do not fail the run (R18)' {
            $runDir | Should -Match '\\\.scripts-move-\d{8}-\d{6}$'
            $report | Should -Match '\(a\) Changes made:'
            $report | Should -Match '\(b\) Failures:\r?\n  \(none\)'
            $report | Should -Match '\(c\) Remaining references to the old root \(counted as failures\):\r?\n  \(none\)'
            $report | Should -Match '\(d\) Report only'
            $report | Should -Match ([regex]::Escape("Python venv to recreate: $T\pyproj\.venv"))
            $report | Should -Match ([regex]::Escape("App state that mentions the old root: $H\.claude.json"))
            $report | Should -Match 'Result: OK'
            $result.Output | Should -Match ([regex]::Escape('(a) Changes made:'))
        }

        It 'backs up every rewritten file byte for byte and records links and tasks (R19)' {
            foreach ($fx in $fixtures) {
                $backup = Join-Path $runDir "backup\$($fx.Rel)"
                Test-Path -LiteralPath $backup | Should -BeTrue -Because $fx.Rel
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) | Should -Be ([Convert]::ToBase64String($fx.BeforeBytes))
            }
            $records = [IO.File]::ReadAllText((Join-Path $runDir 'backup\links-and-tasks.txt'))
            $records | Should -Match ([regex]::Escape("link $H\.claude\skills [Junction] was -> $F\agent-skills"))
            $records | Should -Match ([regex]::Escape("task \Tests\Sync was Execute=$F\tools\sync.cmd"))
            $records | Should -Match ([regex]::Escape('task \GitConfig Pull at Login was'))
        }

        It 'never edits files inside a repo, app state or the machine scope (R20)' {
            Get-FileHashText (Join-Path $T 'other-repo\notes.txt') | Should -Be $notesHash
            Get-FileHashText (Join-Path $H '.claude.json') | Should -Be $claudeJsonHash
            if ($script:canSymlink) {
                [IO.File]::ReadAllText((Join-Path $T 'dotfiles\zshrc')) | Should -Be "source $Ff/dotfiles/aliases`n"
                @((Get-Item -LiteralPath (Join-Path $H '.zshrc') -Force).Target)[0] | Should -Be (Join-Path $T 'dotfiles\zshrc')
                $report | Should -Match ([regex]::Escape("Link into a repo (not edited): $H\.zshrc"))
            }
        }
    }
}
