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
# login task's log picks it up), emitting no control characters. Returns a
# single [bool], $true when pip exited 0, whatever the -Logger writes to the
# pipeline. Dependency-free by design: no modules, no Python changes.
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
        # Nothing but the final [bool] may reach this function's output: the
        # updater's Write-Log logger emits its line to the pipeline (Tee-Object),
        # and a captured log line made the result @('<line>', $false), which is
        # truthy, so a failed install was reported as [OK] (#256). Out-Host keeps
        # the line on screen without returning it; pip's own output is dropped,
        # as on the job path.
        & $Logger "$activity (this can take a minute)..." | Out-Host
        & $Python -m pip install --quiet @Packages *> $null
        $pipExit = $LASTEXITCODE
        return [bool]($pipExit -eq 0)
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
    return [bool]($exit -eq 0)
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

# ---------------------------------------------------------------------------
# Backups
#
# Every backup is timestamped (<file>.bak.yyyyMMdd-HHmmss) so a later backup
# never overwrites an earlier one. Only the newest $env:GITCONFIG_BACKUP_KEEP
# timestamped backups of each file are kept (default 5; 0 keeps them all), so on
# their own they would lose the user's original file after five regenerations
# (#253). The original is therefore also pinned: the first time a file is backed
# up, a copy is kept as <file>.pre-gitconfig, which pruning never matches and
# which is never overwritten afterwards. On an install that predates the pin,
# the oldest surviving timestamped backup is pinned instead (the original,
# unless it was already pruned). Older single-slot backups from earlier versions
# (Existing.<file>.bak, .gitconfig.bak) are never touched. Mirrors the bash
# helpers in scripts/shared/functions.sh.
# ---------------------------------------------------------------------------

# Return the item at Path without following a symlink (so a dangling link is
# still found), or $null if nothing is there.
function Get-LinkAwareItem {
    param([Parameter(Mandatory)][string]$Path)
    Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

# How many backups of each file to keep. Invalid values fall back to 5.
function Get-BackupKeep {
    $keep = 0
    if ($env:GITCONFIG_BACKUP_KEEP -and [int]::TryParse($env:GITCONFIG_BACKUP_KEEP, [ref]$keep) -and $keep -ge 0) {
        return $keep
    }
    return 5
}

# Return a not-yet-used timestamped backup path for Path. The timestamp goes last
# so names sort oldest-first; a same-second collision gets a zero-padded counter,
# which still sorts after the bare stamp.
function New-BackupPath {
    param([Parameter(Mandatory)][string]$Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = "$Path.bak.$stamp"
    # Go one past the highest name taken this second, never into a gap that
    # pruning left: a reused lower name sorts as the oldest and would be
    # pruned straight away (#268). The bare stamp counts as 0.
    $max = -1
    if (Get-LinkAwareItem -Path $base) { $max = 0 }
    $pattern = '^' + [regex]::Escape((Split-Path -Leaf $base)) + '-(\d{2,})$'
    foreach ($item in @(Get-ChildItem -LiteralPath (Split-Path -Parent $base) -Force -ErrorAction SilentlyContinue)) {
        if ($item.Name -cmatch $pattern) { $max = [Math]::Max($max, [int]$Matches[1]) }
    }
    if ($max -lt 0) { return $base }
    return '{0}-{1:D2}' -f $base, ($max + 1)
}

# Return Path's timestamped backups, oldest first. Only names New-BackupPath
# produces are listed (never <file>.pre-gitconfig).
function Get-TimestampedBackups {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    $name = Split-Path -Leaf $Path
    $pattern = '^' + [regex]::Escape($name) + '\.bak\.\d{8}-\d{6}(-\d{2,})?$'
    @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch $pattern } |
        Sort-Object -Property Name)
}

# Delete all but the newest -Keep timestamped backups of Path (default:
# Get-BackupKeep). 0 disables pruning. Only names New-BackupPath produces count,
# so the pinned <file>.pre-gitconfig is never deleted.
function Remove-OldBackups {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Keep = -1
    )
    if ($Keep -lt 0) { $Keep = Get-BackupKeep }
    if ($Keep -eq 0) { return }
    $backups = @(Get-TimestampedBackups -Path $Path)
    if ($backups.Count -le $Keep) { return }
    $backups | Select-Object -First ($backups.Count - $Keep) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Pin Path's original as <Path>.pre-gitconfig, unless that already exists. The
