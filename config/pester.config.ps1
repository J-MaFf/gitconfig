# Pester Configuration for GitConfig Tests
#
# Returns a hashtable for New-PesterConfiguration, e.g. for a coverage run:
#   $cfg = New-PesterConfiguration -Hashtable (& ./config/pester.config.ps1)
#   Invoke-Pester -Configuration $cfg
#
# Paths are built from this file's location, so the config works from any working
# directory. Integration tests are excluded, as in tests/run-tests.ps1: they change
# the real machine (scheduled task, symlinks, ~/.gitconfig).

$repoRoot = Split-Path -Parent $PSScriptRoot

$PesterConfig = @{
    Run          = @{
        Path = @(Join-Path $repoRoot 'tests')
    }
    Filter       = @{
        ExcludeTag = @('Integration')
    }
    Output       = @{
        Verbosity = 'Detailed'
    }
    CodeCoverage = @{
        Enabled = $true
        # The whole Windows scripts folder, so a new script is covered without
        # editing this list.
        Path    = @(Join-Path (Join-Path $repoRoot 'scripts') 'windows version')
    }
}

return $PesterConfig
