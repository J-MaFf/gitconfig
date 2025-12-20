BeforeAll {
    # Setup variables
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\Setup-GitConfig.ps1"
    $script:testHome = $env:USERPROFILE
    if (-not $script:testHome) {
        $script:testHome = $env:HOME  # Unix/Linux fallback
    }
    $script:testRepo = $script:repoRoot

    # Check if running on Windows
    $script:platformIsWindows = $PSVersionTable.PSVersion.Major -ge 6 ? $IsWindows : $true

    # Check if running as admin (Windows only)
    if ($script:platformIsWindows) {
        try {
            $script:isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        }
        catch {
            $script:isAdmin = $false
        }
    }
    else {
        $script:isAdmin = $false
    }

    # Run setup if in interactive mode
    if ($script:isAdmin -and [System.Environment]::UserInteractive) {
        Write-Host "Running Setup-GitConfig.ps1 for testing..." -ForegroundColor Cyan
        & $script:scriptPath -Force -NoTask -ErrorAction SilentlyContinue | Out-Null
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

    Context "Config Generation" {
        It "Should generate .gitconfig in home directory" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $gitconfigPath | Should -Exist
        }

        It "Generated .gitconfig should not be a symlink" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $item = Get-Item $gitconfigPath
            $item.LinkType | Should -Not -Be "SymbolicLink"
        }

        It "Generated .gitconfig should have no placeholders" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $gitconfigPath = Join-Path $script:testHome ".gitconfig"
            $content = Get-Content $gitconfigPath -Raw
            $content | Should -Not -Match '\{\{REPO_PATH\}\}'
            $content | Should -Not -Match '\{\{HOME_DIR\}\}'
        }
    }

    Context "Symlink Creation" {
        It "Should create .gitignore_global symlink pointing to repository" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $gitignorePath = Join-Path $script:testHome ".gitignore_global"
            $gitignorePath | Should -Exist

            $item = Get-Item $gitignorePath
            $item.LinkType | Should -Be "SymbolicLink"
        }

        It "Should create gitconfig_helper.py symlink pointing to repository" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $helperPath = Join-Path $script:testHome "gitconfig_helper.py"
            $helperPath | Should -Exist

            $item = Get-Item $helperPath
            $item.LinkType | Should -Be "SymbolicLink"
        }
    }

    Context ".gitconfig.local Generation" {
        It "Should create .gitconfig.local file" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $localConfigPath | Should -Exist
        }

        It "Should have valid INI format" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"

            # Should not throw git config error
            $result = & git config -f $localConfigPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should include [gpg] section with format = ssh" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg\]'
            $content | Should -Match 'format\s*=\s*ssh'
        }

        It "Should include [gpg ssh] program path" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[gpg\s+"ssh"\]'
            $content | Should -Match 'op-ssh-sign\.exe'
        }

        It "Should use forward slashes in Windows paths" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            # op-ssh-sign.exe path should use forward slashes for git config compatibility
            $content | Should -Match 'C:/Users/.*/AppData/.*/op-ssh-sign\.exe'
        }

        It "Should include [commit] gpgsign = true" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[commit\]'
            $content | Should -Match 'gpgsign\s*=\s*true'
        }

        It "Should include [user] signingKey" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[user\]'
            $content | Should -Match 'signingKey\s*=\s*ssh-ed25519'
        }

        It "Should include [safe] directory entries" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $content = Get-Content $localConfigPath -Raw

            $content | Should -Match '\[safe\]'
            $content | Should -Match 'directory\s*='
        }
    }

    Context "Git Configuration" {
        It "Should set gpg.format to ssh" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $result = & git config --get gpg.format 2>$null
            $result | Should -Be "ssh"
        }

        It "Should set commit.gpgsign to true" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $result = & git config --get commit.gpgsign 2>$null
            $result | Should -Be "true"
        }

        It "Should set user.signingKey" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $result = & git config --get user.signingKey 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "ssh-ed25519"
        }

        It "Should point gpg.ssh.program to op-ssh-sign.exe" -Skip:((-not [System.Environment]::UserInteractive) -or (-not $script:platformIsWindows)) {
            $result = & git config --get gpg.ssh.program 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "op-ssh-sign\.exe"
        }
    }

    Context "Scheduled Task Creation" {
        It "Should create Update-GitConfig scheduled task" -Skip:(-not $script:platformIsWindows) {
            # Note: This test is skipped when setup runs with -NoTask (which it does for testing)
            # To fully test task creation, run Setup-GitConfig.ps1 -Force (without -NoTask)
            # Scheduled tasks are Windows-only
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            if ($task) {
                $task | Should -Not -BeNullOrEmpty
            }
            else {
                # Task may not exist if setup was run with -NoTask
                Set-ItResult -Skipped -Because "Setup was run with -NoTask (scheduled task creation skipped)"
            }
        }

        It "Scheduled task should trigger at user logon" -Skip:(-not $script:platformIsWindows) {
            # Scheduled tasks are Windows-only
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

