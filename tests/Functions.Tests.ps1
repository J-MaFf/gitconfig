BeforeDiscovery {
    # -Skip is evaluated at discovery time, so the platform flag must be
    # computed here, not in BeforeAll.
    $script:platformIsWindows = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:functionsPath = Join-Path $script:repoRoot "scripts\windows version\Functions.ps1"
}

Describe "Functions.ps1" -Tag 'Unit' {

    Context "Script Validation" {
        It "Should exist" {
            $script:functionsPath | Should -Exist
        }

        It "Should be a valid PowerShell script" {
            # PSParser::Tokenize never throws on syntax errors (it reports them
            # via the discarded [ref] parameter), so a Should -Not -Throw around
            # it is vacuous (#201). Capture and count parse errors instead.
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script:functionsPath, [ref]$null, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
        }
    }

    Context "Resolve-Python probe" {

        It "probes candidates with a non-empty -c argument" {
            # Regression for #197: Windows PowerShell 5.1 silently drops
            # empty-string arguments to native commands, so a probe of
            # `& $cand -c ''` ran as `py -c` (exit 2) and rejected every
            # working interpreter when the login task ran under 5.1.
            # Anchor to line starts so comments mentioning the old probe
            # don't count as code.
            $content = Get-Content $script:functionsPath -Raw
            $content | Should -Not -Match "(?m)^\s*(\`$null\s*=\s*)?&\s+\`$cand\s+-c\s+''"
            $content | Should -Match "(?m)^\s*(\`$null\s*=\s*)?&\s+\`$cand\s+-c\s+'pass'"
        }

        It "accepts a working interpreter that requires the -c argument to be present" -Skip:(-not $platformIsWindows) {
            # Behavioral check: a fake candidate that fails when -c has no
            # following argument (as real python.exe does). The old empty-string
            # probe fails this in BOTH hosts: 5.1 drops '' entirely, and under
            # pwsh 7 the empty arg reaches cmd as "" which %~2 unquotes to
            # nothing. The non-empty probe resolves it in both.
            $fakeDir = Join-Path $TestDrive "fake-python"
            New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
            @(
                '@echo off'
                'if "%~2"=="" exit /b 2'
                'exit /b 0'
            ) | Set-Content -Path (Join-Path $fakeDir "python.cmd") -Encoding ascii

            $oldPath = $env:Path
            $oldLocalAppData = $env:LOCALAPPDATA
            try {
                # Restrict discovery to the fake candidate: PATH holds only the
                # fake, and LOCALAPPDATA points somewhere empty so neither the
                # WindowsApps stubs nor the real launcher fallbacks exist.
                $env:Path = $fakeDir
                $env:LOCALAPPDATA = Join-Path $TestDrive "empty-localappdata"

                # Dot-source inside the try so Resolve-Python sees the fake env.
                . $script:functionsPath
                $resolved = Resolve-Python

                $resolved | Should -Be (Join-Path $fakeDir "python.cmd")
            }
            finally {
                $env:Path = $oldPath
                $env:LOCALAPPDATA = $oldLocalAppData
            }
        }

        It "prefers a real interpreter over a WindowsApps stub found alongside it" -Skip:(-not $platformIsWindows) {
            # Regression for #199: stubs are set aside and probed LAST as a
            # Store-only fallback, not skipped outright - a stub found
            # alongside a real interpreter must not win just because it was
            # discovered first. A genuine app-execution-alias reparse point
            # can't be fabricated in a test fixture (it's an OS-level MSIX
            # registration), so this uses an intentionally-broken 0-byte file
            # at a path shaped like the real one - if the real candidate is
            # returned, the broken stub was never allowed to win, regardless
            # of whether it was even probed.
            $realDir = Join-Path $TestDrive "real-python"
            New-Item -ItemType Directory -Force -Path $realDir | Out-Null
            @('@echo off', 'exit /b 0') | Set-Content -Path (Join-Path $realDir "python.cmd") -Encoding ascii

            $stubDir = Join-Path $TestDrive "stub\Microsoft\WindowsApps"
            New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $stubDir "python.exe") -Force | Out-Null

            $oldPath = $env:Path
            $oldLocalAppData = $env:LOCALAPPDATA
            try {
                # Stub dir listed FIRST on PATH so Get-Command would return it
                # before the real one if ordering were not enforced correctly.
                $env:Path = "$stubDir;$realDir"
                $env:LOCALAPPDATA = Join-Path $TestDrive "empty-localappdata-2"

                . $script:functionsPath
                $resolved = Resolve-Python

                $resolved | Should -Be (Join-Path $realDir "python.cmd")
            }
            finally {
                $env:Path = $oldPath
                $env:LOCALAPPDATA = $oldLocalAppData
            }
        }

        It "does not crash when a WindowsApps stub fails to launch" -Skip:(-not $platformIsWindows) {
            # A truly-invalid 0-byte file (the closest a test fixture can get
            # to an app-execution-alias reparse point) throws when invoked,
            # not just exits non-zero. Without the try/catch around the probe,
            # a broken stub would crash Resolve-Python - and with it,
            # Install-PythonDeps's best-effort caller chain.
            $stubDir = Join-Path $TestDrive "crash-stub\Microsoft\WindowsApps"
            New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
            New-Item -ItemType File -Path (Join-Path $stubDir "python.exe") -Force | Out-Null

            $oldPath = $env:Path
            $oldLocalAppData = $env:LOCALAPPDATA
            try {
                $env:Path = $stubDir
                $env:LOCALAPPDATA = Join-Path $TestDrive "empty-localappdata-3"

                . $script:functionsPath
                { $script:resolved = Resolve-Python } | Should -Not -Throw
                $script:resolved | Should -BeNullOrEmpty
            }
            finally {
                $env:Path = $oldPath
                $env:LOCALAPPDATA = $oldLocalAppData
            }
        }
    }

    Context "Invoke-PipInstall progress (#210)" {
        BeforeAll {
            . $script:functionsPath

            $script:isWindowsHost = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

            # Cross-platform fake interpreter: ignores its arguments
            # (`-m pip install --quiet ...`) and exits with the requested code,
            # standing in for pip succeeding or failing.
            function New-FakePip {
                param([Parameter(Mandatory)][int]$ExitCode)
                if ($script:isWindowsHost) {
                    $path = Join-Path $TestDrive "fake-pip-$ExitCode.cmd"
                    @('@echo off', "exit /b $ExitCode") | Set-Content -Path $path -Encoding ascii
                }
                else {
                    $path = Join-Path $TestDrive "fake-pip-$ExitCode.sh"
                    @('#!/bin/sh', "exit $ExitCode") | Set-Content -Path $path -Encoding ascii
                    & chmod +x $path
                }
                return $path
            }
        }

        It "routes every pip install in Install-PythonDeps through Invoke-PipInstall" {
            # The spinner only covers all install paths (install.ps1 STEP 6 and
            # the login auto-update) if no call site regresses to a raw inline
            # `& $py -m pip install`. Invoke-PipInstall's own internals use
            # different variable names, so this pattern pins the call sites.
            $content = Get-Content $script:functionsPath -Raw
            $content | Should -Not -Match '(?m)^\s*&\s*\$py\s+-m\s+pip\s+install'
            $content | Should -Match 'Invoke-PipInstall -Python \$py'
        }

        It "Test-ConsoleSpinnerSupport never throws and returns a boolean" {
            # The probe runs on every host (CI, scheduled task, interactive);
            # whatever it decides, it must decide cleanly.
            { $script:spinnerSupported = Test-ConsoleSpinnerSupport } | Should -Not -Throw
            $script:spinnerSupported | Should -BeOfType [bool]
        }

        It "emits a single plain status line via -Logger and returns `$true on success when no console is available" {
            Mock Test-ConsoleSpinnerSupport { $false }
            $script:messages = @()

            $result = Invoke-PipInstall -Python (New-FakePip -ExitCode 0) -Packages @('rich') -Logger { param($m) $script:messages += $m }

            $result | Should -BeTrue
            $script:messages.Count | Should -Be 1
            $script:messages[0] | Should -Match 'Installing rich'
            # No control characters may reach redirected logs (CI, login task).
            $script:messages[0] | Should -Not -Match "`r"
        }

        It "returns `$false when pip fails on the plain fallback path" {
            Mock Test-ConsoleSpinnerSupport { $false }
            $script:messages = @()

            $result = Invoke-PipInstall -Python (New-FakePip -ExitCode 1) -Packages @('rich', 'textual') -Logger { param($m) $script:messages += $m }

            $result | Should -BeFalse
            # The interim status line still shows; the caller owns the [WARN].
            $script:messages.Count | Should -Be 1
        }

        It "returns the pip exit status from the background job on the spinner path" {
            Mock Test-ConsoleSpinnerSupport { $true }

            Invoke-PipInstall -Python (New-FakePip -ExitCode 0) -Packages @('rich') | Should -BeTrue
            Invoke-PipInstall -Python (New-FakePip -ExitCode 3) -Packages @('rich') | Should -BeFalse
        }

        It "returns a single `$false when the -Logger writes to the pipeline and pip fails (#256)" {
            # Update-GitConfig's Write-Log emits its line to the pipeline
            # (Tee-Object). That line used to be captured into the return value,
            # giving @('<line>', $false), which is truthy: a failed install was
            # logged as [OK].
            Mock Test-ConsoleSpinnerSupport { $false }
            $script:messages = @()

            $result = Invoke-PipInstall -Python (New-FakePip -ExitCode 1) -Packages @('rich') -Logger {
                param($m)
                $script:messages += $m
                "2026-01-01 00:00:00 - $m"
            }

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [bool]
            $result | Should -BeFalse
            # The status line still went through the logger.
            $script:messages.Count | Should -Be 1
        }

        It "returns a single `$true when the -Logger writes to the pipeline and pip succeeds (#256)" {
            Mock Test-ConsoleSpinnerSupport { $false }

            $result = Invoke-PipInstall -Python (New-FakePip -ExitCode 0) -Packages @('rich') -Logger { param($m) "logged: $m" }

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [bool]
            $result | Should -BeTrue
        }

        It "does not let pip's stdout leak into the result on the plain path (#256)" {
            Mock Test-ConsoleSpinnerSupport { $false }
            if ($script:isWindowsHost) {
                $noisy = Join-Path $TestDrive "noisy-pip.cmd"
                @('@echo off', 'echo Collecting rich', 'exit /b 1') | Set-Content -Path $noisy -Encoding ascii
            }
            else {
                $noisy = Join-Path $TestDrive "noisy-pip.sh"
                @('#!/bin/sh', 'echo Collecting rich', 'exit 1') | Set-Content -Path $noisy -Encoding ascii
                & chmod +x $noisy
            }

            $result = Invoke-PipInstall -Python $noisy -Packages @('rich') -Logger { param($m) }

            @($result).Count | Should -Be 1
            $result | Should -BeFalse
        }
    }

    Context "Install-PythonDeps status (#256)" {
        BeforeAll {
            . $script:functionsPath

            $script:isWindowsHost = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

            # A repo root with the deps.py that Install-PythonDeps checks for. Its
            # content doesn't matter: the fake interpreter answers in its place.
            $script:depsRoot = Join-Path $TestDrive "deps-repo"
            New-Item -ItemType Directory -Force -Path (Join-Path $script:depsRoot "scripts/shared") | Out-Null
            New-Item -ItemType File -Force -Path (Join-Path $script:depsRoot "scripts/shared/deps.py") | Out-Null

            # Fake interpreter: pip is present, deps.py lists rich (required) and
            # textual (optional), neither imports, and every `pip install` exits
            # with $PipExit. Never runs a real pip.
            function New-FakePython {
                param([Parameter(Mandatory)][int]$PipExit)
                if ($script:isWindowsHost) {
                    $path = Join-Path $TestDrive "fake-python-$PipExit.cmd"
                    @(
                        '@echo off'
                        'if "%~1"=="-m" if "%~2"=="pip" if "%~3"=="--version" exit /b 0'
                        "if `"%~1`"==`"-m`" if `"%~2`"==`"pip`" if `"%~3`"==`"install`" exit /b $PipExit"
                        'if "%~1"=="-c" exit /b 1'
                        'if "%~2"=="required" echo rich'
                        'if "%~2"=="optional" echo textual'
                        'exit /b 0'
                    ) | Set-Content -Path $path -Encoding ascii
                }
                else {
                    $path = Join-Path $TestDrive "fake-python-$PipExit.sh"
                    @(
                        '#!/bin/sh'
                        'case "$1 $2 $3" in'
                        '  "-m pip --version") exit 0 ;;'
                        "  `"-m pip install`") exit $PipExit ;;"
                        'esac'
                        '[ "$1" = "-c" ] && exit 1'
                        '[ "$2" = "required" ] && echo rich'
                        '[ "$2" = "optional" ] && echo textual'
                        'exit 0'
                    ) | Set-Content -Path $path -Encoding ascii
                    & chmod +x $path
                }
                return $path
            }

            # Logs like Update-GitConfig's Write-Log: records the line and also
            # emits it to the pipeline.
            $script:pipelineLogger = {
                param($m)
                $script:depsMessages += $m
                "2026-01-01 00:00:00 - $m"
            }
        }

        BeforeEach {
            $script:depsMessages = @()
            Mock Test-ConsoleSpinnerSupport { $false }
        }

        It "logs [WARN], not [OK], when pip install fails and the logger writes to the pipeline" {
            $script:fakePython = New-FakePython -PipExit 1
            Mock Resolve-Python { $script:fakePython }

            Install-PythonDeps -RepoRoot $script:depsRoot -Logger $script:pipelineLogger | Out-Null

            $all = $script:depsMessages -join "`n"
            $all | Should -Match '\[WARN\] Could not install required Python deps \(rich\)'
            $all | Should -Not -Match '\[OK\]'
        }

        It "logs [OK] when pip install succeeds and the logger writes to the pipeline" {
            $script:fakePython = New-FakePython -PipExit 0
            Mock Resolve-Python { $script:fakePython }

            Install-PythonDeps -RepoRoot $script:depsRoot -Logger $script:pipelineLogger | Out-Null

            $all = $script:depsMessages -join "`n"
            $all | Should -Match '\[OK\] Installed Python deps: rich textual'
            $all | Should -Not -Match '\[WARN\]'
        }
    }
}

Describe "Elevating as a different account (Functions.ps1, #240)" -Tag 'Unit' {
    # With over-the-shoulder UAC the elevated relaunch runs as the administrator.
    # The non-elevated run passes who started it (Get-InvokingUserArguments) and
    # the elevated run switches back to that account (Use-InvokingUser).

    BeforeAll {
        . $script:functionsPath
        $script:savedEnv = @{
            USERDOMAIN = $env:USERDOMAIN; USERNAME = $env:USERNAME
            USERPROFILE = $env:USERPROFILE; HOME = $env:HOME
        }
    }

    BeforeEach {
        $env:USERDOMAIN = "CORP"
        $env:USERNAME = "admin"
        $env:USERPROFILE = "C:\Users\admin"
        $env:HOME = "C:\Users\admin"
    }

    AfterAll {
        foreach ($k in $script:savedEnv.Keys) {
            if ($null -ne $script:savedEnv[$k]) { Set-Item "Env:$k" $script:savedEnv[$k] }
            else { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        }
    }

    It "Get-CurrentUserName returns DOMAIN\user, or the bare name without a domain" {
        Get-CurrentUserName | Should -Be "CORP\admin"
        $env:USERDOMAIN = ""
        Get-CurrentUserName | Should -Be "admin"
    }

    It "Get-InvokingUserArguments quotes the user and profile and trims a trailing backslash" {
        $env:USERNAME = "alice"
        $env:USERPROFILE = "C:\Users\alice smith\"
        $a = Get-InvokingUserArguments
        $a[0..3] | Should -Be @('-InvokingUser', '"CORP\alice"', '-InvokingUserProfile', '"C:\Users\alice smith"')
    }

    It "Use-InvokingUser changes nothing when the same account elevated" {
        $r = Use-InvokingUser -InvokingUser "corp\ADMIN" -InvokingUserProfile "C:\Users\other" -InvokingDocuments "D:\Docs" 6> $null
        $r.Switched | Should -BeFalse
        $r.User | Should -Be "CORP\admin"
        # The Documents folder passed is still used for the profiles (#230).
        $r.Documents | Should -Be "D:\Docs"
        $env:USERPROFILE | Should -Be "C:\Users\admin"
    }

    It "Use-InvokingUser changes nothing when no invoking user was passed (run elevated directly)" {
        $r = Use-InvokingUser -InvokingUser "" 6> $null
        $r.Switched | Should -BeFalse
        $r.User | Should -Be "CORP\admin"
        $r.Documents | Should -BeNullOrEmpty
    }

    It "Use-InvokingUser switches USERPROFILE and HOME to the invoking account and warns" {
        $out = Use-InvokingUser -InvokingUser "CORP\alice" -InvokingUserProfile "C:\Users\alice" -InvokingDocuments "C:\Users\alice\OneDrive\Documents" 6>&1
        $r = $out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }
        $text = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n"
        $r.Switched | Should -BeTrue
        $r.User | Should -Be "CORP\alice"
        $r.Documents | Should -Be "C:\Users\alice\OneDrive\Documents"
        $env:USERPROFILE | Should -Be "C:\Users\alice"
        $env:HOME | Should -Be "C:\Users\alice"
        $text | Should -Match '\[WARN\] Elevated as CORP\\admin, but started by CORP\\alice'
    }

    It "Get-ProfileScriptPath returns both editions' profiles under the given Documents folder (#230)" {
        $docs = Join-Path $TestDrive "Docs"
        $p = @(Get-ProfileScriptPath -Documents $docs)
        $p | Should -Be @(
            (Join-Path (Join-Path $docs "WindowsPowerShell") "profile.ps1"),
            (Join-Path (Join-Path $docs "PowerShell") "profile.ps1")
        )
    }

    It "Get-ProfileScriptPath defaults to this account's Documents folder, not `$PROFILE" {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $expected = if ($docs) { @(Get-ProfileScriptPath -Documents $docs) } else { @($PROFILE.CurrentUserAllHosts) }
        @(Get-ProfileScriptPath) | Should -Be $expected
    }
}

Describe "UTF-8 file helpers (Functions.ps1, #230)" -Tag 'Unit' {
    # Windows PowerShell 5.1's Get-Content / Set-Content / Add-Content use ANSI.

    BeforeAll {
        . $script:functionsPath
        # Spelled with char codes so this file stays ASCII: e-acute, CJK, emoji.
        $script:fancy = "Jos" + [char]0xE9 + " " + [char]0x4E2D + " " + [char]::ConvertFromUtf32(0x1F600)
        $script:utf8 = New-Object System.Text.UTF8Encoding($false)
    }

    BeforeEach {
        $script:file = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ".txt")
    }

    It "Write-Utf8File writes UTF-8 without a BOM and Read-Utf8File reads it back" {
        Write-Utf8File -Path $script:file -Text "$script:fancy`n"
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $script:utf8.GetBytes("$script:fancy`n")
        Read-Utf8File $script:file | Should -BeExactly "$script:fancy`n"
    }

    It "Write-Utf8File replaces a longer file completely" {
        [System.IO.File]::WriteAllText($script:file, ("x" * 100))
        Write-Utf8File -Path $script:file -Text "short"
        [System.IO.File]::ReadAllText($script:file) | Should -BeExactly "short"
    }

    It "Read-Utf8File honours a BOM" {
        [System.IO.File]::WriteAllBytes($script:file, [byte[]](0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($script:fancy))
        Read-Utf8File $script:file | Should -BeExactly $script:fancy
    }

    It "Add-Utf8Text appends UTF-8 and creates the file" {
        Add-Utf8Text -Path $script:file -Text "a`n"
        Add-Utf8Text -Path $script:file -Text "$script:fancy`n"
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $script:utf8.GetBytes("a`n$script:fancy`n")
    }

    It "resolves a relative path against the PowerShell location" {
        Push-Location $TestDrive
        try { Write-Utf8File -Path "relative.txt" -Text "here" }
        finally { Pop-Location }
        Join-Path $TestDrive "relative.txt" | Should -Exist
    }
}

Describe "Set-MarkedBlock (Functions.ps1, #230)" -Tag 'Unit' {

    BeforeAll {
        . $script:functionsPath
        $script:begin = "# >>> begin >>>"
        $script:end = "# <<< end <<<"
        $script:utf8 = New-Object System.Text.UTF8Encoding($false)
        $script:latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $script:fancy = "Write-Host 'caf" + [char]0xE9 + " " + [char]0xE0B0 + " " + [char]::ConvertFromUtf32(0x1F600) + "'"
        function Set-Block([string]$Body) {
            Set-MarkedBlock -Path $script:file -BeginMarker $script:begin -EndMarker $script:end -Body $Body
        }
    }

    BeforeEach {
        $script:file = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) "profile.ps1"
    }

    It "creates the folder and a UTF-8 file with a BOM and CRLF endings" {
        Set-Block ". 'new.ps1'" | Should -Be 'Added'
        $expected = [byte[]](0xEF, 0xBB, 0xBF) + $script:utf8.GetBytes("$script:begin`r`n. 'new.ps1'`r`n$script:end`r`n")
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $expected
    }

    It "writes an empty existing file like a new one (UTF-8 with a BOM)" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        [System.IO.File]::WriteAllBytes($script:file, [byte[]]@())
        Set-Block ". '$script:fancy.ps1'" | Should -Be 'Added'
        $expected = [byte[]](0xEF, 0xBB, 0xBF) + $script:utf8.GetBytes("$script:begin`r`n. '$script:fancy.ps1'`r`n$script:end`r`n")
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $expected
    }

    It "appends after a blank line, keeping a UTF-8 BOM, CRLF endings and non-ASCII text" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        [System.IO.File]::WriteAllBytes($script:file, $bom + $script:utf8.GetBytes("# mine`r`n$script:fancy`r`n"))
        Set-Block ". 'w.ps1'" | Should -Be 'Added'
        $expected = $bom + $script:utf8.GetBytes("# mine`r`n$script:fancy`r`n`r`n$script:begin`r`n. 'w.ps1'`r`n$script:end`r`n")
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $expected
    }

    It "uses LF in an LF-only file and ends an unterminated last line first" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        [System.IO.File]::WriteAllBytes($script:file, $script:utf8.GetBytes("# mine`n$script:fancy"))
        Set-Block ". 'w.ps1'" | Should -Be 'Added'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $script:utf8.GetBytes("# mine`n$script:fancy`n`n$script:begin`n. 'w.ps1'`n$script:end`n")
    }

    It "rewrites an existing block in place and keeps the lines around it" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $before = "# mine`r`n"
        $after = "Set-Alias g git"
        [System.IO.File]::WriteAllBytes($script:file, $script:utf8.GetBytes("$before$script:begin`r`n. 'C:\old\w.ps1'`r`n$script:end`r`n$after"))
        Set-Block ". 'C:\new\w.ps1'" | Should -Be 'Updated'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $script:utf8.GetBytes("$before$script:begin`r`n. 'C:\new\w.ps1'`r`n$script:end`r`n$after")
    }

    It "drops later copies of the block" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $block = "$script:begin`n. 'w.ps1'`n$script:end`n"
        [System.IO.File]::WriteAllBytes($script:file, $script:utf8.GetBytes("a`n$block" + "b`n$block" + "c`n"))
        Set-Block ". 'w.ps1'" | Should -Be 'Updated'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $script:utf8.GetBytes("a`n$block" + "b`nc`n")
    }

    It "leaves an up-to-date file alone (no write)" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $bytes = $script:utf8.GetBytes("# mine`r`n$script:begin`r`n. 'w.ps1'`r`n$script:end`r`n")
        [System.IO.File]::WriteAllBytes($script:file, $bytes)
        $stamp = [datetime]'2001-02-03'
        (Get-Item -LiteralPath $script:file).LastWriteTime = $stamp
        Set-Block ". 'w.ps1'" | Should -Be 'Unchanged'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $bytes
        (Get-Item -LiteralPath $script:file).LastWriteTime | Should -Be $stamp
    }

    It "keeps a UTF-16 LE file UTF-16 LE" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $enc = New-Object System.Text.UnicodeEncoding($false, $false)
        $bom = [byte[]](0xFF, 0xFE)
        [System.IO.File]::WriteAllBytes($script:file, $bom + $enc.GetBytes("$script:fancy`r`n"))
        Set-Block ". 'w.ps1'" | Should -Be 'Added'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be ($bom + $enc.GetBytes("$script:fancy`r`n`r`n$script:begin`r`n. 'w.ps1'`r`n$script:end`r`n"))
    }

    It "keeps ANSI bytes that are not valid UTF-8, and writes a non-ASCII body as UTF-8" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $before = "# caf" + [char]0xE9 + "`r`n"
        [System.IO.File]::WriteAllBytes($script:file, $script:latin1.GetBytes($before))
        $body = ". 'C:\Users\Jos" + [char]0xE9 + "\w.ps1'"
        Set-Block $body | Should -Be 'Added'
        $expected = $script:latin1.GetBytes("$before`r`n") + $script:utf8.GetBytes("$script:begin`r`n$body`r`n$script:end`r`n")
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $expected
    }

    It "leaves the file alone when the end marker is missing" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:file) | Out-Null
        $bytes = $script:utf8.GetBytes("# mine`n$script:begin`n. 'w.ps1'`n# user line after`n")
        [System.IO.File]::WriteAllBytes($script:file, $bytes)
        Set-Block ". 'w.ps1'" | Should -Be 'Unterminated'
        [System.IO.File]::ReadAllBytes($script:file) | Should -Be $bytes
    }
}
