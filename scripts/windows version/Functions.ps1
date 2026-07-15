<#
  Shared PowerShell helpers for the Windows gitconfig scripts. Dot-source it:

    . (Join-Path $PSScriptRoot 'Functions.ps1')
    Install-PythonDeps -RepoRoot $repoRoot

  Single source of truth for installing the helper's Python dependencies, so
  install.ps1 and Update-GitConfig.ps1 don't each duplicate the pip logic.
#>

# Resolve a usable Python: prefer the 'py' launcher, then python3, then python
# (avoids the Microsoft Store stub when a real interpreter exists). Returns a
# command name or full path that works, or $null if none does.
#
# Why this is more than a simple Get-Command: the Python Install Manager
# (PyManager) and the Store register their entry points as 0-byte "app execution
# alias" reparse points under %LOCALAPPDATA%\Microsoft\WindowsApps. A working
# alias and the not-installed placeholder are indistinguishable (both 0 bytes),
# and an argument-less run of the placeholder opens the Store install prompt,
# so we don't probe them: enumerate ALL matches (Get-Command -All), skip 0-byte
# WindowsApps stubs, and add the real launcher install paths as explicit
# fallbacks. Known gap: a Store-only install has no launcher fallback and is
# never resolved - see #199.
#
# The probe must pass a NON-EMPTY -c argument: Windows PowerShell 5.1 (which
# runs the login scheduled task) silently drops empty-string arguments to
# native commands, so `& $cand -c ''` became `py -c` (exit 2) and every
# working candidate was rejected (#197). pwsh 7 passes '' correctly, which is
# why the old probe looked fine when tested interactively.
function Resolve-Python {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($cmd in 'py', 'python3', 'python') {
        foreach ($g in @(Get-Command $cmd -All -ErrorAction SilentlyContinue)) {
            $src = $g.Source
            if (-not $src) { continue }
            # Skip 0-byte WindowsApps app-execution-alias stubs (working and
            # placeholder aliases are indistinguishable at 0 bytes; #199).
            if ($src -like '*\Microsoft\WindowsApps\*' -and (Test-Path $src) -and ((Get-Item $src).Length -eq 0)) { continue }
            if (-not $candidates.Contains($src)) { $candidates.Add($src) }
        }
    }

    # Explicit fallbacks: the real launcher / PyManager install locations, in
    # case PATH in the task context doesn't reach them.
    if ($env:LOCALAPPDATA) {
        foreach ($fb in @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Python\py.exe')
            )) {
            if ((Test-Path $fb) -and (-not $candidates.Contains($fb))) { $candidates.Add($fb) }
        }
    }

    foreach ($cand in $candidates) {
        # $null = : a candidate that writes to stdout (e.g. a .cmd wrapper
        # echoing commands) must not leak into the function's return value.
        $null = & $cand -c 'pass' 2>$null
        if ($LASTEXITCODE -eq 0) { return $cand }
    }
    return $null
}

# Install the Python dependencies declared in pyproject.toml (read via
# scripts/shared/deps.py): the required deps (rich) plus the optional 'tui' group
# (textual). Idempotent - only installs what is not already importable. A failed
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
