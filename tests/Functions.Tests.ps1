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
}
