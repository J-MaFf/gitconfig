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
    -Force      Overwrite an existing .gitconfig that differs from the
                template without prompting
    -Help       Display this help message

DESCRIPTION:
    Generates ~/.gitconfig from .gitconfig.template with machine-specific values.
    This allows the git configuration to be portable across different machines
    while maintaining version control of the template.

EXAMPLE:
    # Interactive mode (prompts before overwriting a .gitconfig that differs;
    # an up-to-date one is left alone without asking)
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
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)
$homeDir = $env:USERPROFILE
if (-not $homeDir) {
    $homeDir = $env:HOME  # Unix/Linux fallback
}
$templatePath = Join-Path $repoRoot ".gitconfig.template"
$outputPath = Join-Path $homeDir ".gitconfig"

# Shared helpers: timestamped backups and the dropped-settings check.
. (Join-Path $scriptDir "Functions.ps1")

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

$localConfigPath = Join-Path $homeDir ".gitconfig.local"

# Snapshot what ~/.gitconfig holds now, before the symlink handling below can
# remove it: the settings the template no longer carries are moved from this
# copy into ~/.gitconfig.local before the rewrite (#231).
$previousPath = $null
if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    try {
        $previousPath = [IO.Path]::GetTempFileName()
        Copy-Item -LiteralPath $outputPath -Destination $previousPath -Force -ErrorAction Stop
    }
    catch {
        $previousPath = $null
    }
}

# A ~/.gitconfig that is a symlink into this repo is a leftover from an old
# install that linked it instead of generating it. Writing through it would
# clobber a file inside the repo, and backing it up would only save a link, so
# drop the link and write a real file in its place.
if (Test-LinkIntoDirectory -Path $outputPath -Directory $repoRoot) {
    Remove-Item -LiteralPath $outputPath -Force
    Write-Host "[INFO] Replaced the old ~/.gitconfig symlink into the repo with a generated file" -ForegroundColor Yellow
}

try {
    # Read template. Read-Utf8File / Write-Utf8File (Functions.ps1) read and
    # write UTF-8 in both editions; Get-Content / Set-Content use ANSI under
    # Windows PowerShell 5.1 and mangled a non-ASCII home path (#230).
    $templateContent = Read-Utf8File $templatePath
    
    # Convert Windows paths to forward slashes for git config compatibility
    $repoPathForward = $repoRoot -replace '\\', '/'
    $homeDirForward = $homeDir -replace '\\', '/'
    
    # Replace placeholders. String.Replace copies the path as is; -replace
    # would expand a '$1', '$&' or '$_' in it as a regex substitution (#230).
    $generatedContent = $templateContent.Replace('{{REPO_PATH}}', $repoPathForward).Replace('{{HOME_DIR}}', $homeDirForward)
    if (-not $generatedContent.EndsWith("`n")) { $generatedContent += [Environment]::NewLine }

    # Idempotent: skip backup/write when the installed config already matches the
    # rendered template (newline-insensitive compare). Makes the auto-update
    # convergent and avoids needless rewrites/.bak churn on every login. Checked
    # before the overwrite prompt below, so re-running install on an up-to-date
    # machine doesn't ask to overwrite a file it would leave alone (#256).
    if (Test-Path $outputPath) {
        $normExisting = ((Read-Utf8File $outputPath) -replace "`r`n", "`n").TrimEnd("`n")
        $normGenerated = ($generatedContent -replace "`r`n", "`n").TrimEnd("`n")
        if ($normExisting -eq $normGenerated) {
            Write-Host "[OK] .gitconfig already up to date (matches template); no changes made" -ForegroundColor Green
            exit 0
        }
    }

    # The existing .gitconfig differs from the template: ask before replacing it.
    if ((Test-Path $outputPath) -and -not $Force) {
        Write-Host ".gitconfig already exists at: $outputPath" -ForegroundColor Yellow
        $response = Read-Host "Overwrite? (y/n)"
        if ($response -ne "y") {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    # Settings the old template carried (signing key, gpgsign, editor) must
    # survive the rewrite, or a machine whose ~/.gitconfig.local lacks them
    # would silently stop signing after the next scheduled update. If they
    # can't be moved, leave ~/.gitconfig alone so the next run tries again.
    if ($previousPath) {
        if (-not (Move-TemplateSettingsToLocal -PreviousPath $previousPath -NewContent $generatedContent -LocalPath $localConfigPath)) {
            Write-Host "[ERROR] Could not move settings into ~/.gitconfig.local; ~/.gitconfig left unchanged" -ForegroundColor Red
            exit 1
        }
    }

    # Warn about settings the rewrite drops, then back up the existing file to a
    # timestamped copy (older backups are kept, see Backup-UserFile).
    if (Test-Path $outputPath) {
        $dropped = @(Get-DroppedGitConfigKeys -ExistingPath $outputPath -NewContent $generatedContent -LocalPath $localConfigPath)
        if ($dropped.Count -gt 0) {
            Write-Host "[WARN] ~/.gitconfig has settings the template doesn't; regenerating drops them:" -ForegroundColor Yellow
            foreach ($key in $dropped) { Write-Host "         $key" -ForegroundColor Yellow }
            Write-Host "       They are kept in the backup below. To keep a setting, put it in" -ForegroundColor Yellow
            Write-Host "       ~/.gitconfig.local (git config --file ~/.gitconfig.local <key> <value>)." -ForegroundColor Yellow
        }
        $backupPath = Backup-UserFile -Path $outputPath
        if ($backupPath) {
            Write-Host "[INFO] Backed up existing .gitconfig to $(Split-Path -Leaf $backupPath)" -ForegroundColor Yellow
        }
    }
    
    # Write generated config
    Write-Utf8File -Path $outputPath -Text $generatedContent
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
finally {
    if ($previousPath) { Remove-Item -LiteralPath $previousPath -Force -ErrorAction SilentlyContinue }
}
