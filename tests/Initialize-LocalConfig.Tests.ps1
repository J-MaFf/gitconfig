BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\windows version\Initialize-LocalConfig.ps1"
}

Describe "Initialize-LocalConfig.ps1" {

    Context "allowed_signers generation" {
        BeforeEach {
            # Sandbox everything to TestDrive so the real ~/.gitconfig.local and
            # ~/.ssh/allowed_signers are never touched. Redirect HOME/USERPROFILE
            # and isolate git's global/system config to seeded sandbox files.
            $script:sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

            $script:savedUserProfile = $env:USERPROFILE
            $script:savedHome = $env:HOME
            $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
            $script:savedSystem = $env:GIT_CONFIG_SYSTEM

            $env:USERPROFILE = $script:sandbox
            $env:HOME = $script:sandbox
            $env:GIT_CONFIG_GLOBAL = Join-Path $script:sandbox ".gitconfig"
            $env:GIT_CONFIG_SYSTEM = Join-Path $script:sandbox "no-system-config"

            git config --global user.email "sandbox@example.com" 2>&1 | Out-Null
            git config --global user.signingkey "ssh-ed25519 AAAASANDBOXKEY test-comment" 2>&1 | Out-Null
        }

        AfterEach {
            $env:USERPROFILE = $script:savedUserProfile
            $env:HOME = $script:savedHome
            $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
            $env:GIT_CONFIG_SYSTEM = $script:savedSystem
        }

        It "Should write ~/.ssh/allowed_signers with the signing identity" {
            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $allowed = Join-Path $script:sandbox ".ssh\allowed_signers"
            $allowed | Should -Exist
            $content = Get-Content $allowed -Raw
            $content | Should -Match 'sandbox@example.com namespaces="git" ssh-ed25519 AAAASANDBOXKEY'
        }

        It "Should drop any trailing comment from the public key" {
            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $content = Get-Content (Join-Path $script:sandbox ".ssh\allowed_signers") -Raw
            $content | Should -Not -Match 'test-comment'
        }

        It "Should set allowedSignersFile in .gitconfig.local" {
            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $local = Join-Path $script:sandbox ".gitconfig.local"
            $local | Should -Exist
            (Get-Content $local -Raw) | Should -Match 'allowedSignersFile\s*=\s*.*/\.ssh/allowed_signers'
        }

        It "Should not duplicate the entry when run twice" {
            Push-Location $script:sandbox
            try {
                & $script:scriptPath -Force 2>&1 | Out-Null
                & $script:scriptPath -Force 2>&1 | Out-Null
            }
            finally { Pop-Location }

            $allowed = Join-Path $script:sandbox ".ssh\allowed_signers"
            @(Get-Content $allowed | Where-Object { $_ -match 'sandbox@example.com' }).Count | Should -Be 1
        }

        It "Should preserve entries for other identities" {
            $sshDir = Join-Path $script:sandbox ".ssh"
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            $allowed = Join-Path $sshDir "allowed_signers"
            Set-Content -Path $allowed -Value 'other@example.com namespaces="git" ssh-ed25519 AAAAOTHER'

            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $content = Get-Content $allowed -Raw
            $content | Should -Match 'other@example.com'
            $content | Should -Match 'sandbox@example.com'
        }

        It "Should start a new line when allowed_signers lacks a trailing newline (#255)" {
            # Add-Content used to glue the new entry onto the last one, so
            # neither identity verified.
            $sshDir = Join-Path $script:sandbox ".ssh"
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            $allowed = Join-Path $sshDir "allowed_signers"
            [System.IO.File]::WriteAllText($allowed, 'other@example.com namespaces="git" ssh-ed25519 AAAAOTHER')

            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $lines = @(Get-Content $allowed)
            $lines.Count | Should -Be 2
            $lines[0] | Should -BeExactly 'other@example.com namespaces="git" ssh-ed25519 AAAAOTHER'
            $lines[1] | Should -BeExactly 'sandbox@example.com namespaces="git" ssh-ed25519 AAAASANDBOXKEY'
        }

        It "Should not add a blank line when allowed_signers already ends in a newline (#255)" {
            $sshDir = Join-Path $script:sandbox ".ssh"
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            $allowed = Join-Path $sshDir "allowed_signers"
            [System.IO.File]::WriteAllText($allowed, "other@example.com namespaces=`"git`" ssh-ed25519 AAAAOTHER`n")

            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $lines = @(Get-Content $allowed)
            $lines.Count | Should -Be 2
            $lines[1] | Should -BeExactly 'sandbox@example.com namespaces="git" ssh-ed25519 AAAASANDBOXKEY'
        }
    }

    Context "config verification" {
        BeforeEach {
            # Same sandbox isolation as above; the sandbox dir is deliberately NOT
            # a git repo (it lives under TestDrive), which is the condition that
            # exposed the verification-scope bug.
            $script:sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

            $script:savedUserProfile = $env:USERPROFILE
            $script:savedHome = $env:HOME
            $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
            $script:savedSystem = $env:GIT_CONFIG_SYSTEM

            $env:USERPROFILE = $script:sandbox
            $env:HOME = $script:sandbox
            $env:GIT_CONFIG_GLOBAL = Join-Path $script:sandbox ".gitconfig"
            $env:GIT_CONFIG_SYSTEM = Join-Path $script:sandbox "no-system-config"

            git config --global user.email "sandbox@example.com" 2>&1 | Out-Null
            git config --global user.signingkey "ssh-ed25519 AAAASANDBOXKEY test-comment" 2>&1 | Out-Null
        }

        AfterEach {
            $env:USERPROFILE = $script:savedUserProfile
            $env:HOME = $script:savedHome
            $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
            $env:GIT_CONFIG_SYSTEM = $script:savedSystem
        }

        It "Should verify the generated config (not WARN) when run outside a git repo" -Skip:($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            # Regression guard for #148: the script must validate the file it wrote
            # (git config --file ...), not the repo config (git config --local ...),
            # which errors when the current directory isn't a git repo. The sandbox
            # CWD is not a repo, so the old --local check printed a spurious WARN.
            # Capture all streams (*>&1) so Write-Host's information-stream output
            # lands in $out; 2>&1 alone would miss it.
            #
            # Windows-only (#176): the script under test builds USERPROFILE-relative
            # paths with backslashes, so on Unix hosts verification reads a
            # mixed-separator path and WARNs spuriously. The script never runs on
            # Unix, so skip there instead of chasing Windows path semantics
            # cross-platform. (The -Skip expression is discovery-safe: $IsWindows
            # doesn't exist on Windows PowerShell 5.1, where the version guard
            # short-circuits to "run".)
            Push-Location $script:sandbox
            try { $out = & $script:scriptPath -Force *>&1 } finally { Pop-Location }
            $text = $out | Out-String

            $text | Should -Match '\[OK\] Git configuration verified!'
            $text | Should -Not -Match 'Git may have issues reading the configuration'
        }

        It "Should not use the CWD-dependent 'git config --local' check" {
            (Get-Content $script:scriptPath -Raw) | Should -Not -Match 'git config --local --list'
        }
    }

    Context "generated [core] settings" {
        BeforeEach {
            # Same sandbox isolation as the other contexts.
            $script:sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

            $script:savedUserProfile = $env:USERPROFILE
            $script:savedHome = $env:HOME
            $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
            $script:savedSystem = $env:GIT_CONFIG_SYSTEM

            $env:USERPROFILE = $script:sandbox
            $env:HOME = $script:sandbox
            $env:GIT_CONFIG_GLOBAL = Join-Path $script:sandbox ".gitconfig"
            $env:GIT_CONFIG_SYSTEM = Join-Path $script:sandbox "no-system-config"

            git config --global user.email "sandbox@example.com" 2>&1 | Out-Null
            git config --global user.signingkey "ssh-ed25519 AAAASANDBOXKEY test-comment" 2>&1 | Out-Null
        }

        AfterEach {
            $env:USERPROFILE = $script:savedUserProfile
            $env:HOME = $script:savedHome
            $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
            $env:GIT_CONFIG_SYSTEM = $script:savedSystem
        }

        It "Should enable core.longpaths in the generated .gitconfig.local" {
            # Regression guard for #186: core.longpaths=true must come from the
            # never-clobbered local config, not a hand-set global that template
            # regeneration (git selfupdate) silently wipes. Without it, deeply
            # nested repos (Dolt's git-remote-cache behind beads' bd dolt push)
            # fail with "Filename too long" on Windows.
            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $local = Join-Path $script:sandbox ".gitconfig.local"
            $local | Should -Exist
            git config --file $local --get core.longpaths | Should -Be 'true'
        }
    }

    Context "create-if-missing (preserve existing .gitconfig.local)" {
        BeforeEach {
            # Same sandbox isolation as the other contexts.
            $script:sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

            $script:savedUserProfile = $env:USERPROFILE
            $script:savedHome = $env:HOME
            $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
            $script:savedSystem = $env:GIT_CONFIG_SYSTEM

            $env:USERPROFILE = $script:sandbox
            $env:HOME = $script:sandbox
            $env:GIT_CONFIG_GLOBAL = Join-Path $script:sandbox ".gitconfig"
            $env:GIT_CONFIG_SYSTEM = Join-Path $script:sandbox "no-system-config"

            git config --global user.email "sandbox@example.com" 2>&1 | Out-Null
            git config --global user.signingkey "ssh-ed25519 AAAASANDBOXKEY test-comment" 2>&1 | Out-Null

            $script:localPath = Join-Path $script:sandbox ".gitconfig.local"
        }

        AfterEach {
            $env:USERPROFILE = $script:savedUserProfile
            $env:HOME = $script:savedHome
            $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
            $env:GIT_CONFIG_SYSTEM = $script:savedSystem
        }

        It "Should preserve an existing file when run without -Force" {
            Set-Content -Path $script:localPath -Value "# USER-EDIT-MARKER-DO-NOT-CLOBBER"

            Push-Location $script:sandbox
            try { & $script:scriptPath 2>&1 | Out-Null } finally { Pop-Location }

            $content = Get-Content $script:localPath -Raw
            $content | Should -Match 'USER-EDIT-MARKER-DO-NOT-CLOBBER'
            $content | Should -Not -Match '\[safe\]'           # template was NOT written
        }

        It "Should still ensure allowed_signers even when preserving the config" {
            Set-Content -Path $script:localPath -Value "# USER-EDIT-MARKER-DO-NOT-CLOBBER"

            Push-Location $script:sandbox
            try { & $script:scriptPath 2>&1 | Out-Null } finally { Pop-Location }

            $allowed = Join-Path $script:sandbox ".ssh\allowed_signers"
            $allowed | Should -Exist
            (Get-Content $allowed -Raw) | Should -Match 'sandbox@example.com namespaces="git" ssh-ed25519 AAAASANDBOXKEY'
        }

        It "Should regenerate from template when -Force overwrites an existing file" {
            Set-Content -Path $script:localPath -Value "# USER-EDIT-MARKER-DO-NOT-CLOBBER"

            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 2>&1 | Out-Null } finally { Pop-Location }

            $content = Get-Content $script:localPath -Raw
            $content | Should -Not -Match 'USER-EDIT-MARKER-DO-NOT-CLOBBER'
            $content | Should -Match '\[safe\]'               # template WAS written
        }
    }
}

