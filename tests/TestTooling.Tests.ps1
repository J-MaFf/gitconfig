# Tests for the test tooling itself: tests/run-tests.ps1 (the entry point CI runs)
# and config/pester.config.ps1. Kept ASCII-only so Windows PowerShell 5.1 parses it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:runTests = Join-Path $PSScriptRoot 'run-tests.ps1'
    $script:configFile = Join-Path (Join-Path $repoRoot 'config') 'pester.config.ps1'
    # Same host as this run: powershell.exe under 5.1, pwsh under 7.
    $script:hostExe = (Get-Process -Id $PID).Path

    function Invoke-RunTests {
        param([string]$TestFile)
        $null = & $script:hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $script:runTests -Path $TestFile 2>&1
        return $LASTEXITCODE
    }
}

Describe "tests/run-tests.ps1 exit code" -Tag 'Unit' {

    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $sandbox | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "exits 0 when every test passes" {
        $file = Join-Path $sandbox 'Pass.Tests.ps1'
        Set-Content -Path $file -Value "Describe 'd' { It 'passes' { 1 | Should -Be 1 } }"
        Invoke-RunTests -TestFile $file | Should -Be 0
    }

    It "exits 1 when a test fails (called without -PassThru, as CI does)" {
        $file = Join-Path $sandbox 'Fail.Tests.ps1'
        Set-Content -Path $file -Value "Describe 'd' { It 'fails' { 1 | Should -Be 2 } }"
        Invoke-RunTests -TestFile $file | Should -Be 1
    }

    It "exits 1 when a test file's setup throws (no individual test fails)" {
        $file = Join-Path $sandbox 'Broken.Tests.ps1'
        Set-Content -Path $file -Value "Describe 'd' { BeforeAll { throw 'boom' }; It 'never runs' { 1 | Should -Be 1 } }"
        Invoke-RunTests -TestFile $file | Should -Be 1
    }
}

Describe "config/pester.config.ps1" -Tag 'Unit' {

    BeforeAll {
        $script:cfg = & $configFile
    }

    It "points Run.Path at paths that exist" {
        foreach ($p in $cfg.Run.Path) {
            Test-Path -LiteralPath $p | Should -BeTrue -Because "Run.Path entry '$p' must exist"
        }
    }

    It "points CodeCoverage.Path at paths that exist" {
        foreach ($p in $cfg.CodeCoverage.Path) {
            Test-Path -LiteralPath $p | Should -BeTrue -Because "CodeCoverage.Path entry '$p' must exist"
        }
    }

    It "covers install.ps1 and Cleanup-GitConfig.ps1" {
        foreach ($name in 'install.ps1', 'Cleanup-GitConfig.ps1') {
            $covered = @($cfg.CodeCoverage.Path | Where-Object {
                    Test-Path -LiteralPath (Join-Path $_ $name)
                })
            $covered.Count | Should -BeGreaterThan 0 -Because "$name should be in code coverage"
        }
    }

    It "excludes machine-mutating Integration tests" {
        $cfg.Filter.ExcludeTag | Should -Contain 'Integration'
    }

    It "resolves to existing absolute paths from another working directory" {
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            $other = & $configFile
            foreach ($p in @($other.Run.Path) + @($other.CodeCoverage.Path)) {
                [System.IO.Path]::IsPathRooted($p) | Should -BeTrue -Because "'$p' must not depend on the working directory"
                Test-Path -LiteralPath $p | Should -BeTrue -Because "'$p' must exist from any working directory"
            }
        }
        finally {
            Pop-Location
        }
    }

    It "is accepted by New-PesterConfiguration" {
        { New-PesterConfiguration -Hashtable $cfg } | Should -Not -Throw
    }
}
