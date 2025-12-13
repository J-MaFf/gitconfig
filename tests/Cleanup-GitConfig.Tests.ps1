BeforeAll {
    # Import the script
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot "scripts\Cleanup-GitConfig.ps1"

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
    }

    Context "Script Functionality" {
        It "Should be executable PowerShell script" {
            $scriptPath | Should -Exist
        }

        It "Should contain cleanup logic" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Remove-Item'
            $scriptContent | Should -Match 'ScheduledTask'
        }

        It "Should have backup mechanism" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Existing\.'
            $scriptContent | Should -Match '\.bak'
        }
    }

    Context "Verification" {
        It "Should have self-verification after cleanup" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Cleanup SUCCESSFUL'
        }
    }
}
