<#
.SYNOPSIS
Move the Scripts root out of Documents and re-point everything that uses it.

.DESCRIPTION
Moves the folder that holds every clone (the Scripts root, by default
$HOME\Documents\Scripts) to $HOME\Scripts with one same-volume rename, then
repairs what depends on the old path (#304). Google Drive for desktop backs up
Documents, .git folders included, and a sync conflict leaves invalid refs such
as "refs/heads/main (1)" that break every fetch; Drive can't exclude a
subfolder, so the repos have to live outside Documents.

After the move it repairs: linked git worktrees; this repo's generated files
(~/.gitconfig, the ~/.gitignore_global and ~/gitconfig_helper.py links, the
"GitConfig Pull at Login" task, the Ctrl-G profile block); symlinks and
junctions in the home folder; paths in a fixed set of config files; scheduled
tasks; user environment variables; .lnk shortcuts; and Claude Code's
per-project folders. No link is left at the old path: on a machine where Drive
backs up Documents, one would bring the repos back into the backup.

The full plan is printed, and confirmed, before anything changes. Every file
it rewrites is first copied to ~/.scripts-move-<timestamp>/backup/, and the
run ends with a report in that folder. Run it again after a partial run: it
skips the move and finishes the repairs. Runbook: docs/MOVE-SCRIPTS-ROOT.md.

.PARAMETER From
The Scripts root to move. Default: $HOME\Documents\Scripts.

.PARAMETER To
Where the Scripts root goes. Default: $HOME\Scripts.

.PARAMETER DryRun
Print the plan and exit 0 without changing anything.

.PARAMETER Yes
Answer yes to every confirmation (needed when there is no one to ask).

.PARAMETER AllowSyncedTarget
Allow a -To inside a synced folder (Documents, Desktop, Pictures, OneDrive,
Google Drive, Dropbox). Only for a rollback.

.PARAMETER Help
Display the usage text.

.EXAMPLE
& "$HOME\Documents\Scripts\gitconfig\scripts\windows version\Move-ScriptsRoot.ps1" -DryRun

.EXAMPLE
& "$HOME\Documents\Scripts\gitconfig\scripts\windows version\Move-ScriptsRoot.ps1"
#>
# CmdletBinding makes a mistyped option an error. Without it PowerShell would
# drop "-DryRn" into $args and run the move for real.
[CmdletBinding()]
param(
    [string]$From = "$env:USERPROFILE\Documents\Scripts",
    [string]$To = "$env:USERPROFILE\Scripts",
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$AllowSyncedTarget,
    [switch]$Help
)

$usage = @"
Move the Scripts root out of Documents

USAGE:
    .\Move-ScriptsRoot.ps1 [-From <path>] [-To <path>] [-DryRun] [-Yes] [-AllowSyncedTarget]

OPTIONS:
    -From <path>         The Scripts root to move (default: `$HOME\Documents\Scripts)
    -To <path>           Where it goes (default: `$HOME\Scripts)
    -DryRun              Print the plan and exit 0 without changing anything
    -Yes                 Answer yes to every confirmation
    -AllowSyncedTarget   Allow a -To inside a synced folder (Documents, Desktop,
                         Pictures, OneDrive, Google Drive, Dropbox); for a rollback
    -Help, -?            Display this help message

DESCRIPTION:
    Renames From to To (one same-volume rename, never a copy), then repairs
    what used the old path: linked git worktrees, ~/.gitconfig and the other
    files this repo generates, home-folder symlinks and junctions, paths in
    shell/PowerShell profiles and Claude/VS Code config files, scheduled tasks,
    user environment variables, .lnk shortcuts and Claude Code project folders.
    No link is left at the old path. The plan is printed and confirmed first;
    files are backed up to ~/.scripts-move-<timestamp>/backup/ before they are
    changed, and the report is written to ~/.scripts-move-<timestamp>/report.txt.
    Run it again after a partial run: it skips the move and resumes the repairs.
    Runbook: docs/MOVE-SCRIPTS-ROOT.md.

EXIT STATUS:
    0  moved and repaired, or nothing to do
    1  a preflight check stopped the run (nothing was changed), or a repair
       failed or left a reference to the old root (see the report)
    2  a confirmation was declined or had no input (pass -Yes when unattended)
"@

if ($Help) {
    Write-Host $usage
    exit 0
}

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Host "[ERROR] This is the Windows tool. On macOS and Linux run scripts/unix/move-scripts-root.sh." -ForegroundColor Red
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
# Shared helpers: Read-MarkedText / Write-MarkedText (byte-preserving edits),
# Set-MarkedBlock, Backup-UserFile, ConvertTo-GitSafeDirectory, Resolve-FullPath.
. (Join-Path $scriptDir 'Functions.ps1')

# Paths are compared case-insensitively, as Windows does.
$cmp = [StringComparison]::OrdinalIgnoreCase
$loginTaskName = 'GitConfig Pull at Login'
# Must match install.ps1 STEP 6b.
$widgetBegin = '# >>> gitconfig git-alias browser (Ctrl-G) >>>'
$widgetEnd = '# <<< gitconfig git-alias browser <<<'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# A full path with no trailing separator (a drive root keeps its "\"). A
# relative path (or ~\...) is taken from the current location; a rooted one is
# used as it is, even on a drive that doesn't exist.
function Get-NormalPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Resolve-FullPath $Path }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

