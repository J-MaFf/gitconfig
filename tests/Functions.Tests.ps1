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
    }
}
