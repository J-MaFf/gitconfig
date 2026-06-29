<#
.SYNOPSIS
Run all Pester tests for GitConfig repository

.DESCRIPTION
Executes the Pester test suite. Integration tests (Tag 'Integration') mutate real
machine state - they run install.ps1 / Cleanup-GitConfig.ps1, which create/remove
the login scheduled task, symlinks, and the real ~/.gitconfig. They must run on a
real machine or VM and are EXCLUDED BY DEFAULT here. Opt in with -IncludeIntegration.

.PARAMETER Path
Path to test files or directory. Defaults to ./tests

.PARAMETER Tag
Run only tests with specified tags

.PARAMETER ExcludeTag
Exclude tests with specified tags. 'Integration' is always added unless
-IncludeIntegration is passed.

.PARAMETER IncludeIntegration
Also run integration tests. WARNING: these mutate the real machine (scheduled task,
symlinks, ~/.gitconfig) - only use on a throwaway machine or VM.

.PARAMETER PassThru
Return Pester results object

.EXAMPLE
.\run-tests.ps1
Run the unit suite (integration excluded) - safe; does not touch real config.

.EXAMPLE
.\run-tests.ps1 -Tag Unit
Run only unit tests

.EXAMPLE
.\run-tests.ps1 -IncludeIntegration
Run everything, including machine-mutating integration tests (VM only).
#>

param(
    [string]$Path = './tests',
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$IncludeIntegration,
    [switch]$PassThru
)

# Integration tests touch real machine state and must never run in a routine unit
# pass. Exclude them by default; opt in explicitly with -IncludeIntegration.
if (-not $IncludeIntegration) {
    $ExcludeTag = @($ExcludeTag) + 'Integration' | Where-Object { $_ } | Select-Object -Unique
}

# Check if Pester is installed
try {
    Import-Module -Name Pester -MinimumVersion 5.0 -ErrorAction Stop
}
catch {
    Write-Error "Pester 5.0+ is required. Install with: Install-Module -Name Pester -Force"
    exit 1
}

# Check for admin privileges (Windows only)
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $platformIsWindows = $IsWindows
}
else {
    $platformIsWindows = $true
}
if ($platformIsWindows) {
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Warning "Some tests require administrator privileges. Consider running as admin."
        }
    }
    catch {
        Write-Warning "Unable to determine administrator status."
    }
}
else {
    Write-Host "Running on non-Windows platform. Windows-specific tests will be skipped." -ForegroundColor Yellow
}

# Build Pester configuration using Pester 5 Configuration object
$pesterConfig = @{
    Run          = @{
        Path     = $Path
        PassThru = $PassThru
    }
    Output       = @{
        Verbosity = 'Detailed'
    }
    CodeCoverage = @{
        Enabled = $false
    }
}

# Add tag filters if specified. Tag include/exclude lives under the Filter section
# in Pester 5 - setting them under Run is silently ignored (which previously let
# Integration-tagged tests run even with -ExcludeTag Integration).
$pesterConfig.Filter = @{}
if ($Tag) {
    $pesterConfig.Filter['Tag'] = $Tag
}

if ($ExcludeTag) {
    $pesterConfig.Filter['ExcludeTag'] = $ExcludeTag
}

Write-Host "Running Pester Tests for GitConfig" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Run tests using Pester 5 configuration
$config = New-PesterConfiguration -Hashtable $pesterConfig
$results = Invoke-Pester -Configuration $config

# Exit with appropriate code
if ($results.FailedCount -gt 0) {
    exit 1
}
else {
    exit 0
}
