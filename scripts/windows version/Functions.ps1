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
# alias and the not-installed placeholder are indistinguishable by size (both
# 0 bytes), and an argument-less run of the placeholder opens the Store install
# prompt - so we never probe them FIRST: enumerate ALL matches (Get-Command
# -All), set 0-byte WindowsApps stubs aside, and add the real launcher install
# paths as explicit fallbacks. If none of those resolve, fall back to probing
# the WindowsApps stubs LAST (#199): with a non-empty -c argument a placeholder
# just prints a message and exits 9009 (no UI), so this is safe and it's the
# only way to resolve a Store-only install with no launcher.
#
# The probe must pass a NON-EMPTY -c argument: Windows PowerShell 5.1 (which
# runs the login scheduled task) silently drops empty-string arguments to
# native commands, so `& $cand -c ''` became `py -c` (exit 2) and every
# working candidate was rejected (#197). pwsh 7 passes '' correctly, which is
# why the old probe looked fine when tested interactively.
function Resolve-Python {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $stubs = [System.Collections.Generic.List[string]]::new()

    foreach ($cmd in 'py', 'python3', 'python') {
        foreach ($g in @(Get-Command $cmd -All -ErrorAction SilentlyContinue)) {
            $src = $g.Source
            if (-not $src) { continue }
            # Set aside 0-byte WindowsApps app-execution-alias stubs rather than
            # skipping them outright - they're probed last, below, as the only
            # way to resolve a Store-only install (#199).
            if ($src -like '*\Microsoft\WindowsApps\*' -and (Test-Path $src) -and ((Get-Item $src).Length -eq 0)) {
                if (-not $stubs.Contains($src)) { $stubs.Add($src) }
                continue
            }
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

    # Real paths first, WindowsApps stubs last: a stub found alongside a real
    # interpreter shouldn't win the resolution just because it was probed first.
    foreach ($cand in (@($candidates) + @($stubs))) {
        try {
            # $null = : a candidate that writes to stdout (e.g. a .cmd wrapper
            # echoing commands) must not leak into the function's return value.
            # try/catch: a stub is probed here specifically because it might be
            # broken (that's the whole reason it was previously skipped
            # outright) - a launch failure must be treated as "this candidate
            # doesn't work", not crash Resolve-Python's best-effort caller chain.
            $null = & $cand -c 'pass' 2>$null
        }
        catch {
            continue
        }
        if ($LASTEXITCODE -eq 0) { return $cand }
    }
    return $null
}

# True when the host console can render an in-place spinner: stdout must not
# be redirected, the session must be interactive, and the host must expose a
# real RawUI console. CI runners, piped/redirected output, and the login
# scheduled task (non-interactive) all fail at least one check and get a plain
# one-line fallback instead - an animated spinner would just spew carriage
# returns into their logs (#210).
function Test-ConsoleSpinnerSupport {
    if ([System.Console]::IsOutputRedirected) { return $false }
    if (-not [System.Environment]::UserInteractive) { return $false }
    if (-not $Host.UI -or -not $Host.UI.RawUI) { return $false }
    try {
        # Hosts without a real console (e.g. some remoting/CI hosts) throw here.
        $null = $Host.UI.RawUI.WindowSize
    }
    catch { return $false }
    return $true
}

# Run `pip install --quiet <packages>` showing an animated | / - \ spinner
# while it blocks: a cold install of rich/textual can take many seconds with
# zero output, which made install.ps1 STEP 6 look hung (#210). pip runs in a
# background job so the foreground can animate; the job swallows pip's output
# just like the old inline `2>$null` calls did. Without a real console (see
# Test-ConsoleSpinnerSupport) - or if job startup fails - the install runs
# synchronously behind a single plain status line (routed via -Logger so the
# login task's log picks it up), emitting no control characters. Returns $true
# when pip exited 0. Dependency-free by design: no modules, no Python changes.
function Invoke-PipInstall {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string[]]$Packages,
        [scriptblock]$Logger = { param($m) Write-Host $m }
    )

    $activity = "Installing $($Packages -join ' ')"
    if ($activity.Length -gt 60) { $activity = $activity.Substring(0, 57) + '...' }

    $job = $null
    if (Test-ConsoleSpinnerSupport) {
        try {
            $job = Start-Job -ScriptBlock {
                param($exe, $pkgs)
                & $exe -m pip install --quiet @pkgs *> $null
                $LASTEXITCODE
            } -ArgumentList $Python, $Packages
        }
        catch {
            # Job infrastructure unavailable - fall through to the plain path.
            $job = $null
        }
    }

    if (-not $job) {
        & $Logger "$activity (this can take a minute)..."
        & $Python -m pip install --quiet @Packages 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    $frames = '|', '/', '-', '\'
    $i = 0
    try {
        while ($job.State -eq 'Running') {
            Write-Host -NoNewline ("`r  [{0}] {1}" -f $frames[$i % $frames.Count], $activity)
            $i++
            Start-Sleep -Milliseconds 150
        }
    }
    finally {
        # Blank the spinner line so the final [OK]/[WARN] message starts clean.
        Write-Host -NoNewline ("`r{0}`r" -f (' ' * ($activity.Length + 8)))
    }

    $null = Wait-Job $job
    # The job's only output is the $LASTEXITCODE it emitted after pip finished.
    $exit = Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return ($exit -eq 0)
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
            if (Invoke-PipInstall -Python $py -Packages ($needRequired + $needOptional) -Logger $Logger) { & $say "[OK] Installed Python deps: $($needRequired -join ' ') $($needOptional -join ' ')"; return }
        }
        if (Invoke-PipInstall -Python $py -Packages $needRequired -Logger $Logger) {
            if ($needOptional.Count -gt 0) { & $say "[OK] Installed required Python deps: $($needRequired -join ' ') (optional unavailable; 'git alias' uses the static table)" }
            else { & $say "[OK] Installed required Python deps: $($needRequired -join ' ')" }
        }
        else {
            & $say "[WARN] Could not install required Python deps ($($needRequired -join ' ')) - run: $py -m pip install $($needRequired -join ' ')"
        }
    }
    elseif ($needOptional.Count -gt 0) {
        if (Invoke-PipInstall -Python $py -Packages $needOptional -Logger $Logger) { & $say "[OK] Installed optional Python deps: $($needOptional -join ' ')" }
        else { & $say "[WARN] Optional Python deps unavailable ($($needOptional -join ' ')); 'git alias' uses the static table" }
    }
}