# source is the oldest timestamped backup if there is one (an install from
# before the pin), otherwise Path itself. Call it before taking a backup. A
# symlink is pinned as a symlink to the same target. Never throws: a pin that
# cannot be written only warns, and the timestamped backup still goes ahead.
# Returns the pinned path if it was created now, else $null.
function Save-OriginalBackup {
    param([Parameter(Mandatory)][string]$Path)
    $pinned = "$Path.pre-gitconfig"
    if (Get-LinkAwareItem -Path $pinned) { return $null }
    $oldest = @(Get-TimestampedBackups -Path $Path)
    $source = if ($oldest.Count -gt 0) { $oldest[0].FullName } else { $Path }
    $item = Get-LinkAwareItem -Path $source
    if (-not $item) { return $null }
    try {
        if ($item.LinkType -eq 'SymbolicLink') {
            $target = @($item.Target)[0]
            if (-not [IO.Path]::IsPathRooted($target)) {
                $target = Join-Path (Split-Path -Parent $item.FullName) $target
            }
            New-Item -ItemType SymbolicLink -Path $pinned -Target $target -ErrorAction Stop | Out-Null
        }
        else {
            Copy-Item -LiteralPath $source -Destination $pinned -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Could not keep the original $(Split-Path -Leaf $Path) as $(Split-Path -Leaf $pinned): $_"
        return $null
    }
    Write-Host "[INFO] Kept the original $(Split-Path -Leaf $Path) as $(Split-Path -Leaf $pinned) (never pruned)" -ForegroundColor Yellow
    return $pinned
}

# True if Path is a symlink whose target lies inside Directory (e.g. a link this
# tool created into the repo). Such a link holds no user data, so it is replaced
# or removed without a backup.
function Test-LinkIntoDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Directory
    )
    $item = Get-LinkAwareItem -Path $Path
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $target = @($item.Target)[0]
    if (-not $target) { return $false }
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $item.FullName) $target
    }
    $sep = [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($target)
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + $sep
    return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

# True if Path is a symlink that already resolves to Target.
function Test-LinkPointsTo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )
    $item = Get-LinkAwareItem -Path $Path
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $false }
    $linkTarget = @($item.Target)[0]
    if (-not $linkTarget) { return $false }
    if (-not [IO.Path]::IsPathRooted($linkTarget)) {
        $linkTarget = Join-Path (Split-Path -Parent $item.FullName) $linkTarget
    }
    return [string]::Equals([IO.Path]::GetFullPath($linkTarget), [IO.Path]::GetFullPath($Target), [StringComparison]::OrdinalIgnoreCase)
}

# Back up Path to a timestamped file in the same directory, then prune old
# backups. The first backup of Path also pins the original (see
# Save-OriginalBackup). -Move moves Path away (use before replacing or removing
# it); otherwise it is copied and stays in place (use before overwriting it). With
# -RepoRoot, a symlink into the repo is simply removed instead (-Move) or left
# alone (copy): it is ours and backing it up would push a real backup out of the
# retention window. Returns the backup path, or $null if nothing was backed up.
function Backup-UserFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Move,
        [string]$RepoRoot
    )
    $item = Get-LinkAwareItem -Path $Path
    if (-not $item) { return $null }

    if ($RepoRoot -and (Test-LinkIntoDirectory -Path $Path -Directory $RepoRoot)) {
        if ($Move) { Remove-Item -LiteralPath $Path -Force }
        return $null
    }

    $null = Save-OriginalBackup -Path $Path
    $backup = New-BackupPath -Path $Path
    if ($Move) {
        Move-Item -LiteralPath $Path -Destination $backup -Force
    }
    else {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    Remove-OldBackups -Path $Path
    return $backup
}

