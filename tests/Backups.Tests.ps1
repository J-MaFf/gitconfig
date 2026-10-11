# Behavioural tests for "stop losing user files" (audit findings 1, 13, 16, 25):
# timestamped backups with retention, no backups of links into the repo, cleanup
# only on -Reinstall, back up before linking, and Cleanup's elevated relaunch
# keeping -KeepLocal. The helper tests run on any pwsh; tests that need real
# symlinks say so in their -Skip condition.

BeforeDiscovery {
    # The symlink tests need to create real symlinks. Linux and macOS always
    # can; Windows can when elevated (as on the CI runner) or in Developer Mode.
    # Probe rather than guess, so they run wherever symlinks work (#262).
    $script:canSymlink = $false
    $probe = Join-Path ([IO.Path]::GetTempPath()) ("symlink-probe-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $probe -ErrorAction Stop | Out-Null
        $probeTarget = Join-Path $probe "target"
        Set-Content -LiteralPath $probeTarget -Value "probe"
        New-Item -ItemType SymbolicLink -Path (Join-Path $probe "link") -Target $probeTarget -ErrorAction Stop | Out-Null
        $script:canSymlink = $true
    }
    catch { $script:canSymlink = $false }  # no symlink privilege: the tests skip
    finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:winDir = Join-Path (Join-Path $script:repoRoot "scripts") "windows version"
    $script:functionsPath = Join-Path $script:winDir "Functions.ps1"
    $script:pwshPath = (Get-Process -Id $PID).Path
    . $script:functionsPath

    function Get-Backups([string]$Path) {
        $dir = Split-Path -Parent $Path
        $name = Split-Path -Leaf $Path
        $pattern = '^' + [regex]::Escape($name) + '\.bak\.\d{8}-\d{6}(-\d{2,})?$'
        @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -cmatch $pattern } | Sort-Object Name)
    }

    # Run a script in a child process with Start-Process stubbed out, and
    # return the argument list the script tried to relaunch itself with.
    # The script's elevation check (Test-IsAdministrator) is stubbed to report
    # "not elevated" with an alias, which PowerShell resolves before the
    # script's own function of that name. That makes the script take its
    # relaunch branch even on an elevated session such as the CI runner (#262).
    function Invoke-Relaunch([string]$Script, [string[]]$ScriptArgs, [int]$ChildExitCode = 0) {
        # Refuse to run a script whose elevation check the stub can't reach:
        # on an elevated session it would do its real work instead.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
        $check = $ast.Find({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$isAdmin' -and
                $n.Right.Extent.Text -eq 'Test-IsAdministrator'
            }, $true)
        if (-not $check) { throw "$Script no longer sets `$isAdmin = Test-IsAdministrator; refusing to run it" }

        $capture = Join-Path $TestDrive ("relaunch-" + [guid]::NewGuid().ToString('N') + ".txt")
        $sandbox = Join-Path $TestDrive ("relaunch-home-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        # The Start-Process stub stands in for the elevated window: it records
        # the arguments and, with -PassThru, returns a process whose ExitCode is
        # $ChildExitCode.
        $cmd = @"
function Start-Process { param([string]`$FilePath, [string[]]`$ArgumentList, [string]`$Verb, [switch]`$Wait, [switch]`$PassThru) Set-Content -LiteralPath '$capture' -Value (`$ArgumentList -join ' '); if (`$PassThru) { [pscustomobject]@{ ExitCode = $ChildExitCode } } }
function Test-NotAdministrator { `$false }
Set-Alias -Name Test-IsAdministrator -Value Test-NotAdministrator
`$env:USERPROFILE = '$sandbox'; `$env:HOME = '$sandbox'
`$env:USERDOMAIN = 'CORP'; `$env:USERNAME = 'alice'
`$env:GIT_CONFIG_GLOBAL = '$sandbox/.gitconfig'; `$env:GIT_CONFIG_SYSTEM = '$sandbox/none'
& '$Script' $($ScriptArgs -join ' ')
exit `$LASTEXITCODE
"@
        & $script:pwshPath -NoProfile -NonInteractive -Command $cmd *> $null
        $code = $LASTEXITCODE
        $relaunchArgs = if (Test-Path $capture) { (Get-Content -LiteralPath $capture -Raw).Trim() } else { $null }
        [pscustomobject]@{ Args = $relaunchArgs; ExitCode = $code; Home = $sandbox }
    }

    # The argument list the script tried to relaunch itself with.
    function Get-RelaunchArgs([string]$Script, [string[]]$ScriptArgs) {
        (Invoke-Relaunch -Script $Script -ScriptArgs $ScriptArgs).Args
    }
}

Describe "Backup helpers (Functions.ps1)" -Tag 'Unit' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        $script:savedKeep = $env:GITCONFIG_BACKUP_KEEP
        Remove-Item Env:GITCONFIG_BACKUP_KEEP -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -ne $script:savedKeep) { $env:GITCONFIG_BACKUP_KEEP = $script:savedKeep }
        else { Remove-Item Env:GITCONFIG_BACKUP_KEEP -ErrorAction SilentlyContinue }
    }

    It "copies to a timestamped <name>.bak.yyyyMMdd-HHmmss and leaves the file in place" {
        $f = Join-Path $script:dir ".gitconfig"
        Set-Content -LiteralPath $f -Value "original"
        $backup = Backup-UserFile -Path $f
        (Split-Path -Leaf $backup) | Should -Match '^\.gitconfig\.bak\.\d{8}-\d{6}$'
        (Get-Content -LiteralPath $backup -Raw).Trim() | Should -Be "original"
        $f | Should -Exist
    }

    It "never overwrites an earlier backup, even within the same second (finding 1)" {
        $f = Join-Path $script:dir "file"
        foreach ($v in "original", "second", "third") {
            Set-Content -LiteralPath $f -Value $v
            $null = Backup-UserFile -Path $f
        }
        $backups = Get-Backups $f
        $backups.Count | Should -Be 3
        (Get-Content -LiteralPath $backups[0].FullName -Raw).Trim() | Should -Be "original"
        (Get-Content -LiteralPath $backups[2].FullName -Raw).Trim() | Should -Be "third"
    }

    It "more same-second backups than are kept still keep the newest (#268)" {
        # Pin the clock so all eight backups land in the same second.
        Mock Get-Date { '20260101-120000' } -ParameterFilter { $Format -eq 'yyyyMMdd-HHmmss' }
        $f = Join-Path $script:dir "file"
        foreach ($i in 1..8) {
            Set-Content -LiteralPath $f -Value "v$i"
            $null = Backup-UserFile -Path $f
        }
        $backups = Get-Backups $f
        ($backups | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() }) -join ',' |
            Should -Be 'v4,v5,v6,v7,v8'
        $backups[-1].Name | Should -Be 'file.bak.20260101-120000-07'
    }

    It "-Move moves the file away" {
        $f = Join-Path $script:dir "file"
        Set-Content -LiteralPath $f -Value "x"
        $backup = Backup-UserFile -Path $f -Move
        $f | Should -Not -Exist
        $backup | Should -Exist
    }

    It "returns `$null and does nothing when the file is missing" {
        Backup-UserFile -Path (Join-Path $script:dir "nope") | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:dir).Count | Should -Be 0
    }

    It "keeps the newest 5 backups by default" {
        $f = Join-Path $script:dir "file"
        1..7 | ForEach-Object { Set-Content -LiteralPath "$f.bak.2026010$_-120000" -Value "v$_" }
        Remove-OldBackups -Path $f
        $names = (Get-Backups $f).Name
        $names.Count | Should -Be 5
        $names | Should -Not -Contain "file.bak.20260101-120000"
        $names | Should -Contain "file.bak.20260107-120000"
    }

    It "honours GITCONFIG_BACKUP_KEEP, and 0 keeps everything" {
        $f = Join-Path $script:dir "file"
        1..4 | ForEach-Object { Set-Content -LiteralPath "$f.bak.2026010$_-120000" -Value "v$_" }
        $env:GITCONFIG_BACKUP_KEEP = "0"
        Remove-OldBackups -Path $f
        (Get-Backups $f).Count | Should -Be 4
        $env:GITCONFIG_BACKUP_KEEP = "2"
        Remove-OldBackups -Path $f
        (Get-Backups $f).Name | Should -Be @("file.bak.20260103-120000", "file.bak.20260104-120000")
    }

    It "never prunes legacy backups or unrelated files" {
        $f = Join-Path $script:dir "file"
        1..3 | ForEach-Object { Set-Content -LiteralPath "$f.bak.2026010$_-120000" -Value "v$_" }
        Set-Content -LiteralPath (Join-Path $script:dir "Existing.file.bak") -Value "legacy"
        Set-Content -LiteralPath "$f.bak" -Value "legacy"
        Set-Content -LiteralPath "$f.bak.notes" -Value "notes"
        Remove-OldBackups -Path $f -Keep 1
        (Join-Path $script:dir "Existing.file.bak") | Should -Exist
        "$f.bak" | Should -Exist
        "$f.bak.notes" | Should -Exist
        (Get-Backups $f).Count | Should -Be 1
    }

    It "pins the original on the first backup and never replaces or prunes it (#253)" {
        $f = Join-Path $script:dir ".gitconfig"
        Set-Content -LiteralPath $f -Value "original"
        $null = Backup-UserFile -Path $f
        1..7 | ForEach-Object {
            Set-Content -LiteralPath $f -Value "generated $_"
            $null = Backup-UserFile -Path $f
        }
        $pinned = "$f.pre-gitconfig"
        (Get-Content -LiteralPath $pinned -Raw).Trim() | Should -Be "original"
        # Pruning still keeps exactly the newest 5 timestamped backups, and the
        # original has aged out of them: the pin is what keeps it.
        $backups = Get-Backups $f
        $backups.Count | Should -Be 5
        foreach ($b in $backups) { (Get-Content -LiteralPath $b.FullName -Raw).Trim() | Should -Not -Be "original" }
    }

    It "-Move pins the original before moving it away (#253)" {
        $f = Join-Path $script:dir "file"
        Set-Content -LiteralPath $f -Value "original"
        $null = Backup-UserFile -Path $f -Move
        1..6 | ForEach-Object {
            Set-Content -LiteralPath $f -Value "generated $_"
            $null = Backup-UserFile -Path $f -Move
        }
        $f | Should -Not -Exist
        (Get-Content -LiteralPath "$f.pre-gitconfig" -Raw).Trim() | Should -Be "original"
        (Get-Backups $f).Count | Should -Be 5
    }

    It "pins the oldest surviving backup on an install from before the pin (#253)" {
        $f = Join-Path $script:dir "file"
        Set-Content -LiteralPath "$f.bak.20260101-120000" -Value "oldest"
        Set-Content -LiteralPath "$f.bak.20260102-120000" -Value "newer"
        Set-Content -LiteralPath $f -Value "current"
        $null = Backup-UserFile -Path $f
        (Get-Content -LiteralPath "$f.pre-gitconfig" -Raw).Trim() | Should -Be "oldest"
    }

    It "never overwrites an existing pin (#253)" {
        $f = Join-Path $script:dir "file"
        Set-Content -LiteralPath "$f.pre-gitconfig" -Value "pinned"
        Set-Content -LiteralPath $f -Value "current"
        $null = Backup-UserFile -Path $f
        (Get-Content -LiteralPath "$f.pre-gitconfig" -Raw).Trim() | Should -Be "pinned"
        Save-OriginalBackup -Path $f | Should -BeNullOrEmpty
    }

    It "Remove-OldBackups never deletes the pinned original (#253)" {
        $f = Join-Path $script:dir "file"
        1..3 | ForEach-Object { Set-Content -LiteralPath "$f.bak.2026010$_-120000" -Value "v$_" }
        Set-Content -LiteralPath "$f.pre-gitconfig" -Value "pinned"
        Remove-OldBackups -Path $f -Keep 1
        "$f.pre-gitconfig" | Should -Exist
        (Get-Backups $f).Count | Should -Be 1
    }

    Context "symlinks" -Skip:(-not $canSymlink) {
        # Creating symlinks on Windows needs admin or Developer Mode; see the
        # probe in BeforeDiscovery.

        BeforeEach {
            $script:repo = Join-Path $script:dir "repo"
            $script:sbHome = Join-Path $script:dir "home"
            New-Item -ItemType Directory -Path $script:repo, $script:sbHome | Out-Null
            Set-Content -LiteralPath (Join-Path $script:repo ".gitignore_global") -Value "ours"
        }

        It "Test-LinkIntoDirectory / Test-LinkPointsTo recognise links into the repo" {
            $link = Join-Path $script:sbHome ".gitignore_global"
            $target = Join-Path $script:repo ".gitignore_global"
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
            Test-LinkIntoDirectory -Path $link -Directory $script:repo | Should -BeTrue
            Test-LinkPointsTo -Path $link -Target $target | Should -BeTrue
            Test-LinkIntoDirectory -Path $link -Directory $script:sbHome | Should -BeFalse
            Test-LinkIntoDirectory -Path $target -Directory $script:repo | Should -BeFalse  # a real file
        }

        It "removes a link into the repo with -Move -RepoRoot, without a backup" {
            $link = Join-Path $script:sbHome ".gitignore_global"
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:repo ".gitignore_global") | Out-Null
            Backup-UserFile -Path $link -Move -RepoRoot $script:repo | Should -BeNullOrEmpty
            Get-LinkAwareItem -Path $link | Should -BeNullOrEmpty
            (Get-Backups $link).Count | Should -Be 0
            (Join-Path $script:repo ".gitignore_global") | Should -Exist
        }

        It "still backs up a link that points outside the repo" {
            $elsewhere = Join-Path $script:dir "elsewhere"
            Set-Content -LiteralPath $elsewhere -Value "theirs"
            $link = Join-Path $script:sbHome ".gitignore_global"
            New-Item -ItemType SymbolicLink -Path $link -Target $elsewhere | Out-Null
            Backup-UserFile -Path $link -Move -RepoRoot $script:repo | Should -Not -BeNullOrEmpty
            (Get-Backups $link).Count | Should -Be 1
        }

        It "pins a link outside the repo as a link to the same target, and never pins a link into the repo (#253)" {
            $elsewhere = Join-Path $script:dir "elsewhere"
            Set-Content -LiteralPath $elsewhere -Value "theirs"
            $link = Join-Path $script:sbHome ".gitignore_global"
            New-Item -ItemType SymbolicLink -Path $link -Target $elsewhere | Out-Null
            $null = Backup-UserFile -Path $link -Move -RepoRoot $script:repo
            $pin = Get-LinkAwareItem -Path "$link.pre-gitconfig"
            $pin.LinkType | Should -Be "SymbolicLink"
            Test-LinkPointsTo -Path "$link.pre-gitconfig" -Target $elsewhere | Should -BeTrue

            $repoLink = Join-Path $script:sbHome "gitconfig_helper.py"
            New-Item -ItemType SymbolicLink -Path $repoLink -Target (Join-Path $script:repo ".gitignore_global") | Out-Null
            $null = Backup-UserFile -Path $repoLink -Move -RepoRoot $script:repo
            Get-LinkAwareItem -Path "$repoLink.pre-gitconfig" | Should -BeNullOrEmpty
        }
    }

    It "Get-DroppedGitConfigKeys names settings the template lacks, without values" {
        $existing = Join-Path $script:dir ".gitconfig"
        Set-Content -LiteralPath $existing -Value "[user]`n`tname = Tester`n[filter `"lfs`"]`n`tclean = git-lfs clean -- %f`n[credential `"https://github.com`"]`n`thelper = secret-helper-value"
        $dropped = Get-DroppedGitConfigKeys -ExistingPath $existing -NewContent "[user]`n`tname = Tester`n"
        $dropped | Should -Contain "filter.lfs.clean"
        $dropped | Should -Contain "credential.https://github.com.helper"
        $dropped | Should -Not -Contain "user.name"
        ($dropped -join ' ') | Should -Not -Match "secret-helper-value"
        @(Get-DroppedGitConfigKeys -ExistingPath $existing -NewContent (Get-Content -LiteralPath $existing -Raw)).Count | Should -Be 0
    }

    It "Get-DroppedGitConfigKeys ignores a template-changed single value but reports a lost multi-value" {
        $existing = Join-Path $script:dir ".gitconfig"
        Set-Content -LiteralPath $existing -Value "[alias]`n`tst = status -sb`n[safe]`n`tdirectory = /a`n`tdirectory = /b"
        $dropped = @(Get-DroppedGitConfigKeys -ExistingPath $existing -NewContent "[alias]`n`tst = status`n[safe]`n`tdirectory = /a`n")
        $dropped | Should -Not -Contain "alias.st"
        $dropped | Should -Contain "safe.directory"
        @(Get-DroppedGitConfigKeys -ExistingPath $existing -NewContent "[alias]`n`tst = status`n[safe]`n`tdirectory = /a`n`tdirectory = /b`n").Count | Should -Be 0
    }
}

