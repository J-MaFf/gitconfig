# Initialize Git Configuration
# This script generates ~/.gitconfig from .gitconfig.template
# Usage: .\Initialize-GitConfig.ps1

param(
    [switch]$Force = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
Initialize Git Configuration

USAGE:
    .\Initialize-GitConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Overwrite existing .gitconfig without prompting
    -Help       Display this help message

DESCRIPTION:
    Generates ~/.gitconfig from .gitconfig.template with machine-specific values.
    This allows the git configuration to be portable across different machines
    while maintaining version control of the template.

EXAMPLE:
    # Interactive mode (prompts before overwriting)
    .\Initialize-GitConfig.ps1

    # Force mode (overwrites without prompting)
    .\Initialize-GitConfig.ps1 -Force

TEMPLATE PLACEHOLDERS:
    {{REPO_PATH}}  - Replaced with repository absolute path
    {{HOME_DIR}}   - Replaced with user home directory path
"@
    exit 0
}

# Get paths
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$homeDir = $env:USERPROFILE
if (-not $homeDir) {
    $homeDir = $env:HOME  # Unix/Linux fallback
}
$templatePath = Join-Path $repoRoot ".gitconfig.template"
$outputPath = Join-Path $homeDir ".gitconfig"

Write-Host "Git Configuration Generator" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor Green
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host "Template: $templatePath" -ForegroundColor Green
Write-Host "Output: $outputPath" -ForegroundColor Green
Write-Host ""

# Check if template exists
if (-not (Test-Path $templatePath)) {
    Write-Host "[ERROR] Template not found: $templatePath" -ForegroundColor Red
    exit 1
}

# Check if .gitconfig already exists
if ((Test-Path $outputPath) -and -not $Force) {
    Write-Host ".gitconfig already exists at: $outputPath" -ForegroundColor Yellow
    $response = Read-Host "Overwrite? (y/n)"
    if ($response -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

try {
    # Read template
    $templateContent = Get-Content $templatePath -Raw
    
    # Convert Windows paths to forward slashes for git config compatibility
    $repoPathForward = $repoRoot -replace '\\', '/'
    $homeDirForward = $homeDir -replace '\\', '/'
    
    # Replace placeholders
    $generatedContent = $templateContent
    $generatedContent = $generatedContent -replace '\{\{REPO_PATH\}\}', $repoPathForward
    $generatedContent = $generatedContent -replace '\{\{HOME_DIR\}\}', $homeDirForward
    
    # Backup existing file if it exists
    if (Test-Path $outputPath) {
        $backupPath = "$outputPath.bak"
        Copy-Item -Path $outputPath -Destination $backupPath -Force
        Write-Host "[INFO] Backed up existing .gitconfig to .gitconfig.bak" -ForegroundColor Yellow
    }
    
    # Write generated config
    Set-Content -Path $outputPath -Value $generatedContent -Force
    Write-Host "[OK] Generated .gitconfig" -ForegroundColor Green
    Write-Host ""
    
    # Verify git can read the config
    Write-Host "Verifying git configuration..." -ForegroundColor Cyan
    $gitConfigTest = & git config --file $outputPath --list 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git configuration verified!" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Git may have issues reading the configuration" -ForegroundColor Yellow
        Write-Host "  Run: git config --list to diagnose" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Configuration generated successfully!" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Generated values:" -ForegroundColor Cyan
    Write-Host "  Repository Path: $repoPathForward" -ForegroundColor Gray
    Write-Host "  Home Directory: $homeDirForward" -ForegroundColor Gray
    Write-Host ""
    Write-Host "To customize, either:" -ForegroundColor Cyan
    Write-Host "  1. Edit the template: $templatePath" -ForegroundColor Gray
    Write-Host "  2. Re-run this script to regenerate" -ForegroundColor Gray
    Write-Host "  OR" -ForegroundColor Cyan
    Write-Host "  3. Add overrides to ~/.gitconfig.local" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Host "[FAIL] Error generating .gitconfig" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
