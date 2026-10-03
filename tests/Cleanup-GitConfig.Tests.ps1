BeforeAll {
    # Import the script
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot "scripts\windows version\Cleanup-GitConfig.ps1"

    # Test variables
    $testHome = $env:USERPROFILE
    $testRepo = $repoRoot
}

Describe "Cleanup-GitConfig.ps1" {

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$Force'
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$Help'
        }

        It "Should accept -KeepLocal parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$KeepLocal'
        }
    }

    Context "Help text" {
        BeforeAll {
            # -Help prints via Write-Host (information stream 6) and exits before
            # the elevation check, so it is safe to run on any platform.
            $script:helpText = & $scriptPath -Help 6>&1 | Out-String
        }

        It "Should name the scheduled task it actually removes" {
            $taskName = [regex]::Match((Get-Content $scriptPath -Raw), '\$taskName\s*=\s*"([^"]+)"').Groups[1].Value
            $taskName | Should -Not -BeNullOrEmpty
            $script:helpText | Should -Match ([regex]::Escape("`"$taskName`""))
        }

        It "Should not list a signing-config step the script does not perform" {
            # The script never touches user.signingkey / gpg.*; the help used to
            # claim a 'Clears git SSH signing config' step.
            $script:helpText | Should -Not -Match '(?i)signing'
            Get-Content $scriptPath -Raw | Should -Not -Match '(?i)--unset[^\r\n]*(signingkey|gpg\.)'
        }
    }

    Context "Preserve machine-specific config" {
        It "Should skip removing .gitconfig.local when -KeepLocal is set" {
            $scriptContent = Get-Content $scriptPath -Raw
            # Guard branch present: -KeepLocal short-circuits the removal step.
            $scriptContent | Should -Match 'if \(\$KeepLocal\)'
            $scriptContent | Should -Match 'Preserving \.gitconfig\.local'
        }
    }

    Context "Script Functionality" {
        It "Should be executable PowerShell script" {
            $scriptPath | Should -Exist
        }

        It "Should contain cleanup logic" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Backup-UserFile'
            $scriptContent | Should -Match 'ScheduledTask'
        }

        It "Should move files to timestamped backups, skipping links into the repo" {
            # Behaviour of Backup-UserFile is covered in Backups.Tests.ps1.
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Backup-UserFile -Path \$Path -Move -RepoRoot \$repoRoot'
            $scriptContent | Should -Not -Match 'Existing\.'
        }
    }

    Context "Verification" {
        It "Should have self-verification after cleanup" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Cleanup SUCCESSFUL'
        }
    }
}