Describe "Initialize-GitConfig.ps1 backups and dropped-setting warning" -Tag 'Unit' {

    BeforeAll {
        $script:saved = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; G = $env:GIT_CONFIG_GLOBAL; S = $env:GIT_CONFIG_SYSTEM }
        $script:testHome = Join-Path $TestDrive "igc-home"
        New-Item -ItemType Directory -Path $script:testHome | Out-Null
        $env:USERPROFILE = $script:testHome
        $env:HOME = $script:testHome
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:testHome ".gitconfig"
        $env:GIT_CONFIG_SYSTEM = Join-Path $script:testHome "no-system-config"
        $script:initScript = Join-Path $script:winDir "Initialize-GitConfig.ps1"
        $script:cfg = Join-Path $script:testHome ".gitconfig"
    }

    AfterAll {
        $env:USERPROFILE = $script:saved.USERPROFILE
        $env:HOME = $script:saved.HOME
        $env:GIT_CONFIG_GLOBAL = $script:saved.G
        $env:GIT_CONFIG_SYSTEM = $script:saved.S
    }

    It "keeps every earlier backup across regenerations and warns about dropped keys" {
        Set-Content -LiteralPath $script:cfg -Value "[filter `"lfs`"]`n`tclean = git-lfs clean -- %f"
        $out = & $script:initScript -Force 6>&1 | Out-String
        $out | Should -Match "filter\.lfs\.clean"
        $out | Should -Match "\.gitconfig\.local"

        Set-Content -LiteralPath $script:cfg -Value "# second hand edit"
        & $script:initScript -Force *> $null

        $backups = Get-Backups $script:cfg
        $backups.Count | Should -Be 2
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should -Match "git-lfs clean"
    }

    It "keeps the original pinned across many regenerations (#253)" {
        Get-ChildItem -LiteralPath $script:testHome -Force -Filter ".gitconfig*" | Remove-Item -Force
        Set-Content -LiteralPath $script:cfg -Value "[alias]`n`tprecious = status"
        & $script:initScript -Force *> $null
        1..6 | ForEach-Object {
            Add-Content -LiteralPath $script:cfg -Value "# hand edit $_"
            & $script:initScript -Force *> $null
        }
        $backups = Get-Backups $script:cfg
        $backups.Count | Should -Be 5
        foreach ($b in $backups) { (Get-Content -LiteralPath $b.FullName -Raw) | Should -Not -Match "precious" }
        (Get-Content -LiteralPath "$($script:cfg).pre-gitconfig" -Raw) | Should -Match "precious = status"
    }
}

Describe "Initialize-Symlinks.ps1 backs up before linking (finding 16)" -Tag 'Unit' -Skip:(-not $canSymlink) {
    # Runs the real script in a child pwsh with a sandboxed USERPROFILE and
    # Read-Host stubbed. Needs real symlinks (see the probe in BeforeDiscovery).

    BeforeAll {
        $script:symlinksScript = Join-Path $script:winDir "Initialize-Symlinks.ps1"
        function Invoke-Symlinks([string]$HomeDir, [string]$Answer, [switch]$Force) {
            $f = if ($Force) { '-Force' } else { '' }
            $cmd = @"
function Read-Host { param([string]`$Prompt) if (`$Prompt -like '*scheduled task*') { 'n' } else { '$Answer' } }
`$env:USERPROFILE = '$HomeDir'; `$env:HOME = '$HomeDir'
`$env:GIT_CONFIG_GLOBAL = '$HomeDir/.gitconfig'; `$env:GIT_CONFIG_SYSTEM = '$HomeDir/none'
& '$script:symlinksScript' $f
"@
            & $script:pwshPath -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        }
    }

    BeforeEach {
        $script:sbHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sbHome | Out-Null
    }

    It "moves a real ~/.gitignore_global to a timestamped backup instead of deleting it" {
        $gi = Join-Path $script:sbHome ".gitignore_global"
        Set-Content -LiteralPath $gi -Value "MY-OWN-IGNORES"
        $null = Invoke-Symlinks -HomeDir $script:sbHome -Force
        (Get-Item -LiteralPath $gi -Force).LinkType | Should -Be "SymbolicLink"
        $backups = Get-Backups $gi
        $backups.Count | Should -Be 1
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should -Match "MY-OWN-IGNORES"
    }

    It "leaves the file alone when the user declines the overwrite prompt" {
        $gi = Join-Path $script:sbHome ".gitignore_global"
        Set-Content -LiteralPath $gi -Value "MY-OWN-IGNORES"
        $null = Invoke-Symlinks -HomeDir $script:sbHome -Answer 'n'
        (Get-Item -LiteralPath $gi -Force).LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $gi -Raw) | Should -Match "MY-OWN-IGNORES"
        (Get-Backups $gi).Count | Should -Be 0
    }

    It "re-running does not back up links that already point into the repo" {
        $null = Invoke-Symlinks -HomeDir $script:sbHome -Force
        $out = Invoke-Symlinks -HomeDir $script:sbHome -Answer 'n'
        $out | Should -Match "Already linked"
        (Get-Backups (Join-Path $script:sbHome ".gitignore_global")).Count | Should -Be 0
        (Get-Backups (Join-Path $script:sbHome "gitconfig_helper.py")).Count | Should -Be 0
    }
}

Describe "Initialize-Symlinks.ps1 keeps the existing file when linking fails (#255)" -Tag 'Unit' {
    # Runs the real script -Force in a child process with a sandboxed
    # USERPROFILE, Read-Host stubbed, and New-Item or Move-Item shimmed to fail
    # the way they do on Windows without admin or Developer Mode. The first
    # test never creates a symlink, so it runs everywhere; the others need
    # real symlinks and skip without them (see the probe in BeforeDiscovery).

    BeforeAll {
        $script:symlinksScript = Join-Path $script:winDir "Initialize-Symlinks.ps1"

        # New-Item that refuses symlinks with a non-terminating error, like
        # the real one without the privilege. Everything else passes through.
        $script:failNewItemShim = @'
function New-Item {
    [CmdletBinding()]
    param([string]$ItemType, [string]$Path, [object]$Target, [object]$Value, [switch]$Force)
    if ($ItemType -eq 'SymbolicLink') { Write-Error 'Administrator privilege required for this operation.'; return }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
'@
        # Move-Item that fails only for the script's temporary link, so the
        # swap fails after the existing file has been moved to its backup.
        $script:failSwapShim = @'
function Move-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($LiteralPath -like '*.tmp-*') { Write-Error 'The process cannot access the file because it is being used by another process.'; return }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
'@

        function Invoke-SymlinksWithShim([string]$HomeDir, [string]$Shim) {
            $cmd = @"
function Read-Host { param([string]`$Prompt) 'n' }
$Shim
`$env:USERPROFILE = '$HomeDir'; `$env:HOME = '$HomeDir'
`$env:GIT_CONFIG_GLOBAL = '$HomeDir/.gitconfig'; `$env:GIT_CONFIG_SYSTEM = '$HomeDir/none'
& '$script:symlinksScript' -Force
exit `$LASTEXITCODE
"@
            $out = & $script:pwshPath -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        # Anything the script left under a temporary name.
        function Get-TempLinks([string]$HomeDir) {
            @(Get-ChildItem -LiteralPath $HomeDir -Force | Where-Object { $_.Name -match '\.tmp-[0-9a-f]{8}$' })
        }
    }

    BeforeEach {
        $script:sbHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sbHome | Out-Null
        $script:gi = Join-Path $script:sbHome ".gitignore_global"
    }

    It "leaves a real file in place, takes no backup, and exits 1 when the link can't be made" {
        Set-Content -LiteralPath $script:gi -Value "MY-OWN-IGNORES"
        $r = Invoke-SymlinksWithShim -HomeDir $script:sbHome -Shim $script:failNewItemShim

        $item = Get-Item -LiteralPath $script:gi -Force
        $item.LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:gi -Raw) | Should -Match "MY-OWN-IGNORES"
        (Get-Backups $script:gi).Count | Should -Be 0
        (Get-TempLinks $script:sbHome).Count | Should -Be 0
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[FAIL\] Failed to create symlink'
        $r.Output | Should -Not -Match 'Created symlink'
        $r.Output | Should -Not -Match 'now symlinked'
    }

    It "keeps an old link into the repo when the new link can't be made" -Skip:(-not $canSymlink) {
        $oldTarget = Join-Path $script:repoRoot "README.md"
        New-Item -ItemType SymbolicLink -Path $script:gi -Target $oldTarget | Out-Null
        $r = Invoke-SymlinksWithShim -HomeDir $script:sbHome -Shim $script:failNewItemShim

        Test-LinkPointsTo -Path $script:gi -Target $oldTarget | Should -BeTrue
        (Get-TempLinks $script:sbHome).Count | Should -Be 0
        $r.ExitCode | Should -Be 1
    }

    It "restores the backup when the new link can't be swapped in" -Skip:(-not $canSymlink) {
        Set-Content -LiteralPath $script:gi -Value "MY-OWN-IGNORES"
        $r = Invoke-SymlinksWithShim -HomeDir $script:sbHome -Shim $script:failSwapShim

        $item = Get-Item -LiteralPath $script:gi -Force
        $item.LinkType | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:gi -Raw) | Should -Match "MY-OWN-IGNORES"
        (Get-Backups $script:gi).Count | Should -Be 0
        (Get-TempLinks $script:sbHome).Count | Should -Be 0
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Restored the existing \.gitignore_global'
    }

    It "links both files, leaves nothing temporary behind, and exits 0 when linking works" -Skip:(-not $canSymlink) {
        Set-Content -LiteralPath $script:gi -Value "MY-OWN-IGNORES"
        $r = Invoke-SymlinksWithShim -HomeDir $script:sbHome -Shim ''

        Test-LinkPointsTo -Path $script:gi -Target (Join-Path $script:repoRoot ".gitignore_global") | Should -BeTrue
        Test-LinkPointsTo -Path (Join-Path $script:sbHome "gitconfig_helper.py") -Target (Join-Path $script:repoRoot "gitconfig_helper.py") | Should -BeTrue
        (Get-Backups $script:gi).Count | Should -Be 1
        (Get-TempLinks $script:sbHome).Count | Should -Be 0
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'now symlinked'
    }
}

Describe "Elevated relaunch keeps the caller's switches" -Tag 'Unit' {
    # Get-RelaunchArgs stubs the elevation check, so these run elevated too.

    It "Cleanup-GitConfig.ps1 passes -KeepLocal through (finding 25)" {
        $relaunch = Get-RelaunchArgs -Script (Join-Path $script:winDir "Cleanup-GitConfig.ps1") -ScriptArgs @('-Force', '-KeepLocal')
        $relaunch | Should -Match '(^| )-KeepLocal( |$)'
        $relaunch | Should -Match '(^| )-Force( |$)'
    }

    It "Cleanup-GitConfig.ps1 does not add -KeepLocal when it was not given" {
        $relaunch = Get-RelaunchArgs -Script (Join-Path $script:winDir "Cleanup-GitConfig.ps1") -ScriptArgs @('-Force')
        $relaunch | Should -Not -Match '-KeepLocal'
    }

    It "install.ps1 passes -Reinstall through" {
        $relaunch = Get-RelaunchArgs -Script (Join-Path $script:winDir "install.ps1") -ScriptArgs @('-Reinstall', '-NoTask')
        $relaunch | Should -Match '(^| )-Reinstall( |$)'
        $relaunch | Should -Match '(^| )-NoTask( |$)'
    }

    It "Cleanup-GitConfig.ps1 passes -KeepTask through (#240)" {
        $relaunch = Get-RelaunchArgs -Script (Join-Path $script:winDir "Cleanup-GitConfig.ps1") -ScriptArgs @('-Force', '-KeepTask')
        $relaunch | Should -Match '(^| )-KeepTask( |$)'
    }
}

Describe "Elevated relaunch hands over the invoking user and the result (#240)" -Tag 'Unit' {
    # Over-the-shoulder UAC runs the elevated copy as the administrator, so the
    # relaunch tells it who started it. The parent waits for the elevated window
    # and exits with its exit code.

    It "<Name> passes the invoking user and profile, and -Elevated instead of -NoExit" -ForEach @(
        @{ Name = "install.ps1" }, @{ Name = "Cleanup-GitConfig.ps1" }
    ) {
        $r = Invoke-Relaunch -Script (Join-Path $script:winDir $Name) -ScriptArgs @('-Force')
        $r.Args | Should -Match '(^| )-InvokingUser "CORP\\alice"( |$)'
        $r.Args | Should -Match ('(^| )-InvokingUserProfile "' + [regex]::Escape($r.Home) + '"( |$)')
        $r.Args | Should -Match '(^| )-Elevated( |$)'
        # -NoExit kept the window open after the script, so the exit code never
        # reached the parent.
        $r.Args | Should -Not -Match '-NoExit'
    }

    It "<Name> exits with the elevated run's exit code (<Code>)" -ForEach @(
        @{ Name = "install.ps1"; Code = 1 }, @{ Name = "install.ps1"; Code = 0 },
        @{ Name = "Cleanup-GitConfig.ps1"; Code = 1 }, @{ Name = "Cleanup-GitConfig.ps1"; Code = 0 }
    ) {
        $r = Invoke-Relaunch -Script (Join-Path $script:winDir $Name) -ScriptArgs @('-Force') -ChildExitCode $Code
        $r.Args | Should -Not -BeNullOrEmpty
        $r.ExitCode | Should -Be $Code
    }
}

Describe "install.ps1 structure" -Tag 'Unit' {
    # install.ps1 needs elevation and Windows to run, so these inspect its
    # syntax tree rather than run it.

    BeforeAll {
        $installPath = Join-Path $script:winDir "install.ps1"
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$null, [ref]$null)
    }

    It "runs the cleanup script only inside 'if (`$Reinstall)'" {
        $calls = $script:ast.FindAll({
                param($n)
                # "& $cleanupScript ..." or "Invoke-Step -Path $cleanupScript ..."
                $n -is [System.Management.Automation.Language.CommandAst] -and
                ($n.CommandElements | Where-Object { $_.Extent.Text -eq '$cleanupScript' })
            }, $true)
        @($calls).Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $p = $call.Parent
            $guarded = $false
            while ($p) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst] -and
                    ($p.Clauses | Where-Object { $_.Item1.Extent.Text -eq '$Reinstall' })) { $guarded = $true; break }
                $p = $p.Parent
            }
            $guarded | Should -BeTrue
        }
    }

    It "no longer writes core.excludesfile with git config --global (finding 13)" {
        $writes = $script:ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'git' -and
                $n.Extent.Text -match 'core\.excludesfile'
            }, $true)
        @($writes).Count | Should -Be 0
    }
}