# True when Path (either slash) is Root or inside it.
function Test-PathAtOrUnder([string]$Path, [string]$Root) {
    if (-not $Path -or -not $Root) { return $false }
    $p = ($Path -replace '/', '\').TrimEnd('\')
    $r = $Root.TrimEnd('\')
    if ([string]::Equals($p, $r, $cmp)) { return $true }
    return $p.StartsWith($r + '\', $cmp)
}

function Test-UnderOld([string]$Path) { Test-PathAtOrUnder $Path $From }

# Path with the old root swapped for the new one; a path outside the old root
# is returned as it is (with backslashes).
function ConvertTo-NewPath([string]$Path) {
    $p = $Path -replace '/', '\'
    if (Test-UnderOld $p) { return $To + $p.TrimEnd('\').Substring($From.TrimEnd('\').Length) }
    return $p
}

# Relative path from the folder FromDir to ToPath, with backslashes.
# ([IO.Path]::GetRelativePath doesn't exist in Windows PowerShell 5.1.)
function Get-RelativePathText([string]$FromDir, [string]$ToPath) {
    $a = $FromDir.TrimEnd('\').Split('\')
    $b = $ToPath.TrimEnd('\').Split('\')
    $i = 0
    while ($i -lt $a.Length -and $i -lt $b.Length -and [string]::Equals($a[$i], $b[$i], $cmp)) { $i++ }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($j = $i; $j -lt $a.Length; $j++) { $parts.Add('..') }
    for ($j = $i; $j -lt $b.Length; $j++) { $parts.Add($b[$j]) }
    if ($parts.Count -eq 0) { return '.' }
    return ($parts -join '\')
}

# Claude Code names a project's folder under ~/.claude/projects after its path,
# with every character that isn't a letter or digit replaced by "-".
function ConvertTo-ClaudeProjectName([string]$Path) { $Path -replace '[^A-Za-z0-9]', '-' }

# A known folder (Documents, Desktop, ...) only counts when it is inside the
# home folder: the tool never touches files outside it.
function Get-KnownFolderUnderHome([string]$Name) {
    $dir = [Environment]::GetFolderPath($Name)
    if ($dir -and (Test-PathAtOrUnder $dir $homeDir)) { return (Get-NormalPath $dir) }
    return $null
}

function Get-UniquePaths([string[]]$Paths) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) { if ($p -and $seen.Add($p)) { $p } }
}

# ---------------------------------------------------------------------------
# Path forms (R14): how a text file can spell the old root, and the new
# spelling of each. A match counts only at a path boundary (see Get-FormsRegex).
# ---------------------------------------------------------------------------

# Path written with Sep as the separator: native "\", "/", or JSON's "\\".
function ConvertTo-SepForm([string]$Path, [string]$Sep) {
    switch ($Sep) {
        '/' { return ($Path -replace '\\', '/') }
        '\\' { return ($Path -replace '\\', '\\') }
        default { return $Path }
    }
}

# The old/new pairs for absolute, home-relative and (with FileDir) relative
# spellings. FileDir is the folder of a .code-workspace file, whose folder
# paths are relative to it.
function Get-RewriteForms([string]$FileDir) {
    $forms = New-Object System.Collections.Generic.List[object]
    $seps = '\', '/', '\\'
    foreach ($sep in $seps) {
        $forms.Add([pscustomobject]@{ Old = (ConvertTo-SepForm $From $sep); New = (ConvertTo-SepForm $To $sep) })
    }
    # git's safe.directory form of a UNC root (%(prefix)///server/share).
    $gitFrom = ConvertTo-GitSafeDirectory -Path $From
    if ($gitFrom -ne (ConvertTo-SepForm $From '/')) {
        $forms.Add([pscustomobject]@{ Old = $gitFrom; New = (ConvertTo-GitSafeDirectory -Path $To) })
    }

    if (Test-PathAtOrUnder $From $homeDir) {
        $homeLen = $homeDir.TrimEnd('\').Length
        $oldRel = $From.Substring($homeLen + 1)
        $newRel = $null
        if ((Test-PathAtOrUnder $To $homeDir) -and $To.Length -gt $homeLen) { $newRel = $To.Substring($homeLen + 1) }
        foreach ($prefix in '$HOME', '${HOME}', '$env:USERPROFILE', '${env:USERPROFILE}', '$env:HOME', '%USERPROFILE%', '%HOME%', '~') {
            foreach ($sep in $seps) {
                $new = if ($newRel) { $prefix + $sep + (ConvertTo-SepForm $newRel $sep) } else { ConvertTo-SepForm $To $sep }
                $forms.Add([pscustomobject]@{ Old = ($prefix + $sep + (ConvertTo-SepForm $oldRel $sep)); New = $new })
            }
        }
    }

    if ($FileDir) {
        # "..\..\<old root>\repo" from the file's folder: one pair per
        # ancestor the old root is under, all rewritten to the path from the
        # file's folder to the new root.
        $newRelative = Get-RelativePathText $FileDir $To
        $base = $FileDir
        $k = 0
        while ($true) {
            $base = [IO.Path]::GetDirectoryName($base)
            if (-not $base) { break }
            $k++
            $b = $base.TrimEnd('\')
            if (-not $From.StartsWith($b + '\', $cmp)) { continue }
            $tail = $From.Substring($b.Length + 1)
            foreach ($sep in $seps) {
                $dots = ('..' + $sep) * $k
                $forms.Add([pscustomobject]@{ Old = ($dots + (ConvertTo-SepForm $tail $sep)); New = (ConvertTo-SepForm $newRelative $sep) })
            }
        }
    }
    return , $forms
}

# One char per byte (Latin-1) for text Read-MarkedText reads byte-wise:
# the UTF-8 bytes of a non-ASCII path then match the file's bytes.
function ConvertTo-ByteText([string]$Text) {
    [Text.Encoding]::GetEncoding(28591).GetString([Text.Encoding]::UTF8.GetBytes($Text))
}

$script:regexCache = @{}

# A regex matching every old spelling in Forms at a path boundary: not right
# after a path character (so a longer path that merely ends the same way isn't
# matched), and followed by "/", "\", a quote, whitespace or the end of the
# line (so ...\ScriptsOld isn't). Case-insensitive, as Windows paths are.
# Returns the regex and the old -> new map.
function Get-FormsRegex($Forms, [bool]$ByteText) {
    $key = [string]$ByteText + [char]0 + (($Forms | ForEach-Object { $_.Old + [char]1 + $_.New }) -join [char]0)
    if ($script:regexCache.ContainsKey($key)) { return $script:regexCache[$key] }
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $alternatives = New-Object System.Collections.Generic.List[string]
    # Longest first, so a longer spelling wins over a shorter one at the same spot.
    foreach ($f in @($Forms | Sort-Object -Property @{ Expression = { $_.Old.Length } } -Descending)) {
        $old = $f.Old
        $new = $f.New
        if ($ByteText) { $old = ConvertTo-ByteText $old; $new = ConvertTo-ByteText $new }
        if (-not $old -or $map.ContainsKey($old)) { continue }
        $map[$old] = $new
        $alternatives.Add([regex]::Escape($old))
    }
    $pattern = '(?<![A-Za-z0-9_.\-/\\])(?:' + ($alternatives -join '|') + ')(?=[/\\"''\s]|$)'
    $options = [Text.RegularExpressions.RegexOptions]'Multiline, IgnoreCase, CultureInvariant'
    $entry = [pscustomobject]@{ Regex = (New-Object regex($pattern, $options)); Map = $map }
    $script:regexCache[$key] = $entry
    return $entry
}

# Rewrite every old spelling in Text. Returns Count and Text.
function Convert-TextForms([string]$Text, $Forms, [bool]$ByteText = $false) {
    $entry = Get-FormsRegex $Forms $ByteText
    if ([string]::IsNullOrEmpty($Text)) { return [pscustomobject]@{ Count = 0; Text = $Text } }
    $count = $entry.Regex.Matches($Text).Count
    if ($count -eq 0) { return [pscustomobject]@{ Count = 0; Text = $Text } }
    $map = $entry.Map
    $evaluator = [Text.RegularExpressions.MatchEvaluator] { param($m) $map[$m.Value] }.GetNewClosure()
    return [pscustomobject]@{ Count = $count; Text = $entry.Regex.Replace($Text, $evaluator) }
}

# An environment variable value is a ";" list (PATH and friends): each entry
# is rewritten on its own, so "...\Scripts;" still ends a path.
function Convert-EnvValue([string]$Value) {
    $parts = $Value -split ';'
    $out = foreach ($part in $parts) { (Convert-TextForms $part $script:baseForms).Text }
    return (@($out) -join ';')
}

function Get-FileForms([string]$Path) {
    if ($Path -like '*.code-workspace') { return (Get-RewriteForms -FileDir (Split-Path -Parent $Path)) }
    return $script:baseForms
}

# Count (or with -Write, rewrite) the old root in a text file, keeping its
# encoding, BOM and line endings byte for byte (Read-MarkedText reads UTF-16/32
# decoded and anything else one char per byte).
function Update-TextFile([string]$Path, [switch]$Write) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $file = Read-MarkedText -FullPath $item.FullName
    $result = Convert-TextForms $file.Text (Get-FileForms $item.FullName) $file.Latin1
    if ($Write -and $result.Count -gt 0) {
        Write-MarkedText -FullPath $item.FullName -File $file -Text $result.Text
    }
    return $result.Count
}

# ---------------------------------------------------------------------------
# System touchpoints
# ---------------------------------------------------------------------------

# User and machine environment variables, read raw (%USERPROFILE% stays
# unexpanded) with their registry kind, so a REG_EXPAND_SZ PATH is written back
# as one. GITCONFIG_MOVE_ENV_FILE is a test seam: a JSON file
# {"User": {name: {"Value", "Kind"}}, "Machine": {...}} used instead of the
# registry, so the tests never touch the real environment.
function Get-EnvironmentEntries([ValidateSet('User', 'Machine')][string]$Scope) {
    if ($env:GITCONFIG_MOVE_ENV_FILE) {
        if (-not (Test-Path -LiteralPath $env:GITCONFIG_MOVE_ENV_FILE)) { return }
        $data = (Read-Utf8File $env:GITCONFIG_MOVE_ENV_FILE) | ConvertFrom-Json
        $scopeData = $data.$Scope
        if (-not $scopeData) { return }
        foreach ($p in $scopeData.PSObject.Properties) {
            [pscustomobject]@{ Name = $p.Name; Value = [string]$p.Value.Value; Kind = [string]$p.Value.Kind }
        }
        return
    }
    $key = if ($Scope -eq 'User') {
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    }
    else {
        [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    }
    if (-not $key) { return }
    try {
        foreach ($name in $key.GetValueNames()) {
            $kind = $key.GetValueKind($name)
            if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String -and $kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) { continue }
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            [pscustomobject]@{ Name = $name; Value = [string]$value; Kind = [string]$kind }
        }
    }
    finally { $key.Dispose() }
}

# Write one user-scope variable (never machine scope), keeping its kind.
function Set-UserEnvironmentValue([string]$Name, [string]$Value, [string]$Kind) {
    if ($env:GITCONFIG_MOVE_ENV_FILE) {
        $data = (Read-Utf8File $env:GITCONFIG_MOVE_ENV_FILE) | ConvertFrom-Json
        $data.User.$Name.Value = $Value
        Write-Utf8File -Path $env:GITCONFIG_MOVE_ENV_FILE -Text ($data | ConvertTo-Json -Depth 5)
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $key.Dispose() }
}

# Tell running programs (Explorer, new terminals) that the environment changed.
function Send-EnvironmentChange {
    if ($env:GITCONFIG_MOVE_ENV_FILE) { return }
    try {
        if (-not ('MoveScriptsRoot.NativeMethods' -as [type])) {
            Add-Type -Namespace MoveScriptsRoot -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 s.
        [void][MoveScriptsRoot.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    }
    catch {
        Write-Host "[WARN] Could not announce the environment change; sign out and back in to pick it up" -ForegroundColor Yellow
    }
}

function Test-IsElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A task this account runs (and so may change): its principal is this user.
# Tasks of SYSTEM, a service or another account are only reported.
function Test-OwnTask($Task) {
    $userId = "$($Task.Principal.UserId)"
    if (-not $userId) { return $false }
    if ([string]::Equals(($userId -split '\\')[-1], "$env:USERNAME", $cmp)) { return $true }
    try { return [string]::Equals($userId, [Security.Principal.WindowsIdentity]::GetCurrent().User.Value, $cmp) } catch { return $false }
}

function Test-AccessDenied($ErrorRecord) {
    $e = $ErrorRecord.Exception
    return ($e -is [UnauthorizedAccessException]) -or ($e.HResult -eq -2147024891) -or ("$($e.Message)" -match 'Access is denied|0x80070005')
}

# Answer a yes/no question: 'yes', 'no', or 'none' when there is no input to
# read (Read-Host fails in a -NonInteractive session and returns nothing at
# the end of redirected input).
function Read-YesNo([string]$Question) {
    $answer = $null
    try { $answer = Read-Host "$Question (y/n)" } catch { $answer = $null }
    if ($null -eq $answer) {
        Write-Host "[INFO] No answer (no input to read), so: no. Pass -Yes to skip this prompt." -ForegroundColor Yellow
        return 'none'
    }
    if ($answer -match '^\s*[Yy]') { return 'yes' }
    return 'no'
}

# ---------------------------------------------------------------------------
# Scans. Each one works before the move (on From) and after it (on To), so the
# same code builds the plan and rescans for leftovers.
# ---------------------------------------------------------------------------

# Folders up to 3 levels below Root (Root included) that hold a .git folder or
# file, skipping node_modules and .venv and never following a link.
function Get-RepoDirs([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        $dir = $entry[0]
        $depth = $entry[1]
        $git = Get-Item -LiteralPath (Join-Path $dir '.git') -Force -ErrorAction SilentlyContinue
        if ($git) { [pscustomobject]@{ Path = $dir; IsMain = [bool]$git.PSIsContainer } }
        if ($depth -ge 3) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($child.LinkType -or $child.Name -in '.git', 'node_modules', '.venv') { continue }
            $queue.Enqueue(@($child.FullName, ($depth + 1)))
        }
    }
}

# The path in a "gitdir: <path>" file (a worktree's .git) or a plain path file
# (a worktree's admin gitdir).
function Read-GitPathFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $line = @((Read-Utf8File $Path) -split "`r?`n")[0].Trim()
    return ($line -replace '^gitdir:\s*', '')
}

# Linked worktrees that still point at the old root, grouped by their main
# repo, all as paths after the move: the worktrees of each main repo under Root
# whose records name the old root, plus worktrees under Root whose main repo is
# under To (found from the worktree's own .git file).
function Get-WorktreeRepairs([string]$Root) {
    $byRepo = [ordered]@{}
    $add = {
        param([string]$Repo, [string]$Worktree)
        $k = $Repo.ToLowerInvariant()
        if (-not $byRepo.Contains($k)) { $byRepo[$k] = [pscustomobject]@{ Repo = $Repo; Worktrees = (New-Object System.Collections.Generic.List[string]) } }
        if (-not ($byRepo[$k].Worktrees | Where-Object { [string]::Equals($_, $Worktree, $cmp) })) { $byRepo[$k].Worktrees.Add($Worktree) }
    }
    foreach ($repo in @(Get-RepoDirs $Root)) {
        if ($repo.IsMain) {
            $admin = Join-Path $repo.Path '.git\worktrees'
            foreach ($wt in @(Get-ChildItem -LiteralPath $admin -Directory -Force -ErrorAction SilentlyContinue)) {
                $recorded = Read-GitPathFile (Join-Path $wt.FullName 'gitdir')
                if (-not $recorded) { continue }
                $wtPath = ConvertTo-NewPath (Split-Path -Parent ($recorded -replace '/', '\'))
                $wtFile = Read-GitPathFile (Join-Path $wtPath '.git')
                if (-not $wtFile) {
                    # Before the move the worktree is still at its old path.
                    $wtFile = Read-GitPathFile (Join-Path (Split-Path -Parent ($recorded -replace '/', '\')) '.git')
                }
                if ((Test-UnderOld $recorded) -or (Test-UnderOld $wtFile)) {
                    & $add (ConvertTo-NewPath $repo.Path) $wtPath
                }
            }
        }
        else {
            $gitdir = Read-GitPathFile (Join-Path $repo.Path '.git')
            if (-not (Test-UnderOld $gitdir)) { continue }
            $adminNew = ConvertTo-NewPath $gitdir
            $adminNow = if (Test-Path -LiteralPath ($gitdir -replace '/', '\')) { $gitdir -replace '/', '\' } else { $adminNew }
            $common = Read-GitPathFile (Join-Path $adminNow 'commondir')
            if (-not $common) { $common = '..\..' }
            if (-not [IO.Path]::IsPathRooted($common)) { $common = [IO.Path]::GetFullPath((Join-Path $adminNew $common)) }
            $common = ConvertTo-NewPath $common
            $main = if ((Split-Path -Leaf $common) -eq '.git') { Split-Path -Parent $common } else { $common }
            if (Test-PathAtOrUnder $main $To) { & $add $main (ConvertTo-NewPath $repo.Path) }
        }
    }
    return @($byRepo.Values)
}

# Folders (up to 5 levels below Root) holding a pyvenv.cfg: venvs embed their
# absolute path and must be recreated. Reported, never changed.
function Get-Venvs([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $entry[0] 'pyvenv.cfg') -PathType Leaf) { ConvertTo-NewPath $entry[0]; continue }
        if ($entry[1] -ge 5) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $entry[0] -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($child.LinkType -or $child.Name -in '.git', 'node_modules') { continue }
            $queue.Enqueue(@($child.FullName, ($entry[1] + 1)))
        }
    }
}

# Target of a symlink or junction as a full path.
function Get-LinkTargetPath($Item) {
    $t = @($Item.Target)[0]
    if (-not $t) { return $null }
    $t = $t -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', ''
    if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $Item.FullName) $t }
    return [IO.Path]::GetFullPath($t)
}

# The links the tool repairs (R13): $HOME and ~/.claude (depth 1), ~/.config
# (depth 2), ~/.local/bin and ~/bin (depth 1). A scan folder that is itself a
# link is not looked into (its contents belong to whatever it points at).
function Get-HomeLinks {
    $sets = @(
        @($homeDir, 1),
        @((Join-Path $homeDir '.claude'), 1),
        @((Join-Path $homeDir '.config'), 2),
        @((Join-Path $homeDir '.local\bin'), 1),
        @((Join-Path $homeDir 'bin'), 1)
    )
    foreach ($set in $sets) { Get-LinksIn $set[0] $set[1] }
}

function Get-LinksIn([string]$Dir, [int]$Depth) {
    $dirItem = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
    if (-not $dirItem -or -not $dirItem.PSIsContainer -or $dirItem.LinkType) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if ($item.LinkType -eq 'SymbolicLink' -or $item.LinkType -eq 'Junction') { $item }
        elseif ($Depth -gt 1 -and $item.PSIsContainer) { Get-LinksIn $item.FullName ($Depth - 1) }
    }
}

function Get-LinkItems {
    foreach ($item in @(Get-HomeLinks)) {
        $target = Get-LinkTargetPath $item
        if (Test-UnderOld $target) {
            [pscustomobject]@{ Path = $item.FullName; LinkType = [string]$item.LinkType; OldTarget = $target; NewTarget = (ConvertTo-NewPath $target); IsDir = [bool]$item.PSIsContainer }
        }
    }
}

# Documents folders whose PowerShell profiles are checked: ~/Documents and,
# when it is redirected inside the home folder (OneDrive), the real one.
function Get-DocumentsDirs {
    Get-UniquePaths @((Join-Path $homeDir 'Documents'), (Get-KnownFolderUnderHome 'MyDocuments'))
}

# The exact set of text files R14 rewrites (those that exist).
function Get-TextFileSet {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($docs in @(Get-DocumentsDirs)) {
        foreach ($edition in 'PowerShell', 'WindowsPowerShell') {
            foreach ($name in 'profile.ps1', 'Microsoft.PowerShell_profile.ps1', 'Microsoft.VSCode_profile.ps1') {
                $paths.Add((Join-Path (Join-Path $docs $edition) $name))
            }
        }
    }
    foreach ($rel in '.gitconfig.local', '.config\gitconfig\safe-directories', '.bashrc', '.bash_profile', '.profile',
        '.zshrc', '.zprofile', '.config\fish\config.fish', '.claude\settings.json') {
        $paths.Add((Join-Path $homeDir $rel))
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.claude\scheduled-tasks') -Directory -Force -ErrorAction SilentlyContinue)) {
        $paths.Add((Join-Path $dir.FullName 'SKILL.md'))
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.vscode\workspaces') -Filter '*.code-workspace' -File -Force -ErrorAction SilentlyContinue)) {
        $paths.Add($f.FullName)
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.vscode\agent-plugins') -Filter '.mcp.json' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $paths.Add($f.FullName)
    }
    foreach ($p in (Get-UniquePaths $paths)) { if (Test-Path -LiteralPath $p -PathType Leaf) { $p } }
}

# Text files to rewrite, with match counts. A file that is a link into a repo
# (a dotfiles checkout under the root) is only reported: the tool never edits
# files inside a repo.
function Get-TextItems {
    foreach ($path in @(Get-TextFileSet)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item.LinkType) {
            $target = Get-LinkTargetPath $item
            if ((Test-UnderOld $target) -or (Test-PathAtOrUnder $target $To)) {
                [pscustomobject]@{ Path = $path; Count = 0; InRepo = $true }
                continue
            }
        }
        $count = 0
        try { $count = Update-TextFile -Path $path } catch { $count = 0 }
        if ($count -gt 0) { [pscustomobject]@{ Path = $path; Count = $count; InRepo = $false } }
    }
}

# Scheduled tasks whose action names the old root (R15).
function Get-TaskItems {
    $all = @()
    try { $all = @(Get-ScheduledTask -ErrorAction Stop) }
    catch {
        $script:planWarnings.Add("Could not list scheduled tasks: $($_.Exception.Message)")
        return
    }
    foreach ($task in $all) {
        $fields = New-Object System.Collections.Generic.List[string]
        foreach ($action in @($task.Actions)) {
            foreach ($field in 'Execute', 'Arguments', 'WorkingDirectory') {
                $value = "$($action.$field)"
                if ($value -and (Convert-TextForms $value $script:baseForms).Count -gt 0) { $fields.Add("$field=$value") }
            }
        }
        if ($fields.Count -eq 0) { continue }
        [pscustomobject]@{
            Task   = $task
            Key    = "$($task.TaskPath)$($task.TaskName)"
            Own    = (Test-OwnTask $task)
            Login  = ($task.TaskName -eq $loginTaskName)
            Fields = $fields
        }
    }
}

# User-scope environment variables naming the old root (R16).
function Get-EnvItems([string]$Scope = 'User') {
    foreach ($e in @(Get-EnvironmentEntries -Scope $Scope)) {
        $new = Convert-EnvValue $e.Value
        if ($new -cne $e.Value) { [pscustomobject]@{ Name = $e.Name; Old = $e.Value; New = $new; Kind = $e.Kind } }
    }
}

# .lnk files under the Desktop and the Start Menu's Programs (Startup included).
function Get-ShortcutFiles {
    $dirs = @(
        (Join-Path $homeDir 'Desktop'),
        (Get-KnownFolderUnderHome 'Desktop'),
        (Get-KnownFolderUnderHome 'Programs')
    )
    if ($env:APPDATA -and (Test-PathAtOrUnder $env:APPDATA $homeDir)) {
        $dirs += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    }
    $files = foreach ($dir in (Get-UniquePaths $dirs)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        }
    }
    Get-UniquePaths @($files)
}

$script:shell = $null
function Get-WScriptShell {
    if (-not $script:shell) { $script:shell = New-Object -ComObject WScript.Shell }
    return $script:shell
}

function Get-ShortcutItems {
    foreach ($path in @(Get-ShortcutFiles)) {
        try { $lnk = (Get-WScriptShell).CreateShortcut($path) } catch { continue }
        $changes = [ordered]@{}
        foreach ($field in 'TargetPath', 'Arguments', 'WorkingDirectory', 'IconLocation') {
            $value = "$($lnk.$field)"
            if (-not $value) { continue }
            $r = Convert-TextForms $value $script:baseForms
            if ($r.Count -gt 0) { $changes[$field] = @($value, $r.Text) }
        }
        if ($changes.Count -gt 0) { [pscustomobject]@{ Path = $path; Changes = $changes } }
    }
}

# Claude Code project folders named after a path under the old root (R17).
function Get-ProjectItems {
    $dir = Join-Path $homeDir '.claude\projects'
    $oldName = ConvertTo-ClaudeProjectName $From
    $newName = ConvertTo-ClaudeProjectName $To
    foreach ($p in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not ([string]::Equals($p.Name, $oldName, $cmp) -or $p.Name.StartsWith($oldName + '-', $cmp))) { continue }
        $target = $newName + $p.Name.Substring($oldName.Length)
        $dest = Join-Path $dir $target
        [pscustomobject]@{ Path = $p.FullName; NewPath = $dest; Blocked = [bool](Test-Path -LiteralPath $dest) }
    }
}

# App state that mentions the old root (reported only, never changed).
function Get-AppStateMentions {
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Join-Path $homeDir '.claude.json'))
    if ($env:APPDATA -and (Test-PathAtOrUnder $env:APPDATA $homeDir)) {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Claude') -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        foreach ($code in 'Code', 'Code - Insiders') {
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA "$code\User\globalStorage") -File -Force -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        }
    }
    # The drive-less tail catches file:///c%3A/... URIs too.
    $needles = @($From, (ConvertTo-SepForm $From '/'), (ConvertTo-SepForm $From '\\'), (ConvertTo-SepForm ($From -replace '^[A-Za-z]:', '') '/'))
    foreach ($f in $files) {
        $item = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer -or $item.Length -gt 64MB) { continue }
        try { $file = Read-MarkedText -FullPath $item.FullName } catch { continue }
        foreach ($n in $needles) {
            $needle = if ($file.Latin1) { ConvertTo-ByteText $n } else { $n }
            if ($file.Text.IndexOf($needle, $cmp) -ge 0) { $f; break }
        }
    }
}

# What R12 re-runs from the clone's new location, and why.
function Get-GeneratorItems {
    $items = New-Object System.Collections.Generic.List[object]
    $gitconfig = Join-Path $homeDir '.gitconfig'
    if ((Test-Path -LiteralPath $gitconfig -PathType Leaf) -and (Update-TextFile -Path $gitconfig) -gt 0) {
        $items.Add([pscustomobject]@{ Kind = 'gitconfig'; Text = "Initialize-GitConfig.ps1 -Force (regenerates $gitconfig)"; Path = $gitconfig })
    }
    $stale = @(foreach ($name in '.gitignore_global', 'gitconfig_helper.py') {
            $link = Get-Item -LiteralPath (Join-Path $homeDir $name) -Force -ErrorAction SilentlyContinue
            if ($link -and $link.LinkType -and (Test-UnderOld (Get-LinkTargetPath $link))) { $link.FullName }
        })
    if ($stale.Count -gt 0) {
        $items.Add([pscustomobject]@{ Kind = 'symlinks'; Text = "Initialize-Symlinks.ps1 -Force ($($stale -join ', '))"; Path = $null })
    }
    $login = $null
    try { $login = Get-ScheduledTask -TaskName $loginTaskName -ErrorAction Stop } catch { $login = $null }
    if ($login) {
        $hit = $false
        foreach ($action in @($login.Actions)) {
            foreach ($field in 'Execute', 'Arguments', 'WorkingDirectory') {
                if ("$($action.$field)" -and (Convert-TextForms "$($action.$field)" $script:baseForms).Count -gt 0) { $hit = $true }
            }
        }
        if ($hit) {
            $items.Add([pscustomobject]@{ Kind = 'logintask'; Text = "Register-LoginTask.ps1 -RepoPath `"$script:cloneNew`" (task '$loginTaskName')"; Path = $null })
        }
    }
    foreach ($docs in @(Get-DocumentsDirs)) {
        foreach ($edition in 'WindowsPowerShell', 'PowerShell') {
            $profilePath = Join-Path (Join-Path $docs $edition) 'profile.ps1'
            if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { continue }
            # A linked profile belongs to whatever it points at (never edited here).
            if ((Get-Item -LiteralPath $profilePath -Force).LinkType) { continue }
            $text = (Read-MarkedText -FullPath (Get-Item -LiteralPath $profilePath -Force).FullName).Text
            if ($text.IndexOf($widgetBegin, [StringComparison]::Ordinal) -lt 0) { continue }
            if ((Update-TextFile -Path $profilePath) -gt 0) {
                $items.Add([pscustomobject]@{ Kind = 'profile'; Text = "Ctrl-G profile block (install.ps1 step 6b) in $profilePath"; Path = $profilePath })
            }
        }
    }
    return $items
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

function Get-MovePlan([string]$ScanRoot) {
    $plan = [pscustomobject]@{
        Worktrees  = @(Get-WorktreeRepairs $ScanRoot)
        Generators = @()
        Links      = @(Get-LinkItems)
        Text       = @()
        InRepo     = @()
        Tasks      = @()
        Env        = @(Get-EnvItems 'User')
        Shortcuts  = @(Get-ShortcutItems)
        Projects   = @(Get-ProjectItems)
        Venvs      = @(Get-Venvs $ScanRoot)
        System     = (New-Object System.Collections.Generic.List[string])
        AppState   = @(Get-AppStateMentions)
    }
    if ($script:cloneUnderTo) { $plan.Generators = @(Get-GeneratorItems) }
    $textItems = @(Get-TextItems)
    $plan.Text = @($textItems | Where-Object { -not $_.InRepo })
    $plan.InRepo = @($textItems | Where-Object { $_.InRepo } | ForEach-Object { $_.Path })
    $loginByGenerator = @($plan.Generators | Where-Object { $_.Kind -eq 'logintask' }).Count -gt 0
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($t in @(Get-TaskItems)) {
        if ($t.Login -and $loginByGenerator) { continue }
        if ($t.Own -and -not $script:deniedTasks.Contains($t.Key)) { $tasks.Add($t) }
        else {
            $why = if ($t.Own) { 'this account may not change it' } else { "runs as '$($t.Task.Principal.UserId)'" }
            $plan.System.Add("scheduled task $($t.Key) ($why): $($t.Fields -join '; ')")
        }
    }
    $plan.Tasks = $tasks.ToArray()
    foreach ($e in @(Get-EnvItems 'Machine')) { $plan.System.Add("machine environment variable $($e.Name) = $($e.Old)") }
    return $plan
}

function Test-PlanHasWork($Plan) {
    ($Plan.Worktrees.Count + $Plan.Generators.Count + $Plan.Links.Count + $Plan.Text.Count + $Plan.Tasks.Count +
        $Plan.Env.Count + $Plan.Shortcuts.Count + $Plan.Projects.Count) -gt 0
}

function Write-Section([string]$Title, $Lines) {
    Write-Host $Title -ForegroundColor Cyan
    $list = @($Lines | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Host '  (none)' -ForegroundColor DarkGray }
    foreach ($l in $list) { Write-Host "  $l" }
}

function Write-Plan($Plan, [bool]$MoveNeeded) {
    Write-Host ''
    Write-Host 'Plan' -ForegroundColor Cyan
    Write-Host '====' -ForegroundColor Cyan
    $moveLine = if ($MoveNeeded) { "$From -> $To (one rename)" } else { "already moved to $To; resuming repairs" }
    Write-Section 'Move:' @($moveLine)
    Write-Section 'Repos and worktrees to repair:' @(foreach ($r in $Plan.Worktrees) {
            "$($r.Repo): git worktree repair"
            foreach ($w in $r.Worktrees) { "    worktree $w" }
        })
    $genLines = @($Plan.Generators | ForEach-Object { $_.Text })
    if (-not $script:cloneUnderTo) { $genLines = @("skipped: this gitconfig clone ($repoRoot) is not under $To") }
    Write-Section "This repo's generators to re-run (from $script:cloneNew):" $genLines
    Write-Section 'Files to rewrite:' @(foreach ($t in $Plan.Text) {
            $m = if ($t.Count -eq 1) { 'match' } else { 'matches' }
            "$($t.Path) ($($t.Count) $m)"
        })
    Write-Section 'Links to re-point:' @(foreach ($l in $Plan.Links) { "$($l.Path) [$($l.LinkType)] -> $($l.NewTarget)" })
    Write-Section 'Scheduled tasks to update:' @(
        foreach ($t in $Plan.Tasks) { "$($t.Key): $($t.Fields -join '; ')" }
        foreach ($g in $Plan.Generators) { if ($g.Kind -eq 'logintask') { "\$loginTaskName (re-registered by Register-LoginTask.ps1)" } }
    )
    Write-Section 'User environment variables to update:' @(foreach ($e in $Plan.Env) { "$($e.Name): $($e.Old) -> $($e.New)" })
    Write-Section 'Shortcuts to update:' @(foreach ($s in $Plan.Shortcuts) { "$($s.Path) ($(@($s.Changes.Keys) -join ', '))" })
    Write-Section 'Claude project folders to rename:' @(foreach ($p in $Plan.Projects) {
            if ($p.Blocked) { "$($p.Path) -> $($p.NewPath) (left alone: the destination already exists)" }
            else { "$($p.Path) -> $($p.NewPath)" }
        })
    Write-Section 'Report only (not changed):' @(
        foreach ($v in $Plan.Venvs) { "Python venv to recreate: $v" }
        foreach ($s in $Plan.System) { "System scope: $s" }
        foreach ($a in $Plan.AppState) { "App state that mentions the old root: $a" }
        foreach ($f in $Plan.InRepo) { "Link into a repo (not edited): $f" }
    )
    foreach ($w in $script:planWarnings) { Write-Host "[WARN] $w" -ForegroundColor Yellow }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Backups (R19)
# ---------------------------------------------------------------------------

# Copy Path into backup/, under its path relative to $HOME (the first original
# wins when a file is changed twice in one run).
function Save-MoveBackup([string]$Path) {
    $full = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    if (Test-PathAtOrUnder $full $homeDir) { $rel = $full.Substring($homeDir.TrimEnd('\').Length + 1) }
    else { $rel = Join-Path '_outside-home' ($full -replace ':', '') }
    $dest = Join-Path $script:backupDir $rel
    if (Test-Path -LiteralPath $dest) { return }
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    # File.Copy follows a symlinked file and copies what it points at.
    [IO.File]::Copy($full, $dest, $false)
}

function Add-BackupRecord([string]$Line) {
    Add-Utf8Text -Path (Join-Path $script:backupDir 'links-and-tasks.txt') -Text ($Line + "`r`n")
}

# Files this repo's installers manage (profiles, dotfiles in $HOME) also get the
# usual timestamped copy next to them, as every other script here keeps.
function Test-InstallerManagedFile([string]$Path) {
    $parent = Split-Path -Parent $Path
    if ([string]::Equals($parent, $homeDir.TrimEnd('\'), $cmp)) { return $true }
    if ($Path -like '*\PowerShell\*.ps1' -or $Path -like '*\WindowsPowerShell\*.ps1') { return $true }
    return ($Path -like '*\.config\gitconfig\safe-directories')
}

# ---------------------------------------------------------------------------
# Repairs. Each step runs even if an earlier one failed; problems are
# collected in $failures and the step carries on with its next item.
# ---------------------------------------------------------------------------

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($out) -join "`n").Trim() }
}

# Run a step script of this repo and return its exit code (they report a
# failure with "exit 1", which & does not turn into an error).
function Invoke-RepoScript([string]$Path, [hashtable]$Arguments = @{}) {
    $global:LASTEXITCODE = 0
    & $Path @Arguments | Out-Host
    return $global:LASTEXITCODE
}

function Repair-Worktrees($Items) {
    foreach ($r in $Items) {
        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($w in $r.Worktrees) {
            if (Test-Path -LiteralPath $w -PathType Container) { $paths.Add($w) }
            else { $failures.Add("worktree $w of $($r.Repo) is missing; run: git -C `"$($r.Repo)`" worktree prune") }
        }
        if ($paths.Count -eq 0) { continue }
        $res = Invoke-Native git (@('-C', $r.Repo, 'worktree', 'repair') + $paths)
        if ($res.Code -eq 0) { $changes.Add("repaired worktrees of $($r.Repo): $($paths -join ', ')") }
        else { $failures.Add("git worktree repair in $($r.Repo) failed (exit $($res.Code)): $($res.Output)") }
    }
}

function Repair-Links($Items) {
    foreach ($l in $Items) {
        $tmp = $null
        $type = $null
        try {
            $type = if ($l.LinkType -eq 'Junction') { 'Junction' } else { 'SymbolicLink' }
            # Make the new link under a temporary name first, so a link that
            # can't be made (no symlink privilege) leaves the old one in place.
            $tmp = "$($l.Path).move-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
            New-Item -ItemType $type -Path $tmp -Target $l.NewTarget -ErrorAction Stop | Out-Null
            Add-BackupRecord "link $($l.Path) [$($l.LinkType)] was -> $($l.OldTarget)"
            if ($l.IsDir) {
                # Delete the reparse point only (never what it points at).
                [IO.Directory]::Delete($l.Path, $false)
                [IO.Directory]::Move($tmp, $l.Path)
            }
            else {
                [IO.File]::Delete($l.Path)
                [IO.File]::Move($tmp, $l.Path)
            }
            $changes.Add("re-pointed $($l.Path) [$type] -> $($l.NewTarget)")
        }
        catch {
            if ($tmp -and (Get-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue)) {
                try { if ($l.IsDir) { [IO.Directory]::Delete($tmp, $false) } else { [IO.File]::Delete($tmp) } } catch { $null = $_ }
            }
            $hint = if ($type -eq 'SymbolicLink' -and -not (Test-IsElevated)) { ' (symbolic links need an elevated prompt or Developer Mode)' } else { '' }
            $failures.Add("could not re-point $($l.Path) -> $($l.NewTarget): $($_.Exception.Message)$hint")
        }
    }
}

function Invoke-Generators($Items) {
    $winDir = Join-Path $script:cloneNew 'scripts\windows version'
    foreach ($g in $Items) {
        try {
            switch ($g.Kind) {
                'gitconfig' {
                    foreach ($f in (Join-Path $homeDir '.gitconfig'), (Join-Path $homeDir '.gitconfig.local')) {
                        if (Test-Path -LiteralPath $f -PathType Leaf) { Save-MoveBackup $f }
                    }
                    $code = Invoke-RepoScript (Join-Path $winDir 'Initialize-GitConfig.ps1') @{ Force = $true }
                    if ($code -eq 0) { $changes.Add("regenerated $(Join-Path $homeDir '.gitconfig') (Initialize-GitConfig.ps1 -Force)") }
                    else { $failures.Add("Initialize-GitConfig.ps1 -Force exited $code") }
                }
                'symlinks' {
                    $code = Invoke-RepoScript (Join-Path $winDir 'Initialize-Symlinks.ps1') @{ Force = $true }
                    if ($code -eq 0) { $changes.Add('checked the home links (Initialize-Symlinks.ps1)') }
                    else { $failures.Add("Initialize-Symlinks.ps1 exited $code") }
                }
                'logintask' {
                    $old = Get-ScheduledTask -TaskName $loginTaskName -ErrorAction SilentlyContinue
                    if ($old) {
                        foreach ($a in @($old.Actions)) { Add-BackupRecord "task \$loginTaskName was Execute=$($a.Execute) Arguments=$($a.Arguments) WorkingDirectory=$($a.WorkingDirectory)" }
                    }
                    $code = Invoke-RepoScript (Join-Path $winDir 'Register-LoginTask.ps1') @{ RepoPath = $script:cloneNew }
                    if ($code -eq 0) { $changes.Add("re-registered task '$loginTaskName' for $($script:cloneNew)") }
                    else { $failures.Add("Register-LoginTask.ps1 -RepoPath `"$($script:cloneNew)`" exited $code") }
                }
                'profile' {
                    Save-MoveBackup $g.Path
                    $widgetPath = Join-Path $script:cloneNew 'scripts\shell\git-alias-widget.ps1'
                    # Single quotes so a '$' or '`' in the path is not expanded.
                    $loadLine = ". '{0}'" -f $widgetPath.Replace("'", "''")
                    switch (Set-MarkedBlock -Path $g.Path -BeginMarker $widgetBegin -EndMarker $widgetEnd -Body $loadLine) {
                        'Updated' { $changes.Add("updated the Ctrl-G block in $($g.Path)") }
                        'Unterminated' { $failures.Add("$($g.Path) has '$widgetBegin' but no end marker; left unchanged") }
                    }
                }
            }
        }
        catch { $failures.Add("$($g.Text): $($_.Exception.Message)") }
    }
}

function Repair-TextFiles($Items) {
    foreach ($t in $Items) {
        try {
            # Counted again: a generator may already have rewritten some lines.
            if ((Update-TextFile -Path $t.Path) -eq 0) { continue }
            Save-MoveBackup $t.Path
            if (Test-InstallerManagedFile $t.Path) { $null = Backup-UserFile -Path $t.Path }
            $n = Update-TextFile -Path $t.Path -Write
            $changes.Add("rewrote $($t.Path) ($n)")
        }
        catch { $failures.Add("could not rewrite $($t.Path): $($_.Exception.Message)") }
    }
}

function Repair-Tasks($Items) {
    foreach ($t in $Items) {
        $task = $t.Task
        $before = @(foreach ($a in @($task.Actions)) { "Execute=$($a.Execute) Arguments=$($a.Arguments) WorkingDirectory=$($a.WorkingDirectory)" })
        try {
            foreach ($a in @($task.Actions)) {
                foreach ($field in 'Execute', 'Arguments', 'WorkingDirectory') {
                    $value = "$($a.$field)"
                    if (-not $value) { continue }
                    $r = Convert-TextForms $value $script:baseForms
                    if ($r.Count -gt 0) { $a.$field = $r.Text }
                }
            }
            # The whole task goes back: triggers, principal and settings as they were.
            Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            foreach ($b in $before) { Add-BackupRecord "task $($t.Key) was $b" }
            $changes.Add("updated scheduled task $($t.Key)")
        }
        catch {
            if (Test-AccessDenied $_) {
                [void]$script:deniedTasks.Add($t.Key)
                $script:deniedNotes.Add("scheduled task $($t.Key) (this account may not change it): $($t.Fields -join '; ')")
            }
            else { $failures.Add("could not update scheduled task $($t.Key): $($_.Exception.Message)") }
        }
    }
}

function Repair-Environment($Items) {
    $changed = $false
    foreach ($e in $Items) {
        try {
            Add-BackupRecord "env User $($e.Name) [$($e.Kind)] was $($e.Old)"
            Set-UserEnvironmentValue -Name $e.Name -Value $e.New -Kind $e.Kind
            $changes.Add("user environment variable $($e.Name) -> $($e.New)")
            $changed = $true
        }
        catch { $failures.Add("could not update user environment variable $($e.Name): $($_.Exception.Message)") }
    }
    if ($changed) { Send-EnvironmentChange }
}

function Repair-Shortcuts($Items) {
    foreach ($s in $Items) {
        try {
            Save-MoveBackup $s.Path
            $lnk = (Get-WScriptShell).CreateShortcut($s.Path)
            foreach ($field in @($s.Changes.Keys)) { $lnk.$field = $s.Changes[$field][1] }
            $lnk.Save()
            foreach ($field in @($s.Changes.Keys)) { Add-BackupRecord "shortcut $($s.Path) $field was $($s.Changes[$field][0])" }
            $changes.Add("updated shortcut $($s.Path) ($(@($s.Changes.Keys) -join ', '))")
        }
        catch { $failures.Add("could not update shortcut $($s.Path): $($_.Exception.Message)") }
    }
}

function Rename-Projects($Items) {
    foreach ($p in $Items) {
        if ($p.Blocked) { continue }   # reported by the rescan
        try {
            [IO.Directory]::Move($p.Path, $p.NewPath)
            Add-BackupRecord "claude project $($p.NewPath) was $($p.Path)"
            $changes.Add("renamed Claude project folder $(Split-Path -Leaf $p.Path) -> $(Split-Path -Leaf $p.NewPath)")
        }
        catch { $failures.Add("could not rename $($p.Path): $($_.Exception.Message) (is Claude Code still running?)") }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Stop-Preflight([string]$Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Write-Host 'Nothing was changed.' -ForegroundColor Red
    exit 1
}

$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$homeDir = Get-NormalPath $homeDir
$From = Get-NormalPath $From
$To = Get-NormalPath $To

Write-Host 'Move the Scripts root' -ForegroundColor Cyan
Write-Host '=====================================' -ForegroundColor Cyan
Write-Host "From: $From" -ForegroundColor Green
Write-Host "To:   $To" -ForegroundColor Green
if ($DryRun) { Write-Host 'Dry run: nothing will be changed.' -ForegroundColor Yellow }
Write-Host ''

# --- Preflight (R3, R4): any abort leaves the machine untouched ------------
if ((Test-PathAtOrUnder $To $From) -or (Test-PathAtOrUnder $From $To)) {
    Stop-Preflight "From and To are the same folder, or one is inside the other ($From, $To)."
}
$fromItem = Get-Item -LiteralPath $From -Force -ErrorAction SilentlyContinue
$toItem = Get-Item -LiteralPath $To -Force -ErrorAction SilentlyContinue
if ($fromItem -and -not $fromItem.PSIsContainer) { Stop-Preflight "From ($From) is a file, not a folder." }
if (-not $fromItem -and -not $toItem) { Stop-Preflight "Neither From ($From) nor To ($To) exists." }
$toEmpty = $false
if ($fromItem -and $toItem) {
    $toEmpty = $toItem.PSIsContainer -and -not $toItem.LinkType -and -not (Get-ChildItem -LiteralPath $To -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $toEmpty) { Stop-Preflight "Both From and To exist, and To ($To) is not an empty folder. Move its contents away or pick another -To." }
}
if ($fromItem) {
    $toParent = Split-Path -Parent $To
    if (-not [string]::Equals([IO.Path]::GetPathRoot($From), [IO.Path]::GetPathRoot($toParent), $cmp)) {
        Stop-Preflight "From ($From) and To's parent ($toParent) are on different volumes. The move is one rename; it never copies across volumes."
    }
    if (-not (Test-Path -LiteralPath $toParent -PathType Container)) { Stop-Preflight "To's parent folder ($toParent) does not exist." }
}
if (-not $AllowSyncedTarget) {
    $synced = @(
        (Join-Path $homeDir 'Documents'), (Join-Path $homeDir 'Desktop'), (Join-Path $homeDir 'Pictures'),
        $env:OneDrive, $env:OneDriveCommercial,
        (Join-Path $homeDir 'Library\CloudStorage'), (Join-Path $homeDir 'Google Drive'), (Join-Path $homeDir 'Dropbox'),
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyPictures')
    )
    foreach ($s in $synced) {
        if ($s -and (Test-PathAtOrUnder $To (Get-NormalPath $s))) {
            Stop-Preflight "To ($To) is inside $s, a folder that cloud sync backs up. Pick a folder outside it, or pass -AllowSyncedTarget (for a rollback)."
        }
    }
}

$moveNeeded = [bool]$fromItem
if (-not $moveNeeded) { Write-Host 'already moved; resuming repairs' -ForegroundColor Yellow; Write-Host '' }

# This repo's clone after the move: the generators run from there.
$script:cloneNew = ConvertTo-NewPath $repoRoot
$script:cloneUnderTo = Test-PathAtOrUnder $script:cloneNew $To
$script:baseForms = Get-RewriteForms
$script:planWarnings = New-Object System.Collections.Generic.List[string]
$script:deniedTasks = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:deniedNotes = New-Object System.Collections.Generic.List[string]

# --- Google Drive (R5) ---------------------------------------------------------
$driveRunning = $moveNeeded -and @(Get-Process -Name 'GoogleDriveFS' -ErrorAction SilentlyContinue).Count -gt 0
if ($driveRunning) {
    Write-Host '[WARN] Google Drive for desktop is running. Pause syncing before the move' -ForegroundColor Yellow
    Write-Host '       (Drive icon in the taskbar > Settings > Pause syncing), so it does' -ForegroundColor Yellow
    Write-Host '       not sync the folder while it moves.' -ForegroundColor Yellow
    if (-not $DryRun -and -not $Yes) {
        if ((Read-YesNo 'Is Drive syncing paused?') -ne 'yes') {
            Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
            exit 2
        }
    }
    Write-Host ''
}

# --- Plan (R6) -----------------------------------------------------------------
$scanRoot = if ($moveNeeded) { $From } else { $To }
$plan = Get-MovePlan $scanRoot
if (-not $moveNeeded -and @($plan.Links | Where-Object { $_.LinkType -eq 'SymbolicLink' }).Count -gt 0 -and -not (Test-IsElevated)) {
    $script:planWarnings.Add('Not elevated: re-creating symbolic links needs an elevated prompt or Developer Mode.')
}
Write-Plan $plan $moveNeeded

if (-not $moveNeeded -and -not (Test-PlanHasWork $plan)) {
    Write-Host "Nothing to do: nothing on this machine still points at $From." -ForegroundColor Green
    exit 0
}
if ($DryRun) {
    Write-Host 'Dry run: nothing was changed.' -ForegroundColor Yellow
    exit 0
}
if (-not $Yes) {
    $verb = if ($moveNeeded) { 'Move the Scripts root and make these changes?' } else { 'Make these changes?' }
    if ((Read-YesNo $verb) -ne 'yes') {
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        exit 2
    }
}

# --- Move (R8, R9) ---------------------------------------------------------------
# Leave the old root first: this process's working directory inside it would
# hold the folder open and the rename would fail.
Set-Location -LiteralPath $homeDir
[Environment]::CurrentDirectory = $homeDir
if ($moveNeeded) {
    try {
        if ($toEmpty) { [IO.Directory]::Delete($To, $false) }
        # One rename. Directory.Move never copies: across volumes it throws.
        [IO.Directory]::Move($From, $To)
    }
    catch {
        if ($toEmpty -and -not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
        Write-Host "[ERROR] Could not rename $From to $To : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '        Close the programs and terminals that use files under it (editors,' -ForegroundColor Red
        Write-Host '        Claude Code, shells whose current folder is inside it), then run this again.' -ForegroundColor Red
        Write-Host 'Nothing was changed.' -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Moved $From -> $To" -ForegroundColor Green
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $homeDir ".scripts-move-$stamp"
$n = 1
while (Test-Path -LiteralPath $runDir) { $runDir = Join-Path $homeDir (".scripts-move-$stamp-{0:D2}" -f $n); $n++ }
$script:backupDir = Join-Path $runDir 'backup'
New-Item -ItemType Directory -Path $script:backupDir -Force | Out-Null

$changes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]
if ($moveNeeded) { $changes.Add("moved $From -> $To") }

# --- Repairs (R11-R17) -----------------------------------------------------------
$steps = @(
    @('worktrees', { Repair-Worktrees $plan.Worktrees }),
    # Links before the generators: Initialize-Symlinks then finds them in place.
    @('links', { Repair-Links $plan.Links }),
    @('generators', { Invoke-Generators $plan.Generators }),
    @('text files', { Repair-TextFiles $plan.Text }),
    @('scheduled tasks', { Repair-Tasks $plan.Tasks }),
    @('environment', { Repair-Environment $plan.Env }),
    @('shortcuts', { Repair-Shortcuts $plan.Shortcuts }),
    @('Claude projects', { Rename-Projects $plan.Projects })
)
foreach ($step in $steps) {
    Write-Host "[STEP] Repairing $($step[0])..." -ForegroundColor Cyan
    try { & $step[1] } catch { $failures.Add("$($step[0]): $($_.Exception.Message)") }
}
Set-Location -LiteralPath $homeDir

# --- Rescan and report (R18) -----------------------------------------------------
$after = Get-MovePlan $To
$remaining = New-Object System.Collections.Generic.List[string]
foreach ($r in $after.Worktrees) { foreach ($w in $r.Worktrees) { $remaining.Add("worktree $w of $($r.Repo) still names the old root") } }
foreach ($repo in @(Get-RepoDirs $To | Where-Object { $_.IsMain -and (Test-Path -LiteralPath (Join-Path $_.Path '.git\worktrees')) })) {
    $list = Invoke-Native git @('-C', $repo.Path, 'worktree', 'list', '--porcelain')
    foreach ($line in ($list.Output -split "`n")) {
        if ($line -match '^prunable' -or (($line -match '^worktree ') -and (Test-UnderOld ($line -replace '^worktree ', '')))) {
            $remaining.Add("git worktree list in $($repo.Path): $line")
        }
    }
}
foreach ($g in $after.Generators) { $remaining.Add("still names the old root: $($g.Text)") }
foreach ($l in $after.Links) { $remaining.Add("link $($l.Path) -> $($l.OldTarget)") }
foreach ($t in $after.Text) { $remaining.Add("$($t.Path) ($($t.Count))") }
foreach ($t in $after.Tasks) { $remaining.Add("scheduled task $($t.Key): $($t.Fields -join '; ')") }
foreach ($e in $after.Env) { $remaining.Add("user environment variable $($e.Name) = $($e.Old)") }
foreach ($s in $after.Shortcuts) { $remaining.Add("shortcut $($s.Path) ($(@($s.Changes.Keys) -join ', '))") }
foreach ($p in $after.Projects) {
    $why = if ($p.Blocked) { "; $($p.NewPath) already exists, merge them by hand" } else { '' }
    $remaining.Add("Claude project folder $($p.Path)$why")
}

$reportOnly = New-Object System.Collections.Generic.List[string]
foreach ($v in $after.Venvs) { $reportOnly.Add("Python venv to recreate: $v") }
foreach ($s in $after.System) { $reportOnly.Add("System scope: $s") }
foreach ($s in $script:deniedNotes) { if (-not ($after.System -contains $s)) { $reportOnly.Add("System scope: $s") } }
foreach ($a in $after.AppState) { $reportOnly.Add("App state that mentions the old root: $a") }
foreach ($f in $after.InRepo) { $reportOnly.Add("Link into a repo (not edited): $f") }
if (-not $script:cloneUnderTo) { $reportOnly.Add("This repo's generators were skipped: the clone ($repoRoot) is not under $To; run its install.ps1 there") }

$sb = New-Object System.Text.StringBuilder
$addLines = {
    param([string]$Title, $Lines)
    [void]$sb.AppendLine($Title)
    $list = @($Lines | Where-Object { $_ })
    if ($list.Count -eq 0) { [void]$sb.AppendLine('  (none)') }
    foreach ($l in $list) { [void]$sb.AppendLine("  $l") }
    [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('Scripts root move report')
[void]$sb.AppendLine("From:    $From")
[void]$sb.AppendLine("To:      $To")
[void]$sb.AppendLine("Date:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine("Backups: $($script:backupDir)")
[void]$sb.AppendLine('')
& $addLines '(a) Changes made:' $changes
& $addLines '(b) Failures:' $failures
& $addLines '(c) Remaining references to the old root (counted as failures):' $remaining
& $addLines '(d) Report only (not changed, not counted as failures):' $reportOnly
$failCount = $failures.Count + $remaining.Count
if ($failCount -eq 0) { [void]$sb.AppendLine('Result: OK') }
else { [void]$sb.AppendLine("Result: $failCount failure(s). Fix them, then run this again to finish.") }

$reportPath = Join-Path $runDir 'report.txt'
Write-Utf8File -Path $reportPath -Text $sb.ToString()
Write-Host ''
Write-Host $sb.ToString()
Write-Host "Report: $reportPath" -ForegroundColor Cyan
if ($failCount -gt 0) { exit 1 }
exit 0