# Return the names of settings in ExistingPath that NewContent (the rendered
# template) doesn't have, e.g. ones `gh auth setup-git`, `git lfs install` or
# `git config --global` wrote. Regenerating ~/.gitconfig drops them, so callers
# warn before rewriting. Only key names are returned, never values.
function Get-DroppedGitConfigKeys {
    param(
        [Parameter(Mandatory)][string]$ExistingPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewContent
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $NewContent)
        $old = @(& git config --file $ExistingPath --list 2>$null)
        $new = @(& git config --file $tmp --list 2>$null)
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    # A key missing from the new content is dropped. For a multi-valued key
    # (safe.directory, credential helpers) a missing exact value is dropped too.
    # A single-valued key the template simply changes is not reported.
    $newSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $newCount = @{}
    $oldCount = @{}
    foreach ($line in $new) {
        [void]$newSet.Add($line)
        $k = ($line -split '=', 2)[0]
        $newCount[$k] = 1 + [int]$newCount[$k]
    }
    foreach ($line in $old) {
        $k = ($line -split '=', 2)[0]
        $oldCount[$k] = 1 + [int]$oldCount[$k]
    }
    $dropped = foreach ($line in $old) {
        $k = ($line -split '=', 2)[0]
        if (-not $newCount.ContainsKey($k)) { $k; continue }
        $multi = ($oldCount[$k] -gt 1) -or ($newCount[$k] -gt 1)
        if ($multi -and -not $newSet.Contains($line)) { $k }
    }
    return @($dropped | Sort-Object -Unique)
}

# --- UTF-8 text files (#230) ---------------------------------------------------
# Under Windows PowerShell 5.1 (the elevated relaunch and the login task),
# Get-Content reads a BOM-less UTF-8 file as ANSI, and Set-Content / Add-Content
# write ANSI, so a non-ASCII user name or path in a generated config came out
# mangled. These read and write UTF-8 in both editions: reading honours a BOM if
# there is one, writing never adds one (git and the Unix scripts expect plain
# UTF-8). A relative Path resolves against the current PowerShell location, as
# the cmdlets do, not the process's working directory.

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-Utf8File {
    param([Parameter(Mandatory)][string]$Path)
    [System.IO.File]::ReadAllText((Resolve-FullPath $Path), [System.Text.Encoding]::UTF8)
}

# Replace the file's contents with Text. An existing file is truncated rather
# than recreated, so its attributes (such as Hidden, which File.WriteAllText
# refuses to overwrite) are kept.
function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $fullPath = Resolve-FullPath $Path
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $mode = if ([System.IO.File]::Exists($fullPath)) { [System.IO.FileMode]::Truncate } else { [System.IO.FileMode]::CreateNew }
    $stream = [System.IO.File]::Open($fullPath, $mode, [System.IO.FileAccess]::Write)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}

# Append Text (add your own line ending) to the file, creating it if needed.
function Add-Utf8Text {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    [System.IO.File]::AppendAllText((Resolve-FullPath $Path), $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Read the text file at FullPath for an in-place edit that keeps every other
# byte as it was. UTF-16/32 (Windows PowerShell's '>' writes UTF-16 LE) need
# decoding to find the lines. Anything else is ASCII-compatible (UTF-8, ANSI),
# so it is read as Latin-1, which maps each byte to one char and back
# unchanged: ASCII markers still match and non-ASCII bytes survive as they
# were. Returns Bytes, BomLength, Encoding, Latin1 ($true for the byte-per-char
# mode) and Text; Write-MarkedText writes Text back the same way.
function Read-MarkedText {
    param([Parameter(Mandatory)][string]$FullPath)
    $bytes = [System.IO.File]::ReadAllBytes($FullPath)
    $bomLength = 0
    $latin1 = $true
    $encoding = [System.Text.Encoding]::GetEncoding(28591)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bomLength = 3
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $bomLength = 4
        $latin1 = $false
        $encoding = New-Object System.Text.UTF32Encoding($false, $false)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $bomLength = 2
        $latin1 = $false
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $bomLength = 2
        $latin1 = $false
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false)
    }
    [pscustomobject]@{
        Bytes     = $bytes
        BomLength = $bomLength
        Encoding  = $encoding
        Latin1    = $latin1
        Text      = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength)
    }
}

# Write Text to FullPath in the encoding Read-MarkedText found, with the
# original BOM (if any) in front.
function Write-MarkedText {
    param([Parameter(Mandatory)][string]$FullPath, [Parameter(Mandatory)]$File, [AllowEmptyString()][string]$Text)
    $body = $File.Encoding.GetBytes($Text)
    $out = New-Object byte[] ($File.BomLength + $body.Length)
    [System.Array]::Copy($File.Bytes, 0, $out, 0, $File.BomLength)
    [System.Array]::Copy($body, 0, $out, $File.BomLength, $body.Length)
    [System.IO.File]::WriteAllBytes($FullPath, $out)
}

