BeforeDiscovery {
    # -Skip conditions are evaluated at discovery, before BeforeAll runs.
    $script:platformIsWindows = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
    # Same condition the setup test below skips on: when it runs, the tests
    # that depend on its result must run too.
    $script:setupRuns = [System.Environment]::UserInteractive -and $script:platformIsWindows
}

BeforeAll {
    # Reads the scheduled task name a script assigns with `$taskName = "..."`.
    # Returns $null when the script has no such assignment.
    function Get-LoginTaskName {
        param([string]$Path)
        $text = Get-Content -LiteralPath $Path -Raw
        if ($text -match '(?m)^\s*\$taskName\s*=\s*"([^"]+)"') { return $Matches[1] }
        return $null
    }

    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:setupScript = Join-Path $script:repoRoot "scripts\windows version\install.ps1"
    $script:cleanupScript = Join-Path $script:repoRoot "scripts\windows version\Cleanup-GitConfig.ps1"
    $script:testHome = $env:USERPROFILE
    if (-not $script:testHome) {
        $script:testHome = $env:HOME  # Unix/Linux fallback
    }

    # The login task's name, read from the script that registers it so these
    # tests can't drift from it again (#245: they looked up "Update-GitConfig",
    # a task no script creates, so both task tests passed vacuously).
    $script:taskName = Get-LoginTaskName -Path (Join-Path $script:repoRoot "scripts\windows version\Register-LoginTask.ps1")

    # Detect platform
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $script:platformIsWindows = $IsWindows
    }
    else {
        $script:platformIsWindows = $true
    }

    # Choose PowerShell executable based on platform
    $script:pwshExe = if ($script:platformIsWindows) { "powershell" } else { "pwsh" }

    # Resolve the Python interpreter per the repo rule: py -> python3 -> python.
    # Never bare `python` first - it's the WindowsApps stub on Windows (exits
    # 9009 or pops the Store prompt) and absent on macOS/Linux (#202). Mirrors
    # gitconfig_helper.Tests.ps1's Resolve-TestPython; kept local here since
    # this file's platform reach (macOS/Linux/Windows) doesn't match
    # Resolve-Python in the Windows-only Functions.ps1.
    $script:python = foreach ($name in 'py', 'python3', 'python') {
        if (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) {
            $name
            break
        }
    }
}

Describe "Integration.Tests.ps1 scheduled task name" -Tag 'Unit' {
    # Runs in the default suite so a rename is caught without -IncludeIntegration.
    It "reads the task name from Register-LoginTask.ps1" {
        $script:taskName | Should -Be "GitConfig Pull at Login"
    }

    It "Cleanup-GitConfig.ps1 removes the task Register-LoginTask.ps1 creates" {
        $cleanupName = Get-LoginTaskName -Path $script:cleanupScript
        $cleanupName | Should -Not -BeNullOrEmpty
        $cleanupName | Should -Be $script:taskName
    }

    It "does not look up a scheduled task by a hardcoded name" {
        $content = Get-Content $PSCommandPath -Raw
        $content | Should -Not -Match 'Get-ScheduledTask\s+-TaskName\s+["\x27]'
    }
}

Describe "Integration.Tests.ps1 Python resolution" -Tag 'Unit' {
    # Static check so a regression is caught by the default (Integration-excluded)
    # suite, not only when someone opts into -IncludeIntegration (#202).
    It "does not invoke bare 'python' - must resolve via py -> python3 -> python" {
        $content = Get-Content $PSCommandPath -Raw
        $content | Should -Not -Match "(?m)^\s*&\s+python\s"
    }
}

