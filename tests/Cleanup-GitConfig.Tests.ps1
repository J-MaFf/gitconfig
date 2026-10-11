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
    # Import the script
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot "scripts\windows version\Cleanup-GitConfig.ps1"

    # Test variables
    $testHome = $env:USERPROFILE
    $testRepo = $repoRoot
}

Describe "Cleanup-GitConfig.ps1" {

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$Force'
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$Help'
        }

        It "Should accept -KeepLocal parameter" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '\[switch\]\s*\$KeepLocal'
        }
    }

    Context "Help text" {
        BeforeAll {
            # -Help prints via Write-Host (information stream 6) and exits before
            # the elevation check, so it is safe to run on any platform.
            $script:helpText = & $scriptPath -Help 6>&1 | Out-String
        }

        It "Should name the scheduled task it actually removes" {
            $taskName = [regex]::Match((Get-Content $scriptPath -Raw), '\$taskName\s*=\s*"([^"]+)"').Groups[1].Value
            $taskName | Should -Not -BeNullOrEmpty
            $script:helpText | Should -Match ([regex]::Escape("`"$taskName`""))
        }

        It "Should not list a signing-config step the script does not perform" {
            # The script never touches user.signingkey / gpg.*; the help used to
            # claim a 'Clears git SSH signing config' step.
            $script:helpText | Should -Not -Match '(?i)signing'
            Get-Content $scriptPath -Raw | Should -Not -Match '(?i)--unset[^\r\n]*(signingkey|gpg\.)'
        }
    }

    Context "Preserve machine-specific config" {
        It "Should skip removing .gitconfig.local when -KeepLocal is set" {
            $scriptContent = Get-Content $scriptPath -Raw
            # Guard branch present: -KeepLocal short-circuits the removal step.
            $scriptContent | Should -Match 'if \(\$KeepLocal\)'
            $scriptContent | Should -Match 'Preserving \.gitconfig\.local'
        }
    }

    Context "Script Functionality" {
        It "Should be executable PowerShell script" {
            $scriptPath | Should -Exist
        }

        It "Should contain cleanup logic" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Backup-UserFile'
            $scriptContent | Should -Match 'ScheduledTask'
        }

        It "Should move files to timestamped backups, skipping links into the repo" {
            # Behaviour of Backup-UserFile is covered in Backups.Tests.ps1.
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Backup-UserFile -Path \$Path -Move -RepoRoot \$repoRoot'
            $scriptContent | Should -Not -Match 'Existing\.'
        }
    }

    Context "Verification" {
        It "Should have self-verification after cleanup" {
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match 'Cleanup SUCCESSFUL'
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
