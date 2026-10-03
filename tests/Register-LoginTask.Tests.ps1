BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\windows version\Register-LoginTask.ps1"
    $script:updaterPath = Join-Path $script:repoRoot "scripts\windows version\Update-GitConfig.ps1"

    # The ScheduledTasks cmdlets are replaced by global stub functions (functions
    # win over cmdlets in command lookup), so these tests never touch the real
    # Task Scheduler and also run on Linux/macOS pwsh, where it doesn't exist.
    # Each stub records how it was called in $global:rltCalls.
    function global:Get-ScheduledTask {
        [CmdletBinding()] param([string]$TaskName)
        $global:rltExistingTask
    }
    function global:New-ScheduledTaskAction {
        [CmdletBinding()] param([string]$Execute, [string]$Argument)
        $global:rltCalls.Action = $PSBoundParameters
        [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
    }
    function global:New-ScheduledTaskTrigger {
        [CmdletBinding()] param([switch]$AtLogOn, [string]$User)
        $global:rltCalls.TriggerParams = $PSBoundParameters
        $t = [pscustomobject]@{ Delay = $null }
        $global:rltCalls.Trigger = $t
        $t
    }
    function global:New-ScheduledTaskSettingsSet {
        [CmdletBinding()] param(
            [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries,
            [switch]$StartWhenAvailable, [switch]$RunOnlyIfNetworkAvailable,
            [timespan]$ExecutionTimeLimit
        )
        $global:rltCalls.Settings = $PSBoundParameters
        [pscustomobject]@{}
    }
    function global:Register-ScheduledTask {
        [CmdletBinding()] param(
            [string]$TaskName, $Action, $Trigger, $Settings, [string]$Description, [switch]$Force
        )
        $global:rltCalls.Register = $PSBoundParameters
    }
    function global:Unregister-ScheduledTask {
        [CmdletBinding()] param([string]$TaskName, [switch]$Confirm)
        $global:rltCalls.Unregister = $PSBoundParameters
    }

    $script:savedUserDomain = $env:USERDOMAIN
    $script:savedUserName = $env:USERNAME
    $env:USERDOMAIN = "TESTDOM"
    $env:USERNAME = "tester"

    # What the script should register for this checkout.
    $script:expectedArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:updaterPath`" -RepoPath `"$script:repoRoot`""

    function Invoke-Register {
        param([switch]$Force)
        & $script:scriptPath -Force:$Force *> $null
        $LASTEXITCODE
    }
}

AfterAll {
    foreach ($f in 'Get-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger',
        'New-ScheduledTaskSettingsSet', 'Register-ScheduledTask', 'Unregister-ScheduledTask') {
        Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable rltCalls, rltExistingTask -Scope Global -ErrorAction SilentlyContinue
    $env:USERDOMAIN = $script:savedUserDomain
    $env:USERNAME = $script:savedUserName
}

Describe "Register-LoginTask.ps1" {
    BeforeEach {
        $global:rltCalls = @{}
        $global:rltExistingTask = $null
    }

    Context "New task" {
        It "Should exit 0 and register the task" {
            Invoke-Register | Should -Be 0
            $global:rltCalls.Register | Should -Not -BeNullOrEmpty
            $global:rltCalls.Register.TaskName | Should -Be "GitConfig Pull at Login"
        }

        It "Should run the updater with -ExecutionPolicy Bypass and an explicit -RepoPath" {
            Invoke-Register | Out-Null
            $global:rltCalls.Action.Execute | Should -Be "PowerShell.exe"
            $arguments = $global:rltCalls.Action.Argument
            $arguments | Should -Be $script:expectedArgs
            $arguments | Should -Match '-NoProfile -NonInteractive -ExecutionPolicy Bypass'
            # RepoPath is the repo this script lives in, not a fixed Documents path.
            $arguments | Should -Match ([regex]::Escape("-RepoPath `"$script:repoRoot`""))
        }

        It "Should trigger at this user's logon, one minute late" {
            Invoke-Register | Out-Null
            $global:rltCalls.TriggerParams.AtLogOn | Should -BeTrue
            $global:rltCalls.TriggerParams.User | Should -Be "TESTDOM\tester"
            $global:rltCalls.Trigger.Delay | Should -Be "PT1M"
        }

        It "Should cap the run at 10 minutes and need a network" {
            Invoke-Register | Out-Null
            $global:rltCalls.Settings.ExecutionTimeLimit | Should -Be (New-TimeSpan -Minutes 10)
            $global:rltCalls.Settings.RunOnlyIfNetworkAvailable | Should -BeTrue
            $global:rltCalls.Settings.StartWhenAvailable | Should -BeTrue
        }

        It "Should exit 1 when registration fails" {
            function global:Register-ScheduledTask {
                [CmdletBinding()] param($TaskName, $Action, $Trigger, $Settings, $Description, [switch]$Force)
                throw "Access is denied"
            }
            try {
                Invoke-Register | Should -Be 1
            }
            finally {
                function global:Register-ScheduledTask {
                    [CmdletBinding()] param(
                        [string]$TaskName, $Action, $Trigger, $Settings, [string]$Description, [switch]$Force
                    )
                    $global:rltCalls.Register = $PSBoundParameters
                }
            }
        }
    }

    Context "Existing task" {
        It "Should keep an up-to-date task without -Force" {
            $global:rltExistingTask = [pscustomobject]@{
                Actions = @([pscustomobject]@{ Execute = "PowerShell.exe"; Arguments = $script:expectedArgs })
            }
            Invoke-Register | Should -Be 0
            $global:rltCalls.ContainsKey('Register') | Should -BeFalse
            $global:rltCalls.ContainsKey('Unregister') | Should -BeFalse
        }

        It "Should replace a task with old arguments even without -Force" {
            # What older installs registered: no Bypass, no -RepoPath.
            $global:rltExistingTask = [pscustomobject]@{
                Actions = @([pscustomobject]@{
                        Execute   = "PowerShell.exe"
                        Arguments = "-NoProfile -WindowStyle Hidden -File `"$script:updaterPath`""
                    })
            }
            Invoke-Register | Should -Be 0
            $global:rltCalls.Unregister.TaskName | Should -Be "GitConfig Pull at Login"
            $global:rltCalls.Register.Action.Arguments | Should -Be $script:expectedArgs
        }

        It "Should replace an up-to-date task when -Force is given" {
            $global:rltExistingTask = [pscustomobject]@{
                Actions = @([pscustomobject]@{ Execute = "PowerShell.exe"; Arguments = $script:expectedArgs })
            }
            Invoke-Register -Force | Should -Be 0
            $global:rltCalls.ContainsKey('Unregister') | Should -BeTrue
            $global:rltCalls.ContainsKey('Register') | Should -BeTrue
        }
    }
}