# Remove the lines from BeginMarker through EndMarker (inclusive) from the text
# file at Path, keeping every other byte as it was: the encoding, any BOM, the
# line endings, and characters the ANSI code page can't hold (#255). Cleanup
# used Set-Content, which re-encodes the file; under Windows PowerShell 5.1
# (the elevated relaunch) it wrote ANSI, so the profile lost its BOM and Nerd
# Font glyphs or emoji became '?'. Returns 'Removed', 'NotFound' (no begin
# marker, or no file) or 'Unterminated' (a begin marker with no end marker after
# it). The file is written only for 'Removed'.
function Remove-MarkedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BeginMarker,
        [Parameter(Mandatory)][string]$EndMarker
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return 'NotFound' }
    $file = Read-MarkedText -FullPath $item.FullName

    # Split after each newline so every piece keeps its own line ending.
    $kept = New-Object System.Text.StringBuilder
    $inBlock = $false
    $found = $false
    foreach ($line in [regex]::Split($file.Text, '(?<=\n)')) {
        $content = $line.TrimEnd([char[]]"`r`n")
        if ($inBlock) {
            if ($content -eq $EndMarker) { $inBlock = $false; $found = $true }
            continue
        }
        if ($content -eq $BeginMarker) { $inBlock = $true; continue }
        [void]$kept.Append($line)
    }
    # No end marker: removing to the end of the file could take the user's own
    # lines with it, so leave the file alone.
    if ($inBlock) { return 'Unterminated' }
    if (-not $found) { return 'NotFound' }

    Write-MarkedText -FullPath $item.FullName -File $file -Text $kept.ToString()
    return 'Removed'
}

# Make the text file at Path contain BeginMarker, the Body lines and EndMarker
# exactly once (#230). An existing block is rewritten in place, so a moved repo
# no longer leaves a stale path behind; any later copies of the block are
# dropped. Otherwise the block is appended after a blank line. Like
# Remove-MarkedBlock it keeps the file's encoding, BOM and line endings; the
# block uses the file's line ending (CRLF unless the file only has LF). A new (or
# empty) file is written as UTF-8 with a BOM, which both Windows PowerShell 5.1 (it
# reads a BOM-less file as ANSI) and PowerShell 7 read as UTF-8; in an existing
# BOM-less file a non-ASCII Body is written as UTF-8. Returns 'Added',
# 'Updated', 'Unchanged' (nothing written) or 'Unterminated' (a begin marker
# with no end marker after it; the file is left alone).
function Set-MarkedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BeginMarker,
        [Parameter(Mandatory)][string]$EndMarker,
        [Parameter(Mandatory)][string[]]$Body
    )
    $lines = @($BeginMarker) + $Body + @($EndMarker)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer) { throw "'$Path' is a directory" }
    # A missing or empty (0-byte) file gets a fresh UTF-8 file with a BOM.
    if (-not $item -or $item.Length -eq 0) {
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $dir = Split-Path -Parent $fullPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $text = ($lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($fullPath, $text, (New-Object System.Text.UTF8Encoding($true)))
        return 'Added'
    }

    $file = Read-MarkedText -FullPath $item.FullName
    $text = $file.Text
    $newline = if ($text.Contains("`r`n") -or -not $text.Contains("`n")) { "`r`n" } else { "`n" }
    $block = $lines -join $newline
    if ($file.Latin1) {
        # One char per byte: store the block's UTF-8 bytes.
        $block = $file.Encoding.GetString([System.Text.Encoding]::UTF8.GetBytes($block))
    }

    $out = New-Object System.Text.StringBuilder
    $inBlock = $false
    $found = $false
    foreach ($line in [regex]::Split($text, '(?<=\n)')) {
        $content = $line.TrimEnd([char[]]"`r`n")
        if ($inBlock) {
            if ($content -eq $EndMarker) {
                $inBlock = $false
                if (-not $found) {
                    # Keep the end marker line's own ending (none at end of file).
                    [void]$out.Append($block).Append($line.Substring($content.Length))
                    $found = $true
                }
            }
            continue
        }
        if ($content -eq $BeginMarker) { $inBlock = $true; continue }
        [void]$out.Append($line)
    }
    if ($inBlock) { return 'Unterminated' }

    if ($found) {
        $newText = $out.ToString()
        if ($newText -ceq $text) { return 'Unchanged' }
        Write-MarkedText -FullPath $item.FullName -File $file -Text $newText
        return 'Updated'
    }

    $prefix = $text
    if ($prefix.Length -gt 0) {
        if (-not $prefix.EndsWith("`n")) { $prefix += $newline }
        $prefix += $newline
    }
    Write-MarkedText -FullPath $item.FullName -File $file -Text ($prefix + $block + $newline)
    return 'Added'
}

