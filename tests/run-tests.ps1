#!/usr/bin/env pwsh
<#
.SYNOPSIS
Run all Pester tests for GitConfig repository

.DESCRIPTION
Executes the complete Pester test suite including unit and integration tests.
Requires Pester module and administrator privileges for integration tests.

.PARAMETER Path
Path to test files or directory. Defaults to ./tests

.PARAMETER Tag
Run only tests with specified tags

.PARAMETER ExcludeTag
Exclude tests with specified tags

.PARAMETER PassThru
Return Pester results object

.EXAMPLE
.\run-tests.ps1
Run all tests with default configuration

.EXAMPLE
.\run-tests.ps1 -Tag Unit
Run only unit tests

.EXAMPLE
.\run-tests.ps1 -ExcludeTag Integration
Run all tests except integration tests
#>

param(
    [string]$Path = './tests',
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$PassThru
)

# Check if Pester is installed
try {
    Import-Module -Name Pester -MinimumVersion 5.0 -ErrorAction Stop
}
catch {
    Write-Error "Pester 5.0+ is required. Install with: Install-Module -Name Pester -Force"
    exit 1
}

# Check for admin privileges (Windows only)
$platformIsWindows = $PSVersionTable.PSVersion.Major -ge 6 ? $IsWindows : $true
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

# Build Pester configuration
$pesterParams = @{
    Path = $Path
    Passthru = $PassThru
    Show = 'All'
}

if ($Tag) {
    $pesterParams['Tag'] = $Tag
}

if ($ExcludeTag) {
    $pesterParams['ExcludeTag'] = $ExcludeTag
}

Write-Host "Running Pester Tests for GitConfig" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Run tests
$results = Invoke-Pester @pesterParams

# Exit with appropriate code
if ($results.FailedCount -gt 0) {
    exit 1
}
else {
    exit 0
}
