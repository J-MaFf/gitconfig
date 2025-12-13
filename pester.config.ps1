# Pester Configuration for GitConfig Tests

$PesterConfig = @{
    Run          = @{
        Path = @(
            './tests/Setup-GitConfig.Tests.ps1',
            './tests/Cleanup-GitConfig.Tests.ps1',
            './tests/Integration.Tests.ps1'
        )
    }
    Output       = @{
        Verbosity = 'Detailed'
    }
    CodeCoverage = @{
        Enabled = $true
        Path    = @(
            './scripts/Setup-GitConfig.ps1',
            './scripts/Cleanup-GitConfig.ps1'
        )
    }
}

return $PesterConfig
