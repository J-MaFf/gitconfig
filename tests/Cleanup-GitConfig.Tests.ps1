BeforeDiscovery {
    # Symlink tests run wherever a symlink can be made: Linux/macOS, or Windows
    # with admin or Developer Mode (the CI runners).
    $script:canSymlink = $false
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $probeDir -ErrorAction Stop | Out-Null
        # Windows PowerShell 5.1 won't link to a missing target, so link to a
        # real file (the test deletes it afterwards to leave a dangling link).
        $probeTarget = Join-Path $probeDir 'target'
        [System.IO.File]::WriteAllText($probeTarget, 'x')
        New-Item -ItemType SymbolicLink -Path (Join-Path $probeDir 'link') -Target $probeTarget -ErrorAction Stop | Out-Null
        $script:canSymlink = $true
    }
    catch { $script:canSymlink = $false }
    finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path (Join-Path (Join-Path $repoRoot "scripts") "windows version") "Cleanup-GitConfig.ps1"
    $script:pwshPath = (Get-Process -Id $PID).Path
    $script:managedFiles = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py")
    $script:beginMarker = "# >>> gitconfig git-alias browser (Ctrl-G) >>>"
    $script:endMarker = "# <<< gitconfig git-alias browser <<<"

    # Run the real Cleanup-GitConfig.ps1 in a child PowerShell of the same
    # edition: the elevation check stubbed to "admin", Read-Host logging its
    # prompt and answering -Answer, USERPROFILE/HOME, the git config and
    # $PROFILE sandboxed, the Documents folder holding both editions' profiles
    # passed as -InvokingDocuments (otherwise the script would use the real
    # MyDocuments), and the ScheduledTasks cmdlets replaced by functions that
    # log their calls. The task "exists" while a marker file does.
    # -EncodedCommand, because Windows PowerShell 5.1 strips double quotes
    # inside a native command's argument.
    function New-CleanupSandbox {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sandboxHome = Join-Path $root "home"
        New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null
        $sb = [pscustomobject]@{
            Root      = $root
            Home      = $sandboxHome
            Profile   = Join-Path (Join-Path $root "profile") "profile.ps1"
            Documents = Join-Path $root "Documents"
            PromptLog = Join-Path $root "prompts.txt"
            GitConfig = Join-Path $root "global.gitconfig"
            TaskFile  = Join-Path $root "task-exists"
            TaskCalls = Join-Path $root "task-calls.txt"
        }
        Set-Content -LiteralPath $sb.GitConfig -Value "[user]`n`tname = Sandbox"
        $sb
    }

    function Invoke-Cleanup {
        param($Sandbox, [string[]]$ScriptArgs = @('-Force'), [string]$Answer = 'n', [switch]$TaskExists)
        $sb = $Sandbox
        $ScriptArgs = @($ScriptArgs) + @('-InvokingDocuments', "`"$($sb.Documents)`"")
        if ($TaskExists) { Set-Content -LiteralPath $sb.TaskFile -Value "" }
        $cmd = @"
function Test-AsAdministrator { `$true }
Set-Alias -Name Test-IsAdministrator -Value Test-AsAdministrator
function Read-Host { param([string]`$Prompt) Add-Content -LiteralPath '$($sb.PromptLog)' -Value `$Prompt; '$Answer' }
function Get-ScheduledTask { param([string]`$TaskName, `$ErrorAction) Add-Content -LiteralPath '$($sb.TaskCalls)' -Value "Get `$TaskName"; if (Test-Path '$($sb.TaskFile)') { [pscustomobject]@{ TaskName = `$TaskName } } }
function Unregister-ScheduledTask { param([string]`$TaskName, [switch]`$Confirm) Add-Content -LiteralPath '$($sb.TaskCalls)' -Value "Unregister `$TaskName"; Remove-Item -LiteralPath '$($sb.TaskFile)' }
`$env:USERPROFILE = '$($sb.Home)'; `$env:HOME = '$($sb.Home)'
`$env:GIT_CONFIG_GLOBAL = '$($sb.GitConfig)'; `$env:GIT_CONFIG_SYSTEM = '$($sb.GitConfig).none'
`$global:PROFILE = [pscustomobject]@{ CurrentUserAllHosts = '$($sb.Profile)' }
& '$scriptPath' $($ScriptArgs -join ' ')
exit `$LASTEXITCODE
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
        $out = & {
            $ErrorActionPreference = 'Continue'
            & $script:pwshPath -NoProfile -NonInteractive -EncodedCommand $encoded *>&1 | Out-String
        }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode  = $code
            Output    = $out
            Prompts   = if (Test-Path $sb.PromptLog) { @(Get-Content -LiteralPath $sb.PromptLog) } else { @() }
            TaskCalls = if (Test-Path $sb.TaskCalls) { @(Get-Content -LiteralPath $sb.TaskCalls) } else { @() }
        }
    }

    # Put each named file in the sandbox home with content naming the file.
    function Add-HomeFile($Sandbox, [string[]]$Name) {
        foreach ($n in $Name) { Set-Content -LiteralPath (Join-Path $Sandbox.Home $n) -Value "original $n" }
    }

    # The Ctrl-G profile scripts of both editions under the sandbox Documents.
    function Get-EditionProfile($Sandbox) {
        foreach ($edition in 'WindowsPowerShell', 'PowerShell') { Join-Path (Join-Path $Sandbox.Documents $edition) "profile.ps1" }
    }

    # The timestamped backups of Name left in the sandbox home.
    function Get-Backup($Sandbox, [string]$Name) {
        @(Get-ChildItem -LiteralPath $Sandbox.Home -Force -Filter "$Name.bak.*")
    }
}

Describe "Cleanup-GitConfig.ps1 (#233)" -Tag 'Unit' {
    # Behavioural: every test runs the real script in a child PowerShell
    # against a sandboxed home, git config, profile and scheduled task.

    Context "-Help" {
        BeforeAll {
            # -Help prints via Write-Host and exits before the elevation check.
            $script:helpText = & $scriptPath -Help 6>&1 | Out-String
        }

        It "names the scheduled task the script actually unregisters" {
            $sb = New-CleanupSandbox
            $r = Invoke-Cleanup -Sandbox $sb -TaskExists
            $unregistered = @($r.TaskCalls | Where-Object { $_ -like 'Unregister *' })
            $unregistered.Count | Should -Be 1
            $taskName = $unregistered[0].Substring('Unregister '.Length)
            $script:helpText | Should -Match ([regex]::Escape("`"$taskName`""))
        }

        It "does not list a signing-config step, and cleanup leaves signing config alone" {
            # The help used to claim a 'Clears git SSH signing config' step.
            $script:helpText | Should -Not -Match '(?i)signing'
            $sb = New-CleanupSandbox
            Add-Content -LiteralPath $sb.GitConfig -Value "`tsigningkey = ~/.ssh/key.pub`n[gpg]`n`tformat = ssh"
            $before = Get-Content -LiteralPath $sb.GitConfig -Raw
            Invoke-Cleanup -Sandbox $sb | Out-Null
            Get-Content -LiteralPath $sb.GitConfig -Raw | Should -Be $before
        }
    }

    Context "-Force on a configured home" {
        BeforeAll {
            $script:sb = New-CleanupSandbox
            Add-HomeFile $script:sb ($script:managedFiles + ".gitconfig.local")
            foreach ($p in Get-EditionProfile $script:sb) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
                Set-Content -LiteralPath $p -Value "# mine`n$script:beginMarker`n. 'widget.ps1'`n$script:endMarker`nSet-Alias g git"
            }
            $script:r = Invoke-Cleanup -Sandbox $script:sb -TaskExists
        }

        It "does not prompt, reports success and exits 0" {
            $script:r.Prompts | Should -BeNullOrEmpty
            $script:r.Output | Should -Match 'Cleanup SUCCESSFUL'
            $script:r.ExitCode | Should -Be 0
        }

        It "moves <_> to one timestamped backup holding the original content" -ForEach @(".gitconfig", ".gitignore_global", "gitconfig_helper.py") {
            Join-Path $script:sb.Home $_ | Should -Not -Exist
            $backups = Get-Backup $script:sb $_
            $backups.Count | Should -Be 1
            $backups[0].Name | Should -Match ('^' + [regex]::Escape($_) + '\.bak\.\d{8}-\d{6}$')
            (Get-Content -LiteralPath $backups[0].FullName -Raw).Trim() | Should -Be "original $_"
            $script:r.Output | Should -Match ([regex]::Escape("[OK] Backed up $_ to $($backups[0].Name)"))
        }

        It "leaves no old-style Existing.* backups" {
            Get-ChildItem -LiteralPath $script:sb.Home -Force -Filter "Existing.*" | Should -BeNullOrEmpty
        }

        It "moves .gitconfig.local to a backup" {
            Join-Path $script:sb.Home ".gitconfig.local" | Should -Not -Exist
            (Get-Backup $script:sb ".gitconfig.local").Count | Should -Be 1
            $script:r.Output | Should -Match '\[OK\] \.gitconfig\.local removed'
            $script:r.Output | Should -Not -Match 'Preserving \.gitconfig\.local'
        }

        It "removes the scheduled task" {
            $script:r.TaskCalls | Should -Contain 'Unregister GitConfig Pull at Login'
            $script:sb.TaskFile | Should -Not -Exist
        }

        It "removes the Ctrl-G block from both editions' profiles and keeps the user's lines" {
            foreach ($p in Get-EditionProfile $script:sb) {
                $content = Get-Content -LiteralPath $p -Raw
                $content | Should -Not -Match ([regex]::Escape($script:beginMarker))
                $content | Should -Not -Match 'widget\.ps1'
                $content | Should -Match '# mine'
                $content | Should -Match 'Set-Alias g git'
            }
        }
    }

    Context "-KeepLocal" {
        It "preserves .gitconfig.local and still removes the managed files" {
            $sb = New-CleanupSandbox
            Add-HomeFile $sb ($script:managedFiles + ".gitconfig.local")
            $local = Join-Path $sb.Home ".gitconfig.local"
            $r = Invoke-Cleanup -Sandbox $sb -ScriptArgs @('-Force', '-KeepLocal')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match '\[SKIP\] Preserving \.gitconfig\.local \(-KeepLocal\)'
            $r.Output | Should -Match '\[OK\] \.gitconfig\.local preserved \(-KeepLocal\)'
            (Get-Content -LiteralPath $local -Raw).Trim() | Should -Be "original .gitconfig.local"
            Get-Backup $sb ".gitconfig.local" | Should -BeNullOrEmpty
            foreach ($f in $script:managedFiles) { Join-Path $sb.Home $f | Should -Not -Exist }
        }
    }

    Context "symlinks into the repo" {
        It "removes a link into the repo without a backup and leaves the repo file" -Skip:(-not $canSymlink) {
            $sb = New-CleanupSandbox
            $target = Join-Path $repoRoot ".gitignore_global"
            $before = Get-Content -LiteralPath $target -Raw
            New-Item -ItemType SymbolicLink -Path (Join-Path $sb.Home ".gitignore_global") -Target $target | Out-Null
            $r = Invoke-Cleanup -Sandbox $sb
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match ([regex]::Escape("[OK] Removed .gitignore_global (symlink into the repo; no backup needed)"))
            Get-Item -LiteralPath (Join-Path $sb.Home ".gitignore_global") -Force -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Backup $sb ".gitignore_global" | Should -BeNullOrEmpty
            Get-Content -LiteralPath $target -Raw | Should -Be $before
        }
    }

    Context "without -Force" {
        It "asks first, and declining leaves everything in place and exits 0" {
            $sb = New-CleanupSandbox
            Add-HomeFile $sb $script:managedFiles
            $r = Invoke-Cleanup -Sandbox $sb -ScriptArgs @() -Answer 'n' -TaskExists
            $r.Prompts | Should -Contain 'Continue? (y/n)'
            $r.Output | Should -Match 'Cancelled\.'
            $r.ExitCode | Should -Be 0
            foreach ($f in $script:managedFiles) { Join-Path $sb.Home $f | Should -Exist }
            $r.TaskCalls | Should -BeNullOrEmpty
            $sb.TaskFile | Should -Exist
        }

        It "goes ahead when the answer is y" {
            $sb = New-CleanupSandbox
            Add-HomeFile $sb $script:managedFiles
            $r = Invoke-Cleanup -Sandbox $sb -ScriptArgs @() -Answer 'y'
            $r.Output | Should -Match 'Cleanup SUCCESSFUL'
            foreach ($f in $script:managedFiles) { Join-Path $sb.Home $f | Should -Not -Exist }
        }
    }
}

Describe "Cleanup-GitConfig.ps1 profile and verification steps (#255)" -Tag 'Unit' {
    # The script needs elevation (Windows) before it gets to these steps, so
    # each test runs the real step's code, taken from the script's syntax tree,
    # against a sandboxed profile or home directory.

    BeforeAll {
        $script:cleanupPath = Join-Path $repoRoot "scripts\windows version\Cleanup-GitConfig.ps1"
        $script:functionsPath = Join-Path $repoRoot "scripts\windows version\Functions.ps1"
        $script:cleanupAst = [System.Management.Automation.Language.Parser]::ParseFile($script:cleanupPath, [ref]$null, [ref]$null)
        $script:begin = "# >>> gitconfig git-alias browser (Ctrl-G) >>>"
        $script:end = "# <<< gitconfig git-alias browser <<<"

        # The text of the first statement in the script of the given AST type
        # whose text matches Pattern.
        function Get-StepText([type]$Type, [string]$Pattern) {
            $node = $script:cleanupAst.FindAll({ param($n) $n -is $Type -and $n.Extent.Text -match $Pattern }, $true) |
                Select-Object -First 1
            $node | Should -Not -BeNullOrEmpty
            $node.Extent.Text
        }

        # Run STEP 2b for the Documents folder holding ProfilePath
        # (<Documents>\<edition>\profile.ps1). Returns the $removed count.
        function Invoke-ProfileStep([string]$ProfilePath) {
            $step = Get-StepText ([System.Management.Automation.Language.TryStatementAst]) 'Remove-MarkedBlock'
            & {
                $removed = 0
                $cleanupUser = [pscustomobject]@{ Documents = (Split-Path -Parent (Split-Path -Parent $ProfilePath)) }
                . $script:functionsPath
                . ([scriptblock]::Create($step)) 6>$null
                $removed
            }
        }

        # Latin-1 maps bytes 0-255 to chars 0-255, so a test can spell exact
        # bytes as a string.
        $script:latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $script:utf8 = New-Object System.Text.UTF8Encoding($false)
        # Non-ASCII text a profile might hold, spelled with char codes so this
        # file stays ASCII: e-acute, a Nerd Font powerline glyph, an emoji.
        $script:fancy = "Write-Host 'caf" + [char]0xE9 + " " + [char]0xE0B0 + " " + [char]::ConvertFromUtf32(0x1F600) + "'"

        function New-ProfileBytes([System.Text.Encoding]$Encoding, [byte[]]$Bom, [string]$Text) {
            [byte[]]($Bom + $Encoding.GetBytes($Text))
        }
    }

    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        # A Documents folder: STEP 2b cleans both editions' profiles under it.
        New-Item -ItemType Directory -Path (Join-Path $script:dir "WindowsPowerShell") | Out-Null
        $script:profilePath = Join-Path (Join-Path $script:dir "WindowsPowerShell") "profile.ps1"
        $script:pwshProfilePath = Join-Path (Join-Path $script:dir "PowerShell") "profile.ps1"
    }

    Context "STEP 2b keeps the profile's bytes" {

        It "keeps a UTF-8 BOM, CRLF endings and non-ASCII characters" {
            $nl = "`r`n"
            $before = "# mine$nl$script:fancy$nl"
            $block = "$nl$script:begin$nl. 'widget.ps1'$nl$script:end$nl"
            $after = "Set-Alias g git$nl"
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            [System.IO.File]::WriteAllBytes($script:profilePath, (New-ProfileBytes $script:utf8 $bom ($before + $block + $after)))

            Invoke-ProfileStep $script:profilePath

            $expected = New-ProfileBytes $script:utf8 $bom ($before + $nl + $after)
            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be $expected
        }

        It "keeps BOM-less UTF-8 with LF endings" {
            $before = "# mine`n$script:fancy`n"
            $after = "Set-Alias g git"
            [System.IO.File]::WriteAllBytes($script:profilePath, $script:utf8.GetBytes("$before$script:begin`n. 'w.ps1'`n$script:end`n$after"))

            Invoke-ProfileStep $script:profilePath

            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be $script:utf8.GetBytes("$before$after")
        }

        It "keeps a UTF-16 LE profile (what Windows PowerShell's '>' writes)" {
            $enc = New-Object System.Text.UnicodeEncoding($false, $false)
            $bom = [byte[]](0xFF, 0xFE)
            $before = "# mine`r`n$script:fancy`r`n"
            [System.IO.File]::WriteAllBytes($script:profilePath, (New-ProfileBytes $enc $bom "$before$script:begin`r`n. 'w.ps1'`r`n$script:end`r`n"))

            Invoke-ProfileStep $script:profilePath

            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be (New-ProfileBytes $enc $bom $before)
        }

        It "keeps ANSI bytes that are not valid UTF-8" {
            # 0xE9 alone is e-acute in Windows-1252 and invalid as UTF-8.
            $before = "# caf" + [char]0xE9 + "`r`n"
            [System.IO.File]::WriteAllBytes($script:profilePath, $script:latin1.GetBytes("$before$script:begin`r`n. 'w.ps1'`r`n$script:end`r`n"))

            Invoke-ProfileStep $script:profilePath

            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be $script:latin1.GetBytes($before)
        }

        It "does not rewrite a profile without the block" {
            $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $script:utf8.GetBytes("# mine`r`n$script:fancy")
            [System.IO.File]::WriteAllBytes($script:profilePath, $bytes)
            $stamp = [datetime]'2001-02-03'
            (Get-Item -LiteralPath $script:profilePath).LastWriteTime = $stamp

            Invoke-ProfileStep $script:profilePath

            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be $bytes
            (Get-Item -LiteralPath $script:profilePath).LastWriteTime | Should -Be $stamp
        }

        It "leaves the profile alone when the end marker is missing" {
            # Removing to the end of the file would take the user's own lines.
            $bytes = $script:utf8.GetBytes("# mine`n$script:begin`n. 'w.ps1'`n# user line after`n")
            [System.IO.File]::WriteAllBytes($script:profilePath, $bytes)

            Invoke-ProfileStep $script:profilePath

            [System.IO.File]::ReadAllBytes($script:profilePath) | Should -Be $bytes
        }

        It "does nothing when there is no profile" {
            Invoke-ProfileStep $script:profilePath | Should -Be 0
            $script:profilePath | Should -Not -Exist
            $script:pwshProfilePath | Should -Not -Exist
        }

        It "removes the block from the PowerShell 7 profile too (#230)" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:pwshProfilePath) | Out-Null
            foreach ($p in $script:profilePath, $script:pwshProfilePath) {
                [System.IO.File]::WriteAllBytes($p, $script:utf8.GetBytes("# mine`n$script:begin`n. 'w.ps1'`n$script:end`n"))
            }

            Invoke-ProfileStep $script:profilePath | Should -Be 2

            foreach ($p in $script:profilePath, $script:pwshProfilePath) {
                [System.IO.File]::ReadAllBytes($p) | Should -Be $script:utf8.GetBytes("# mine`n")
            }
        }
    }

    Context "STEP 4 verification" {

        It "never uses Test-Path, which can miss a dangling link" {
            $text = $script:cleanupAst.Extent.Text
            $start = $text.IndexOf('[STEP 4]')
            $stop = $text.IndexOf('[SUMMARY]')
            $start | Should -BeGreaterThan 0
            $stop | Should -BeGreaterThan $start
            $calls = $script:cleanupAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Test-Path' -and
                    $n.Extent.StartOffset -gt $start -and $n.Extent.StartOffset -lt $stop
                }, $true)
            @($calls).Count | Should -Be 0
        }

        It "reports a dangling link that is still there" -Skip:(-not $canSymlink) {
            $homeDir = $script:dir
            # Link to a real file, then delete it: Windows PowerShell 5.1 won't
            # create a link to a missing target.
            $target = Join-Path $homeDir "gone"
            [System.IO.File]::WriteAllText($target, 'x')
            New-Item -ItemType SymbolicLink -Path (Join-Path $homeDir ".gitignore_global") -Target $target | Out-Null
            Remove-Item -LiteralPath $target -Force
            $step = Get-StepText ([System.Management.Automation.Language.ForEachStatementAst]) 'still exists'
            $verifyErrors = & {
                $filesToRemove = @(".gitconfig", ".gitignore_global", "gitconfig_helper.py")
                $verifyErrors = 0
                . $script:functionsPath
                . ([scriptblock]::Create($step)) 6>$null
                $verifyErrors
            }
            $verifyErrors | Should -Be 1
        }
    }
}
