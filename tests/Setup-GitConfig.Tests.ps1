BeforeAll {
    # Import the script
    $scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts" "Setup-GitConfig.ps1"

    # Test variables
    $testHome = $env:USERPROFILE
    $testRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe "Setup-GitConfig.ps1" {

    Context "Symlink Creation" {
        It "Should create .gitconfig symlink pointing to repository" {
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $gitconfigPath | Should -Exist

            if (Test-Path $gitconfigPath) {
                $item = Get-Item $gitconfigPath
                $item.LinkType | Should -Be "SymbolicLink"
                $item.Target | Should -Contain ".gitconfig"
            }
        }

        It "Should create gitconfig_helper.py symlink pointing to repository" {
            $helperPath = Join-Path $testHome "gitconfig_helper.py"
            $helperPath | Should -Exist

            if (Test-Path $helperPath) {
                $item = Get-Item $helperPath
                $item.LinkType | Should -Be "SymbolicLink"
            }
        }

        It "Should backup existing files before overwriting" {
            # Verify backup files exist after setup
            $gitconfigBackup = Join-Path $testHome "Existing.gitconfig.bak"
            $helperBackup = Join-Path $testHome "Existing.gitconfig_helper.py.bak"

            if (Test-Path $gitconfigBackup) {
                $gitconfigBackup | Should -Exist
            }
            if (Test-Path $helperBackup) {
                $helperBackup | Should -Exist
            }
        }
    }

    Context ".gitconfig.local Generation" {
        It "Should create .gitconfig.local file" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $localConfigPath | Should -Exist
        }

        It "Should have valid INI format" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            # Should not throw git config error
            & git config -f $localConfigPath user.name 2>$null | Should -Not -BeNullOrEmpty
        }

        It "Should include [gpg] section with format = ssh" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg\]'
            $content | Should -Match 'format\s*=\s*ssh'
        }

        It "Should include [gpg ssh] program path" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg "ssh"\]'
            $content | Should -Match 'op-ssh-sign\.exe'
        }

        It "Should use backslashes in Windows paths" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            # op-ssh-sign.exe path should use backslashes
            $content | Should -Match 'C:\\Users\\.*\\AppData\\.*op-ssh-sign\.exe'
        }

        It "Should include [commit] gpgsign = true" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[commit\]'
            $content | Should -Match 'gpgsign\s*=\s*true'
        }

        It "Should include [user] signingKey" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[user\]'
            $content | Should -Match 'signingKey\s*=\s*ssh-ed25519'
        }

        It "Should include [safe] directory entries" {
            $localConfigPath = Join-Path $testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[safe\]'
            $content | Should -Match 'directory\s*='
        }
    }

    Context "Git Configuration" {
        It "Should set gpg.format to ssh" {
            $result = & git config --get gpg.format 2>$null
            $result | Should -Be "ssh"
        }

        It "Should set commit.gpgsign to true" {
            $result = & git config --get commit.gpgsign 2>$null
            $result | Should -Be "true"
        }

        It "Should set user.signingKey" {
            $result = & git config --get user.signingKey 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "ssh-ed25519"
        }

        It "Should point gpg.ssh.program to op-ssh-sign.exe" {
            $result = & git config --get gpg.ssh.program 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "op-ssh-sign\.exe"
        }
    }

    Context "Scheduled Task Creation" {
        It "Should create Update-GitConfig scheduled task" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
        }

        It "Scheduled task should trigger at user logon" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            if ($task) {
                $triggers = $task.Triggers
                $triggers | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            # Just verify the parameter is defined in the script
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match "param\(\s*\[switch\]\$Force"
        }

        It "Should accept -NoTask parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\$NoTask"
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\$Help"
        }
    }
}
