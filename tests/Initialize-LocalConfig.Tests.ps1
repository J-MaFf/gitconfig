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
    }
}
