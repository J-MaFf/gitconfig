# Initialize Machine-Specific Git Configuration
# This script creates ~/.gitconfig.local with machine-specific paths and safe directories.
# Nothing machine-specific is hardcoded: this repo is public and runs everywhere (#235).
# Usage: .\Initialize-LocalConfig.ps1

param(
    [switch]$Force = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host @"
Initialize Machine-Specific Git Configuration

USAGE:
    .\Initialize-LocalConfig.ps1 [OPTIONS]

OPTIONS:
    -Force      Regenerate (overwrite) an existing .gitconfig.local from the
                template, keeping the old file as .gitconfig.local.bak.<timestamp>.
                Without -Force, an existing file is preserved.
    -Help       Display this help message

DESCRIPTION:
    Creates ~/.gitconfig.local with machine-specific safe directories, paths,
    commit signing (user.signingkey and commit.gpgsign, when a key is
    configured) and the editor (core.editor: code --wait when VS Code is
    installed and this isn't an SSH session; an existing value is kept). This
    file is included last by the main .gitconfig, so its values win, and it
    should NOT be version controlled.

    Create-if-missing: because this file holds user-owned machine state (hand-tuned
    safe.directory entries, etc.), an existing one is preserved by default; pass
    -Force to regenerate it from the template. The allowed_signers file is always
    ensured (idempotently), even when the config itself is preserved.

EXAMPLE:
    # Create if missing; preserve an existing file
    .\Initialize-LocalConfig.ps1

    # Regenerate from template, overwriting the existing file
    .\Initialize-LocalConfig.ps1 -Force

SAFE DIRECTORIES:
    The generated file trusts this clone of the repo, wherever it lives. List
    any other paths git should trust on this machine (network shares, other
    accounts' repos) in ~/.config/gitconfig/safe-directories, one per line
    (# starts a comment line); a UNC path (\\server\share\repo) is written
    in git's %(prefix)///server/share/repo form. -Force keeps the entries the
    previous file had.
"@
    exit 0
}

function Update-AllowedSigners {
    # Upserts the current signing identity into ~/.ssh/allowed_signers so git can
    # verify SSH commit signatures locally. Reads the signing key and email from
    # the already-generated ~/.gitconfig (git config). Idempotent: re-running does
    # not duplicate the line, and existing entries for other identities are kept.
    param([Parameter(Mandatory)][string]$AllowedSignersPath)

    $signingKey = (& git config --get user.signingkey 2>$null)
    $signerEmail = (& git config --get user.email 2>$null)

    if ([string]::IsNullOrWhiteSpace($signingKey) -or [string]::IsNullOrWhiteSpace($signerEmail)) {
        Write-Host "[WARN] No user.signingkey/user.email configured; skipped allowed_signers" -ForegroundColor Yellow
        return
    }

    # Resolve the public key: either the literal key (1Password) or a *.pub file.
    $pubKey = $null
    if ($signingKey -match '^(ssh-|sk-ssh-|ecdsa-)') {
        $pubKey = $signingKey.Trim()
    }
    else {
        $candidate = if ($signingKey -match '\.pub$') { $signingKey } else { "$signingKey.pub" }
        $candidate = Resolve-GitPathValue $candidate
        if (Test-Path -LiteralPath $candidate) {
            $pubKey = (Get-Content $candidate -Raw).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($pubKey)) {
        Write-Host "[WARN] Could not resolve signing public key; skipped allowed_signers" -ForegroundColor Yellow
        return
    }

    # Normalize to "<keytype> <base64>" - drop any trailing comment so the line is
    # valid allowed_signers syntax.
    $parts = $pubKey -split '\s+'
    if ($parts.Count -ge 2) {
        $pubKey = "$($parts[0]) $($parts[1])"
    }

    $sshDir = Split-Path -Parent $AllowedSignersPath
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $line = "$signerEmail namespaces=`"git`" $pubKey"
    $existing = @()
    if (Test-Path $AllowedSignersPath) {
        # UTF-8 in both editions (Get-Content reads ANSI under 5.1, #230).
        $existing = @((Read-Utf8File $AllowedSignersPath) -split '\r?\n')
    }
    if ($existing -contains $line) {
        Write-Host "[OK] allowed_signers already up to date" -ForegroundColor Green
    }
    else {
        # Appending goes straight after the last byte, so if the file
        # doesn't end in a newline the new entry would be glued onto the last
        # one and neither identity would verify (#255).
        if (Test-Path -LiteralPath $AllowedSignersPath) {
            $bytes = [System.IO.File]::ReadAllBytes((Get-Item -LiteralPath $AllowedSignersPath -Force).FullName)
            if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) {
                $line = [Environment]::NewLine + $line
            }
        }
        Add-Utf8Text -Path $AllowedSignersPath -Text ($line + [Environment]::NewLine)
        Write-Host "[OK] Updated $AllowedSignersPath" -ForegroundColor Green
    }
}

$homeDir = $env:USERPROFILE
$localConfigPath = Join-Path $homeDir ".gitconfig.local"
# The clone these scripts run from, wherever it was cloned (#235).
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Optional per-machine list of extra safe.directory entries (#235).
$safeDirsFile = [System.IO.Path]::Combine($homeDir, '.config', 'gitconfig', 'safe-directories')

# Shared helpers: timestamped backups (Backup-UserFile).
. (Join-Path $PSScriptRoot "Functions.ps1")

Write-Host "Git Local Configuration Setup" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Home Directory: $homeDir" -ForegroundColor Green
Write-Host "Local Config Path: $localConfigPath" -ForegroundColor Green
Write-Host ""

# Create-if-missing: .gitconfig.local holds user-owned machine state (safe.directory
# entries, etc.), so never clobber an existing one. Regenerate deliberately with -Force.
$localConfigExists = Test-Path $localConfigPath
$preserved = $localConfigExists -and -not $Force

# Expand a leading ~/ in a git path value the way git does (to the home dir).
function Resolve-GitPathValue {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '^~[/\\]') { return (Join-Path $homeDir $Value.Substring(2)) }
    return $Value
}

# Signing settings for the generated file (#231): .gitconfig.template no longer
# sets user.signingkey or commit.gpgsign, so this file carries them. The key is
# the one git already uses (an existing .gitconfig.local's, or an older
# ~/.gitconfig's), so regenerating keeps the machine's key.
#   - A key file path (the standard: an on-disk key, signed by ssh-keygen with
#     no agent): no gpg.ssh.program, and gpgsign only if the file exists.
#   - A literal public key (1Password agent signing): op-ssh-sign signs with
#     it when it's installed (#235: probed at both of 1Password's install
#     locations); otherwise gpgsign only if the SSH agent holds the key.
#   - No key: signing is left off rather than turned on with nothing to sign
#     with, which would make every commit fail.
# gpg.ssh.program is written only when op-ssh-sign.exe exists (#235).
function Get-LocalSigningSection {
    $homeFwd = $homeDir -replace '\\', '/'
    $key = (& git config --get user.signingkey 2>$null)
    if ($LASTEXITCODE -ne 0) { $key = $null }
    $opSshSign = Get-OpSshSignPath -HomeDir $homeDir
    $lines = [System.Collections.Generic.List[string]]::new()
    $isLiteral = $key -and ($key -match '^(key::|ssh-|sk-ssh-|ecdsa-|sk-ecdsa-)')
    $enable = $false
    if ($key) {
        $lines.Add('[user]')
        $lines.Add("`tsigningkey = $key")
        if ($isLiteral) {
            if ($opSshSign) {
                $enable = $true
            }
            elseif (Test-KeyInSshAgent $key) {
                Write-Host "[INFO] 1Password's op-ssh-sign.exe wasn't found; the SSH agent holds the signing key, so ssh-keygen signs with it." -ForegroundColor Yellow
                $enable = $true
            }
            else {
                Write-Host "[WARN] The signing key is a public key, but 1Password's op-ssh-sign.exe isn't installed and the SSH agent" -ForegroundColor Yellow
                Write-Host "       doesn't hold the key, so commit signing is left off. Install 1Password (or load the key)" -ForegroundColor Yellow
                Write-Host "       and re-run with -Force." -ForegroundColor Yellow
            }
        }
        elseif (Test-Path -LiteralPath (Resolve-GitPathValue $key) -PathType Leaf) {
            $enable = $true
        }
        else {
            Write-Host "[WARN] The signing key file $key doesn't exist, so commit signing is left off." -ForegroundColor Yellow
            Write-Host "       Once it does: git config --file ~/.gitconfig.local commit.gpgsign true" -ForegroundColor Yellow
        }
        $lines.Add('')
    }
    else {
        Write-Host "[WARN] No user.signingkey is configured, so commit signing is left off." -ForegroundColor Yellow
        Write-Host "       To sign commits: git config --file ~/.gitconfig.local user.signingkey <key file>" -ForegroundColor Yellow
        Write-Host "       then:            git config --file ~/.gitconfig.local commit.gpgsign true" -ForegroundColor Yellow
    }
    $lines.Add('[gpg]')
    $lines.Add("`tformat = ssh")
    $lines.Add('')
    $lines.Add('[gpg "ssh"]')
    if ((-not $key -or $isLiteral) -and $opSshSign) {
        $lines.Add("`t# 1Password's SSH signing program, found on this machine")
        $lines.Add("`tprogram = $(ConvertTo-GitConfigValue $opSshSign)")
    }
    $lines.Add("`t# Lets git verify SSH commit signatures locally (git log --show-signature, verify-commit)")
    $lines.Add("`tallowedSignersFile = $homeFwd/.ssh/allowed_signers")
    $lines.Add('')
    $lines.Add('[commit]')
    if ($enable) {
        $lines.Add("`tgpgsign = true")
    }
    else {
        $lines.Add("`t# Off until a signing key is set up (see above).")
        $lines.Add("`t# gpgsign = true")
    }
    return ($lines -join "`n")
}

# Whether the SSH agent lists Key, a literal public key ("ssh-ed25519 AAAA...",
# optionally key::-prefixed), comparing type and key data and ignoring any
# comment. False when ssh-add isn't available or the agent can't be reached.
function Test-KeyInSshAgent {
    param([Parameter(Mandatory)][string]$Key)
    if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) { return $false }
    $want = (($Key -replace '^key::', '').Trim() -split '\s+' | Select-Object -First 2) -join ' '
    $listed = & ssh-add -L 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($entry in @($listed)) {
        if (((("$entry").Trim() -split '\s+' | Select-Object -First 2) -join ' ') -eq $want) { return $true }
    }
    return $false
}

# The [safe] section (#235): this clone of the repo, wherever it lives; the
# machine's own trusted paths from ~/.config/gitconfig/safe-directories; and,
# when regenerating, the entries the previous file had, so -Force doesn't drop
# trusted paths set up by hand or by an older version of this script.
function Get-LocalSafeSection {
    $lines = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $lines.Add('[safe]')
    $lines.Add("`t# This clone of the gitconfig repo. To trust more paths on this machine,")
    $lines.Add("`t# list them in ~/.config/gitconfig/safe-directories (one per line, # starts")
    $lines.Add("`t# a comment) and re-run with -Force, or add directory = <path> lines here.")
    $repoEntry = ConvertTo-GitSafeDirectory $repoRoot
    [void]$seen.Add($repoEntry)
    $lines.Add("`tdirectory = $(ConvertTo-GitConfigValue $repoEntry)")

    $extras = @(Read-SafeDirectoryList $safeDirsFile)
    if ($extras.Count -gt 0) {
        Write-Host "[INFO] Adding the safe directories listed in $safeDirsFile" -ForegroundColor Yellow
    }
    foreach ($entry in $extras) {
        $value = ConvertTo-GitSafeDirectory $entry
        if ($seen.Add($value)) { $lines.Add("`tdirectory = $(ConvertTo-GitConfigValue $value)") }
    }

    if (Test-Path -LiteralPath $localConfigPath) {
        $previous = @(& git config --file $localConfigPath --get-all safe.directory 2>$null)
        $kept = @($previous | Where-Object { $_ -and $seen.Add($_) })
        if ($kept.Count -gt 0) {
            $lines.Add("`t# Kept from the previous .gitconfig.local")
            foreach ($value in $kept) { $lines.Add("`tdirectory = $(ConvertTo-GitConfigValue $value)") }
            Write-Host "[INFO] Keeping $($kept.Count) safe director$(if ($kept.Count -eq 1) { 'y' } else { 'ies' }) from the previous .gitconfig.local" -ForegroundColor Yellow
        }
    }
    return ($lines -join "`n")
}

# The editor for the generated file (#231): an existing .gitconfig.local's
# core.editor is kept; otherwise VS Code when it's installed and this isn't an
# SSH session (where a GUI editor can't open). Left unset otherwise, so git
# falls back to GIT_EDITOR, VISUAL, EDITOR, then its default.
function Get-LocalEditorSection {
    if (Test-Path -LiteralPath $localConfigPath) {
        $kept = (& git config --file $localConfigPath --get core.editor 2>$null)
        if ($LASTEXITCODE -eq 0 -and $kept) { return "`teditor = $kept" }
    }
    # GITCONFIG_CODE_BIN overrides the PATH lookup (tests); set but empty
    # means VS Code isn't installed.
    if (Test-Path Env:GITCONFIG_CODE_BIN) {
        $code = $env:GITCONFIG_CODE_BIN
    }
    else {
        $code = (Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    $why = $null
    if (-not $code) { $why = "VS Code (code) isn't on PATH" }
    elseif ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) { $why = "this is an SSH session" }
    if (-not $why) { return "`teditor = code --wait" }
    return "`t# No editor set: $why. git uses GIT_EDITOR, VISUAL or EDITOR, then its default.`n`t# editor = code --wait"
}

try {
    if ($preserved) {
        Write-Host "[SKIP] .gitconfig.local already exists; preserving machine-specific config" -ForegroundColor Yellow
        Write-Host "       (regenerate from template with: Initialize-LocalConfig.ps1 -Force)" -ForegroundColor DarkGray
    }
    else {
        $signingSection = Get-LocalSigningSection
        $editorLine = Get-LocalEditorSection
        $safeSection = Get-LocalSafeSection
        $configContent = @"
# Machine-Specific Git Configuration
# This file is automatically included by .gitconfig and should NOT be committed

$signingSection

[core]
	# Use global gitignore file
	excludesfile = $($homeDir -replace '\\', '/')/.gitignore_global
	# Long path support: some tools nest repos deeper than Windows MAX_PATH
	# (e.g. Dolt's git-remote-cache behind beads' 'bd dolt push'), and stock
	# Git for Windows then fails with "Filename too long". Lives here rather
	# than in .gitconfig.template because it is Windows-specific and this file
	# is never clobbered by template regeneration (see issue #186).
	longpaths = true
$editorLine

[credential]
	# HTTPS auth for unattended pulls of private repos (e.g. the claude-skills
	# scheduled-task sync). Git Credential Manager stores the token in the
	# per-user Windows Credential Manager, so the scheduled task never prompts.
	helper = manager

$safeSection
"@

        # -Force regenerate: keep the user's current file as a timestamped backup
        # first (older backups are kept, see Backup-UserFile).
        if ($localConfigExists) {
            $backupPath = Backup-UserFile -Path $localConfigPath
            if ($backupPath) {
                Write-Host "[INFO] Backed up existing .gitconfig.local to $(Split-Path -Leaf $backupPath)" -ForegroundColor Yellow
            }
        }

        # Create or overwrite the local config file
        # UTF-8, not 5.1's ANSI, so a non-ASCII home path survives (#230).
        Write-Utf8File -Path $localConfigPath -Text ($configContent + [Environment]::NewLine)
        if ($localConfigExists) {
            Write-Host "[OK] Regenerated .gitconfig.local (-Force)" -ForegroundColor Green
        }
        else {
            Write-Host "[OK] Created .gitconfig.local" -ForegroundColor Green
        }
    }
    Write-Host ""

    # Build ~/.ssh/allowed_signers so git can verify SSH commit signatures locally.
    # Without this file, `git log --show-signature` and `git verify-commit` report
    # "No signature" even though commits are signed (and GitHub shows Verified).
    $allowedSignersPath = Join-Path $homeDir ".ssh\allowed_signers"
    Update-AllowedSigners -AllowedSignersPath $allowedSignersPath

    # Describe the generated layout only when we actually wrote it; on the preserve
    # path the user's file may differ, so this summary would be misleading.
    if (-not $preserved) {
        Write-Host ""
        Write-Host "Local configuration includes:" -ForegroundColor Cyan
        Write-Host "  - Commit signing (signing key and gpgsign, when a key is configured)" -ForegroundColor Gray
        Write-Host "  - Editor (core.editor) when VS Code is available" -ForegroundColor Gray
        Write-Host "  - Allowed signers file for local signature verification" -ForegroundColor Gray
        Write-Host "  - Long path support (core.longpaths) for deeply nested repos" -ForegroundColor Gray
        Write-Host "  - Safe directories: this repo, plus any listed in ~/.config/gitconfig/safe-directories" -ForegroundColor Gray
        Write-Host ""
        Write-Host "To trust more directories on this machine:" -ForegroundColor Cyan
        Write-Host "  1. List them in $safeDirsFile (one path per line)" -ForegroundColor Gray
        Write-Host "  2. Re-run with -Force (entries already in the file are kept)" -ForegroundColor Gray
        Write-Host "  Or add directory = <path> lines to the [safe] section of $localConfigPath" -ForegroundColor Gray
        Write-Host ""
    }

    # Verify git can read the config. Validate the generated file directly with
    # --file (scope- and CWD-independent) rather than --local, which reads the
    # repo's .git/config and errors (exit 128) when the current directory isn't a
    # git repo. install.ps1 runs from the home directory, so --local produced a
    # spurious [WARN]. Mirrors Initialize-GitConfig.ps1 and shared/functions.sh.
    Write-Host "Verifying git configuration..." -ForegroundColor Cyan
    & git config --file $localConfigPath --list 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Git configuration verified!" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Git may have issues reading the configuration" -ForegroundColor Yellow
        Write-Host "  Run: git config --list to diagnose" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "[FAIL] Error creating .gitconfig.local" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
