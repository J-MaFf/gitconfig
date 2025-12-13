BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $setupScript = Join-Path $repoRoot "scripts\Setup-GitConfig.ps1"
    $cleanupScript = Join-Path $repoRoot "scripts\Cleanup-GitConfig.ps1"
    $testHome = $env:USERPROFILE
}

Describe "GitConfig Integration" {

    Context "End-to-End Setup and Verification" {
        It "Should complete setup without errors" -Skip:(-not [System.Environment]::UserInteractive) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Run manually on command line: .\Setup-GitConfig.ps1 -Force
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $setupScript -Force 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "Should have all required symlinks after setup" -Skip:(-not [System.Environment]::UserInteractive) {
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $helperPath = Join-Path $testHome "gitconfig_helper.py"

            $gitconfigPath | Should -Exist
            $helperPath | Should -Exist
        }

        It "Should have valid .gitconfig.local file" -Skip:(-not [System.Environment]::UserInteractive) {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $localConfigPath | Should -Exist

            $content = Get-Content $localConfigPath -Raw
            $content | Should -Match '\[gpg\]'
            $content | Should -Match '\[commit\]'
            $content | Should -Match '\[user\]'
            $content | Should -Match '\[safe\]'
        }

        It ".gitconfig.local should have valid INI format" -Skip:(-not [System.Environment]::UserInteractive) {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"

            # Should not error when git reads it
            $result = & git config -f $localConfigPath --list 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "SSH Signing Configuration" {
        It "Should enable SSH signing in git config" -Skip:(-not [System.Environment]::UserInteractive) {
            $gpgFormat = & git config --get gpg.format 2>$null
            $commitGpgSign = & git config --get commit.gpgsign 2>$null

            $gpgFormat | Should -Be "ssh"
            $commitGpgSign | Should -Be "true"
        }

        It "Should configure correct op-ssh-sign.exe path" -Skip:(-not [System.Environment]::UserInteractive) {
            $program = & git config --get gpg.ssh.program 2>$null

            $program | Should -Not -BeNullOrEmpty
            $program | Should -Match "op-ssh-sign\.exe"
            $program | Should -Match "WindowsApps"
        }

        It "Should set SSH signing key" -Skip:(-not [System.Environment]::UserInteractive) {
            $signingKey = & git config --get user.signingKey 2>$null

            $signingKey | Should -Not -BeNullOrEmpty
            $signingKey | Should -Match "ssh-ed25519"
        }

        It "op-ssh-sign.exe should exist at configured path" {
            $program = & git config --get gpg.ssh.program 2>$null

            if ($program) {
                Test-Path $program | Should -Be $true
            }
        }
    }

    Context "Scheduled Task" {
        It "Should create Update-GitConfig scheduled task" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
        }
    }

    Context "Cleanup and Reset" {
        It "Should remove setup on cleanup" -Skip:(-not [System.Environment]::UserInteractive) {
            # This test is skipped in non-interactive environments (Pester extension)
            # Run manually on command line: .\Cleanup-GitConfig.ps1 -Force
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $cleanupScript -Force 2>&1
            $LASTEXITCODE | Should -Be 0

            # Verify symlinks are gone
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $gitconfigPath | Should -Not -Exist
        }

        It "Should remove scheduled task on cleanup" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            $task | Should -BeNullOrEmpty
        }
    }
}

Describe "GitConfig Helper Script" {
    It "gitconfig_helper.py should exist in repository" -Skip:(-not [System.Environment]::UserInteractive) {
        $helperPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "gitconfig_helper.py"
        $helperPath | Should -Exist
    }

    It "gitconfig_helper.py should be valid Python" -Skip:(-not [System.Environment]::UserInteractive) {
        $helperPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "gitconfig_helper.py"
        $result = & python -m py_compile $helperPath 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}

Describe "Git Aliases" {
    It "git alias should work after setup" {
        $result = & git alias 2>&1
        $result | Should -Not -BeNullOrEmpty
    }

    It "git cleanup should be available" {
        $result = & git config --get alias.cleanup
        $result | Should -Not -BeNullOrEmpty
    }

    It "git branches alias should exist" {
        $result = & git config --get alias.branches
        $result | Should -Not -BeNullOrEmpty
    }

    It "git branches alias should have properly quoted format string" {
        $result = & git config --get alias.branches
        # Verify the format string is quoted to prevent shell interpretation
        $result | Should -Match "--format='%\([^)]+\)'"
    }

    It "git branches alias should contain complete command with semicolons" {
        $result = & git config --get alias.branches
        $result | Should -Match "while read ref; do"
        $result | Should -Match "2>/dev/null; done"
    }
}
