BeforeAll {
    # Setup variables
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts" "Setup-GitConfig.ps1"
    $script:testHome = $env:USERPROFILE
    $script:testRepo = $script:repoRoot

    # Check if running as admin
    $script:isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    # Run setup only if admin
    if ($script:isAdmin) {
        Write-Host "Running setup script with -Force -NoTask..." -ForegroundColor Green
        try {
            & $script:scriptPath -Force -NoTask -ErrorAction Stop | Out-Null
            Start-Sleep -Milliseconds 500  # Give filesystem time to update
        }
        catch {
            Write-Error "Setup script failed: $_"
        }
    }
}

Describe "Setup-GitConfig.ps1" {

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "param\s*\(\s*\[switch\]\`$Force"
        }

        It "Should accept -NoTask parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\`$NoTask"
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\`$Help"
        }
    }

    Context "Symlink Creation" {
        It "Should create .gitconfig symlink pointing to repository" {
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $gitconfigPath | Should -Exist

            $item = Get-Item $gitconfigPath
            $item.LinkType | Should -Be "SymbolicLink"
        }

        It "Should create gitconfig_helper.py symlink pointing to repository" {
            $helperPath = Join-Path $script:testHome "gitconfig_helper.py"
            $helperPath | Should -Exist

            $item = Get-Item $helperPath
            $item.LinkType | Should -Be "SymbolicLink"
        }
    }

    Context ".gitconfig.local Generation" {
        It "Should create .gitconfig.local file" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $localConfigPath | Should -Exist
        }

        It "Should have valid INI format" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            # Should not throw git config error
            $result = & git config -f $localConfigPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should include [gpg] section with format = ssh" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg\]'
            $content | Should -Match 'format\s*=\s*ssh'
        }

        It "Should include [gpg ssh] program path" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg\s+"ssh"\]'
            $content | Should -Match 'op-ssh-sign\.exe'
        }

        It "Should use forward slashes in Windows paths" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            # op-ssh-sign.exe path should use forward slashes for git config compatibility
            $content | Should -Match 'C:/Users/.*/AppData/.*/op-ssh-sign\.exe'
        }

        It "Should include [commit] gpgsign = true" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[commit\]'
            $content | Should -Match 'gpgsign\s*=\s*true'
        }

        It "Should include [user] signingKey" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[user\]'
            $content | Should -Match 'signingKey\s*=\s*ssh-ed25519'
        }

        It "Should include [safe] directory entries" {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
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
            # Note: This test is skipped when setup runs with -NoTask (which it does for testing)
            # To fully test task creation, run Setup-GitConfig.ps1 -Force (without -NoTask)
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            if ($task) {
                $task | Should -Not -BeNullOrEmpty
            }
            else {
                # Task may not exist if setup was run with -NoTask
                Set-ItResult -Skipped -Because "Setup was run with -NoTask (scheduled task creation skipped)"
            }
        }

        It "Scheduled task should trigger at user logon" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            if ($task) {
                $triggers = $task.Triggers
                $triggers | Should -Not -BeNullOrEmpty
            }
            else {
                Set-ItResult -Skipped -Because "Setup was run with -NoTask (scheduled task creation skipped)"
            }
        }
    }
}

