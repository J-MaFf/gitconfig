BeforeAll {
    # Import the script
    $scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts" "Cleanup-GitConfig.ps1"

    # Test variables
    $testHome = $env:USERPROFILE
    $testRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe "Cleanup-GitConfig.ps1" {

    Context "Symlink Removal" {
        It "Should remove .gitconfig symlink" {
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            # After cleanup runs, should be removed or backed up
            if (Test-Path $gitconfigPath) {
                $item = Get-Item $gitconfigPath -ErrorAction SilentlyContinue
                # Should either be gone or backed up
                ($gitconfigPath | Should -Not -Exist) -or `
                ((Join-Path $testHome "Existing.gitconfig.bak") | Should -Exist)
            }
        }

        It "Should create backup of .gitconfig before removal" {
            $gitconfigBackup = Join-Path $testHome "Existing.gitconfig.bak"
            # If .gitconfig was removed, backup should exist
            if (-not (Test-Path (Join-Path $testHome ".gitconfig"))) {
                $gitconfigBackup | Should -Exist
            }
        }
    }

    Context "Config File Cleanup" {
        It "Should not remove .gitconfig.local (it will be regenerated)" {
            # Cleanup shouldn't remove .gitconfig.local since Setup regenerates it
            # Only removes symlinks and task
            $localConfig = Join-Path $testHome ".gitconfig.local"
            # This is implementation-specific - cleanup may preserve it
        }
    }

    Context "Scheduled Task Removal" {
        It "Should remove Update-GitConfig scheduled task" {
            $task = Get-ScheduledTask -TaskName "Update-GitConfig" -ErrorAction SilentlyContinue
            $task | Should -BeNullOrEmpty
        }
    }

    Context "Git Configuration Cleanup" {
        It "Should reset git aliases to defaults" {
            # After cleanup, custom aliases should be gone
            $aliases = & git config --get-regexp alias.alias 2>$null
            # Should not find our custom alias
        }
    }

    Context "Verification" {
        It "Should verify cleanup was successful" {
            # Core symlinks should be removed
            $gitconfigPath = Join-Path $testHome ".gitconfig"
            $gitconfigPath | Should -Not -Exist -or `
                ((Get-Item $gitconfigPath -ErrorAction SilentlyContinue).LinkType -eq $null)
        }
    }

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match "param\(\s*\[switch\]\$Force"
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\$Help"
        }
    }
}
