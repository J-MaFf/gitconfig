<#
  Shared PowerShell helpers for the Windows gitconfig scripts. Dot-source it:

    . (Join-Path $PSScriptRoot 'Functions.ps1')
    Install-PythonDeps -RepoRoot $repoRoot

  Single source of truth for installing the helper's Python dependencies, so
  install.ps1 and Update-GitConfig.ps1 don't each duplicate the pip logic.
#>

# Resolve a usable Python: prefer the 'py' launcher, then python3, then python
# (avoids the Microsoft Store stub when a real interpreter exists). Returns the
# command name, or $null if none works.
function Resolve-Python {
    foreach ($cmd in 'py', 'python3', 'python') {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            & $cmd -c '' 2>$null
            if ($LASTEXITCODE -eq 0) { return $cmd }
        }
    }
    return $null
}

# Install the Python dependencies declared in pyproject.toml (read via
# scripts/shared/deps.py): the required deps (rich) plus the optional 'tui' group
# (textual). Idempotent — only installs what is not already importable. A failed
# *optional* install is a warning (the helper falls back to a static table).
# Best-effort; emits status via -Logger (defaults to Write-Host).
# Usage: Install-PythonDeps -RepoRoot <path> [-Logger { param($m) ... }]
function Install-PythonDeps {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [scriptblock]$Logger = { param($m) Write-Host $m }
    )
    $say = { param($m) & $Logger $m }

    $py = Resolve-Python
    if (-not $py) { & $say '[WARN] No Python interpreter found; skipping rich/textual (install Python 3, then re-run)'; return }

    $depsPy = Join-Path $RepoRoot 'scripts\shared\deps.py'
    if (-not (Test-Path $depsPy)) { & $say "[WARN] $depsPy not found; skipping Python dependency install"; return }

    & $py -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) { & $say "[WARN] pip unavailable for $py; install rich (and optionally textual) manually"; return }

    $required = @(& $py $depsPy required | Where-Object { $_ -ne '' })
    $optional = @(& $py $depsPy optional | Where-Object { $_ -ne '' })

    # Import name = spec minus any version operator: "rich>=13" -> "rich".
    $needRequired = @($required | Where-Object { $n = ($_ -split '[<>=!~ ]')[0]; & $py -c "import $n" 2>$null; $LASTEXITCODE -ne 0 })
    $needOptional = @($optional | Where-Object { $n = ($_ -split '[<>=!~ ]')[0]; & $py -c "import $n" 2>$null; $LASTEXITCODE -ne 0 })

    if ($needRequired.Count -eq 0 -and $needOptional.Count -eq 0) {
        & $say '[OK] Python dependencies already present (rich + textual)'
        return
    }

    if ($needRequired.Count -gt 0) {
        # Try required + optional together; if that fails, make sure the required
        # land even when an optional dep is unavailable.
        if ($needOptional.Count -gt 0) {
            & $py -m pip install --quiet $needRequired $needOptional 2>$null
            if ($LASTEXITCODE -eq 0) { & $say "[OK] Installed Python deps: $($needRequired -join ' ') $($needOptional -join ' ')"; return }
        }
        & $py -m pip install --quiet $needRequired 2>$null
        if ($LASTEXITCODE -eq 0) {
            if ($needOptional.Count -gt 0) { & $say "[OK] Installed required Python deps: $($needRequired -join ' ') (optional unavailable; 'git alias' uses the static table)" }
            else { & $say "[OK] Installed required Python deps: $($needRequired -join ' ')" }
        }
        else {
            & $say "[WARN] Could not install required Python deps ($($needRequired -join ' ')) - run: $py -m pip install $($needRequired -join ' ')"
        }
    }
    elseif ($needOptional.Count -gt 0) {
        & $py -m pip install --quiet $needOptional 2>$null
        if ($LASTEXITCODE -eq 0) { & $say "[OK] Installed optional Python deps: $($needOptional -join ' ')" }
        else { & $say "[WARN] Optional Python deps unavailable ($($needOptional -join ' ')); 'git alias' uses the static table" }
    }
}