Describe "Initialize-LocalConfig.ps1 machine-specific values (#235)" -Tag 'Unit' {
    BeforeAll {
        . (Join-Path $script:repoRoot "scripts\windows version\Functions.ps1")
        $script:repoEntry = ConvertTo-GitSafeDirectory $script:repoRoot
        $script:onWindowsRun = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

        # A fake ssh-add whose -L lists Key, put first on PATH.
        function New-FakeSshAdd([string]$Key) {
            $bin = Join-Path $script:sandbox "bin"
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            if ($script:onWindowsRun) {
                Set-Content -LiteralPath (Join-Path $bin "ssh-add.cmd") -Value "@echo $Key agent-comment"
            }
            else {
                $path = Join-Path $bin "ssh-add"
                [IO.File]::WriteAllText($path, "#!/bin/sh`necho '$Key agent-comment'`n")
                & chmod +x $path
            }
            $env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH
        }

        function Invoke-InitLocal {
            Push-Location $script:sandbox
            try { & $script:scriptPath -Force 6>&1 | Out-String } finally { Pop-Location }
        }

        function Get-SafeDirectories {
            @(& git config --file $script:localPath --get-all safe.directory)
        }
    }

    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $script:saved = @{
            USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; PATH = $env:PATH
            G = $env:GIT_CONFIG_GLOBAL; S = $env:GIT_CONFIG_SYSTEM
            Op = $env:GITCONFIG_OP_SSH_SIGN; Sock = $env:SSH_AUTH_SOCK; Code = $env:GITCONFIG_CODE_BIN
        }
        $env:USERPROFILE = $script:sandbox
        $env:HOME = $script:sandbox
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:sandbox ".gitconfig"
        $env:GIT_CONFIG_SYSTEM = Join-Path $script:sandbox "no-system-config"
        $env:SSH_AUTH_SOCK = Join-Path $script:sandbox "no-agent.sock"
        $env:GITCONFIG_CODE_BIN = ""
        # Probe the sandbox for op-ssh-sign.exe, not the real machine.
        Remove-Item Env:GITCONFIG_OP_SSH_SIGN -ErrorAction SilentlyContinue
        git config --global user.email "sandbox@example.com" 2>&1 | Out-Null
        $script:localPath = Join-Path $script:sandbox ".gitconfig.local"
        $script:safeFile = [System.IO.Path]::Combine($script:sandbox, '.config', 'gitconfig', 'safe-directories')
    }

    AfterEach {
        $env:USERPROFILE = $script:saved.USERPROFILE
        $env:HOME = $script:saved.HOME
        $env:PATH = $script:saved.PATH
        $env:GIT_CONFIG_GLOBAL = $script:saved.G
        $env:GIT_CONFIG_SYSTEM = $script:saved.S
        $env:GITCONFIG_OP_SSH_SIGN = $script:saved.Op
        $env:SSH_AUTH_SOCK = $script:saved.Sock
        $env:GITCONFIG_CODE_BIN = $script:saved.Code
    }

    Context "safe.directory" {
        It "trusts this clone of the repo and nothing hardcoded" {
            Invoke-InitLocal | Out-Null
            Get-SafeDirectories | Should -Be @($script:repoEntry)
            $content = Get-Content -LiteralPath $script:localPath -Raw
            $content | Should -Not -Match '10\.210\.3\.10|KFWS9BDC01|winget'
        }

        It "adds the entries listed in ~/.config/gitconfig/safe-directories" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:safeFile) -Force | Out-Null
            [IO.File]::WriteAllText($script:safeFile, "# work shares`r`n\\fileserver\dept\IT\repo`r`nC:\Repos\odd;name`r`n`r`n$($script:repoRoot)`r`n\\fileserver\dept\IT\repo`r`n")
            $out = Invoke-InitLocal
            $out | Should -Match 'safe directories listed in'
            Get-SafeDirectories | Should -Be @($script:repoEntry, '%(prefix)///fileserver/dept/IT/repo', 'C:/Repos/odd;name')
        }

        It "-Force keeps entries the previous file had, once" {
            [IO.File]::WriteAllText($script:localPath, "[safe]`n`tdirectory = %(prefix)///10.0.0.5/share/repo`n`tdirectory = $($script:repoEntry)`n")
            $out = Invoke-InitLocal
            $out | Should -Match 'Keeping 1 safe directory'
            Get-SafeDirectories | Should -Be @($script:repoEntry, '%(prefix)///10.0.0.5/share/repo')
            (Get-Content -LiteralPath $script:localPath -Raw) | Should -Match 'Kept from the previous'

            Invoke-InitLocal | Out-Null
            Get-SafeDirectories | Should -Be @($script:repoEntry, '%(prefix)///10.0.0.5/share/repo')
        }
    }

    Context "op-ssh-sign probing" {
        It "omits gpg.ssh.program when op-ssh-sign.exe isn't installed" {
            Invoke-InitLocal | Out-Null
            & git config --file $script:localPath --get gpg.ssh.program 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 1
            (& git config --file $script:localPath --get gpg.format) | Should -Be "ssh"
        }

        It "points gpg.ssh.program at the op-ssh-sign.exe it finds: <Name>" -ForEach @(
            @{ Name = 'Microsoft Store'; Parts = @('AppData', 'Local', 'Microsoft', 'WindowsApps', 'op-ssh-sign.exe') }
            @{ Name = 'standard installer'; Parts = @('AppData', 'Local', '1Password', 'app', '8', 'op-ssh-sign.exe') }
        ) {
            $stub = [System.IO.Path]::Combine([string[]](@($script:sandbox) + $Parts))
            New-Item -ItemType Directory -Path (Split-Path -Parent $stub) -Force | Out-Null
            Set-Content -LiteralPath $stub -Value "stub"
            git config --global user.signingkey "ssh-ed25519 AAAAPROBEKEY" 2>&1 | Out-Null
            Invoke-InitLocal | Out-Null
            (& git config --file $script:localPath --get gpg.ssh.program) | Should -BeExactly ($stub -replace '\\', '/')
            (& git config --file $script:localPath --get commit.gpgsign) | Should -Be "true"
        }

        It "a literal key with no op-ssh-sign and no agent: signing stays off, with a warning" {
            git config --global user.signingkey "ssh-ed25519 AAAANOAGENT" 2>&1 | Out-Null
            $out = Invoke-InitLocal
            $out | Should -Match "op-ssh-sign.exe isn't installed"
            & git config --file $script:localPath --get commit.gpgsign 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 1
            & git config --file $script:localPath --get gpg.ssh.program 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 1
        }

        It "a literal key the SSH agent holds: signing is on without op-ssh-sign" {
            git config --global user.signingkey "ssh-ed25519 AAAAAGENTKEY me@laptop" 2>&1 | Out-Null
            New-FakeSshAdd "ssh-ed25519 AAAAAGENTKEY"
            Invoke-InitLocal | Out-Null
            (& git config --file $script:localPath --get commit.gpgsign) | Should -Be "true"
            & git config --file $script:localPath --get gpg.ssh.program 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }
}