# --- Elevating as a different account (#240) ---------------------------------
# With over-the-shoulder UAC (a standard user types an administrator's
# password), the elevated relaunch of install.ps1 or Cleanup-GitConfig.ps1 runs
# as the administrator, so its USERPROFILE, Documents folder and user name are
# the administrator's, and everything would be set up for the wrong account.
# The non-elevated run passes its own values (Get-InvokingUserArguments) and the
# elevated run switches back to them (Use-InvokingUser).

# The current account as DOMAIN\user (or just user), the form Task Scheduler
# takes for a logon trigger and a task principal.
function Get-CurrentUserName {
    if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { "$env:USERNAME" }
}

# Arguments for Start-Process that tell the elevated relaunch who started it.
# Each value is quoted for the command line; a trailing backslash is trimmed so
# it can't escape the closing quote.
function Get-InvokingUserArguments {
    $profileDir = "$env:USERPROFILE".TrimEnd('\')
    $documents = "$([Environment]::GetFolderPath('MyDocuments'))".TrimEnd('\')
    $out = @('-InvokingUser', "`"$(Get-CurrentUserName)`"", '-InvokingUserProfile', "`"$profileDir`"")
    if ($documents) { $out += @('-InvokingDocuments', "`"$documents`"") }
    $out
}

# Called by the elevated run with the values Get-InvokingUserArguments passed.
# When it runs as a different account from the one that started it, it points
# USERPROFILE and HOME at the invoking user's profile (the child scripts, git
# and Python read them) and warns. Returns:
#   User      - DOMAIN\user to configure (the login task's user)
#   Documents - the invoking user's Documents folder as passed (the
#               PowerShell profiles go under it), or $null when none was passed
#               (use this process's own Documents folder)
#   Switched  - $true when the account differs
function Use-InvokingUser {
    param([string]$InvokingUser, [string]$InvokingUserProfile, [string]$InvokingDocuments)
    $current = Get-CurrentUserName
    # -eq on strings is case-insensitive, like Windows account names.
    if (-not $InvokingUser -or $InvokingUser -eq $current) {
        $documents = if ($InvokingDocuments) { $InvokingDocuments } else { $null }
        return [pscustomobject]@{ User = $current; Documents = $documents; Switched = $false }
    }

    Write-Host "[WARN] Elevated as $current, but started by $InvokingUser." -ForegroundColor Yellow
    if ($InvokingUserProfile) {
        $env:USERPROFILE = $InvokingUserProfile
        $env:HOME = $InvokingUserProfile
        Write-Host "       Configuring $InvokingUser ($InvokingUserProfile), not $current." -ForegroundColor Yellow
    }
    else {
        Write-Host "       $InvokingUser's profile folder is unknown; configuring $current's instead." -ForegroundColor Yellow
    }
    Write-Host "       Python packages go to the Python $current can run; the login task" -ForegroundColor Yellow
    Write-Host "       installs any that are missing for $InvokingUser at their next login." -ForegroundColor Yellow
    return [pscustomobject]@{ User = $InvokingUser; Documents = $InvokingDocuments; Switched = $true }
}

# The profile scripts that load in every host of Windows PowerShell 5.1 and of
# PowerShell 7 (each edition's $PROFILE.CurrentUserAllHosts), so the Ctrl-G
# widget works in both whichever edition runs the install (#230). Documents
# defaults to this account's Documents folder as Windows reports it, which
# follows a OneDrive redirect; after Use-InvokingUser switched accounts, pass
# its Documents. Falls back to $PROFILE.CurrentUserAllHosts only when there is
# no Documents folder at all.
function Get-ProfileScriptPath {
    param([string]$Documents)
    if (-not $Documents) { $Documents = [Environment]::GetFolderPath('MyDocuments') }
    if (-not $Documents) { return @($PROFILE.CurrentUserAllHosts) }
    foreach ($edition in 'WindowsPowerShell', 'PowerShell') {
        Join-Path (Join-Path $Documents $edition) 'profile.ps1'
    }
}