Describe "GitConfig Integration" -Tag 'Integration' {

    Context "End-to-End Setup and Verification" {
        It "Should complete setup without errors" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Also skipped on non-Windows platforms as the scripts are Windows-specific
            # Run manually on command line: .\install.ps1 -Force
            & $script:pwshExe -NoProfile -ExecutionPolicy Bypass -File $script:setupScript -Force 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }

        It "Should have all required symlinks after setup" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $helperPath = Join-Path $script:testHome "gitconfig_helper.py"

            $gitconfigPath | Should -Exist
            $helperPath | Should -Exist
        }

        It "Should have valid .gitconfig.local file" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $localConfigPath | Should -Exist

            $content = Get-Content $localConfigPath -Raw
            $content | Should -Match '\[gpg\]'
            $content | Should -Match '\[commit\]'
            $content | Should -Match '\[user\]'
            $content | Should -Match '\[safe\]'
        }

        It ".gitconfig.local should have valid INI format" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"

            # Should not error when git reads it
            & git config -f $localConfigPath --list 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "SSH Signing Configuration" {
        It "Should enable SSH signing in git config" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $gpgFormat = & git config --get gpg.format 2>$null
            $commitGpgSign = & git config --get commit.gpgsign 2>$null

            $gpgFormat | Should -Be "ssh"
            $commitGpgSign | Should -Be "true"
        }

        It "Should configure correct op-ssh-sign.exe path" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $program = & git config --get gpg.ssh.program 2>$null

            $program | Should -Not -BeNullOrEmpty
            $program | Should -Match "op-ssh-sign\.exe"
            $program | Should -Match "WindowsApps"
        }

        It "Should set SSH signing key" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $signingKey = & git config --get user.signingKey 2>$null

            $signingKey | Should -Not -BeNullOrEmpty
            $signingKey | Should -Match "ssh-ed25519"
        }

        It "op-ssh-sign.exe should exist at configured path" -Skip:(-not $platformIsWindows) {
            $program = & git config --get gpg.ssh.program 2>$null

            if ($program) {
                Test-Path $program | Should -Be $true
            }
            else {
                Set-ItResult -Skipped -Because "Setup has not been run (gpg.ssh.program not configured)"
            }
        }
    }

    Context "Scheduled Task" {
        # The setup test above runs install.ps1 without -NoTask, so whenever it
        # runs the task must exist; a missing task is a failed registration, not
        # a skip. Skipped only when setup itself is skipped.
        It "Should create the login scheduled task" -Skip:(-not $setupRuns) {
            $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty -Because "install.ps1 (run without -NoTask) registers '$($script:taskName)'"
        }
    }

    # Between setup and cleanup: once "Cleanup and Reset" has run there is no
    # ~/.gitconfig left to read, so these used to come last and always skip
    # (#262). They skip only when setup itself is skipped; after setup ran, a
    # missing alias or config is a failure.
    Context "Git Aliases" -Skip:(-not $setupRuns) {
        BeforeAll {
            $script:gitconfigPath = Join-Path $script:testHome ".gitconfig"
        }

        It "git alias should work after setup" {
            $script:gitconfigPath | Should -Exist
            $result = & git alias 2>&1
            $LASTEXITCODE | Should -Be 0
            $result | Should -Not -BeNullOrEmpty
        }

        It "git cleanup should be available" {
            $result = & git config --get alias.cleanup 2>&1
            $LASTEXITCODE | Should -Be 0
            $result | Should -Not -BeNullOrEmpty
        }

        It "git branches alias should exist" {
            $script:gitconfigPath | Should -Exist
            $result = & git config --get alias.branches
            $result | Should -Not -BeNullOrEmpty
        }

        It "git branches alias should have properly quoted format string" {
            $script:gitconfigPath | Should -Exist
            $result = & git config --get alias.branches
            # Verify the format string is quoted to prevent shell interpretation
            $result | Should -Match "--format='%\([^)]+\)'"
        }

        It "git branches alias should contain complete command with semicolons" {
            $script:gitconfigPath | Should -Exist
            $result = & git config --get alias.branches
            $result | Should -Match "while read ref; do"
            $result | Should -Match "2>/dev/null \|\| true; done"
        }
    }

    Context "Cleanup and Reset" {
        It "Should remove setup on cleanup" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Also skipped on non-Windows platforms as the scripts are Windows-specific
            # Run manually on command line: .\Cleanup-GitConfig.ps1 -Force
            & $script:pwshExe -NoProfile -ExecutionPolicy Bypass -File $script:cleanupScript -Force 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0

            # Verify symlinks are gone
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $gitconfigPath | Should -Not -Exist
        }

        # Runs only when the cleanup test above ran: otherwise there is nothing
        # to check, and a real task on a developer machine would fail it.
        It "Should remove scheduled task on cleanup" -Skip:(-not $setupRuns) {
            $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
            $task | Should -BeNullOrEmpty
        }
    }
}

Describe "GitConfig Helper Script" -Tag 'Integration' {
    It "gitconfig_helper.py should exist in repository" {
        $helperPath = Join-Path $script:repoRoot "gitconfig_helper.py"
        $helperPath | Should -Exist
    }

    It "gitconfig_helper.py should be valid Python" {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because "no Python interpreter found (py/python3/python)"
            return
        }
        $helperPath = Join-Path $script:repoRoot "gitconfig_helper.py"
        & $script:python -m py_compile $helperPath 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
