BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $setupScript = Join-Path $repoRoot "scripts\Setup-GitConfig.ps1"
    $cleanupScript = Join-Path $repoRoot "scripts\Cleanup-GitConfig.ps1"
    $testHome = $env:USERPROFILE
    if (-not $testHome) {
        $testHome = $env:HOME  # Unix/Linux fallback
    }

    # Detect platform
    $platformIsWindows = $PSVersionTable.PSVersion.Major -ge 6 ? $IsWindows : $true

    # Choose PowerShell executable based on platform
    $pwshExe = if ($platformIsWindows) { "powershell" } else { "pwsh" }
}

Describe "GitConfig Integration" {

    Context "End-to-End Setup and Verification" {
        It "Should complete setup without errors" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Also skipped on non-Windows platforms as the scripts are Windows-specific
            # Run manually on command line: .\Setup-GitConfig.ps1 -Force
            $result = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $setupScript -Force -NoPrompt 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "Should have all required symlinks after setup" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $helperPath = Join-Path $testHome "gitconfig_helper.py"

            $gitconfigPath | Should -Exist
            $helperPath | Should -Exist
        }

        It "Should have valid .gitconfig.local file" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $localConfigPath | Should -Exist

            $content = Get-Content $localConfigPath -Raw
            $content | Should -Match '\[gpg\]'
            $content | Should -Match '\[commit\]'
            $content | Should -Match '\[user\]'
            $content | Should -Match '\[safe\]'
        }

        It ".gitconfig.local should have valid INI format" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"

            # Should not error when git reads it
            $result = & git config -f $localConfigPath --list 2>&1
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
        It "Should create Update-GitConfig scheduled task" -Skip:(-not $platformIsWindows) {
            # Scheduled tasks are Windows-only
            # Skip this if setup was run with -NoTask flag
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            if ($task) {
                $task | Should -Not -BeNullOrEmpty
            }
            else {
                Set-ItResult -Skipped -Because "Setup was run with -NoTask (scheduled task creation skipped)"
            }
        }
    }

    Context "Cleanup and Reset" {
        It "Should remove setup on cleanup" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $platformIsWindows)) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Also skipped on non-Windows platforms as the scripts are Windows-specific
            # Run manually on command line: .\Cleanup-GitConfig.ps1 -Force
            $result = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $cleanupScript -Force 2>&1
            $LASTEXITCODE | Should -Be 0

            # Verify symlinks are gone
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $gitconfigPath | Should -Not -Exist
        }

        It "Should remove scheduled task on cleanup" -Skip:(-not $platformIsWindows) {
            # Scheduled tasks are Windows-only
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            $task | Should -BeNullOrEmpty
        }
    }
}

Describe "GitConfig Helper Script" {
    It "gitconfig_helper.py should exist in repository" {
        $helperPath = Join-Path $repoRoot "gitconfig_helper.py"
        $helperPath | Should -Exist
    }

    It "gitconfig_helper.py should be valid Python" {
        $helperPath = Join-Path $repoRoot "gitconfig_helper.py"
        $result = & python -m py_compile $helperPath 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}

Describe "Git Aliases" {
    It "git alias should work after setup" {
        # Check if .gitconfig symlink exists (setup completed)
        $gitconfigExists = Test-Path (Join-Path $testHome ".gitconfig")
        if ($gitconfigExists) {
            $result = & git alias 2>&1
            $result | Should -Not -BeNullOrEmpty
        }
        else {
            Set-ItResult -Skipped -Because "Setup has not been run (no .gitconfig symlink found)"
        }
    }

    It "git cleanup should be available" {
        $result = & git config --get alias.cleanup 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result | Should -Not -BeNullOrEmpty
        }
        else {
            Set-ItResult -Skipped -Because "Setup has not been run (cleanup alias not configured)"
        }
    }

    It "git branches alias should exist" {
        $gitconfigExists = Test-Path (Join-Path $testHome ".gitconfig")
        if ($gitconfigExists) {
            $result = & git config --get alias.branches
            $result | Should -Not -BeNullOrEmpty
        }
        else {
            Set-ItResult -Skipped -Because "Setup has not been run (no .gitconfig symlink found)"
        }
    }

    It "git branches alias should have properly quoted format string" {
        $gitconfigExists = Test-Path (Join-Path $testHome ".gitconfig")
        if ($gitconfigExists) {
            $result = & git config --get alias.branches
            # Verify the format string is quoted to prevent shell interpretation
            $result | Should -Match "--format='%\([^)]+\)'"
        }
        else {
            Set-ItResult -Skipped -Because "Setup has not been run (no .gitconfig symlink found)"
        }
    }

    It "git branches alias should contain complete command with semicolons" {
        $gitconfigExists = Test-Path (Join-Path $testHome ".gitconfig")
        if ($gitconfigExists) {
            $result = & git config --get alias.branches
            $result | Should -Match "while read ref; do"
            $result | Should -Match "2>/dev/null; done"
        }
        else {
            Set-ItResult -Skipped -Because "Setup has not been run (no .gitconfig symlink found)"
        }
    }
}
