# Tests for the move of user.signingkey, commit.gpgsign and core.editor out of
# .gitconfig.template into ~/.gitconfig.local (#231).
#
# An installed machine auto-updates with Update-GitConfig.ps1, which runs
# Initialize-GitConfig.ps1 -Force to regenerate ~/.gitconfig but never
# regenerates ~/.gitconfig.local. These tests start from a ~/.gitconfig
# rendered from an old-style template (signing key, gpgsign, editor, with
# ~/.gitconfig.local included last), regenerate it the way the update does,
# and check that the machine still signs, with the same key and editor.
# The bats suite tests/shared/template-settings-migration.bats covers the
# same ground for macOS/Linux.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:winDir = Join-Path (Join-Path $script:repoRoot "scripts") "windows version"
    . (Join-Path $script:winDir "Functions.ps1")
    $script:initGit = Join-Path $script:winDir "Initialize-GitConfig.ps1"
    $script:initLocal = Join-Path $script:winDir "Initialize-LocalConfig.ps1"
    $script:oldKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY"

    # A ~/.gitconfig as the template before #231 rendered it.
    function New-OldGitConfig {
        param([string]$Path, [string]$Editor = "code --wait")
        $text = "[user]`n`tname = Test`n`temail = test@example.com`n`tsigningkey = $($script:oldKey)`n" +
            "[gpg]`n`tformat = ssh`n[commit]`n`tgpgsign = true`n[core]`n`teditor = $Editor`n" +
            "[include]`n`tpath = ~/.gitconfig.local`n"
        [IO.File]::WriteAllText($Path, $text)
    }

    # What git uses on this machine: ~/.gitconfig with its includes.
    function Get-Effective {
        param([string]$Key)
        $v = & git config --file (Join-Path $script:sbHome ".gitconfig") --includes --get $Key 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $v
    }

    function Set-Sandbox {
        $script:saved = @{
            USERPROFILE = $env:USERPROFILE; HOME = $env:HOME
            G = $env:GIT_CONFIG_GLOBAL; S = $env:GIT_CONFIG_SYSTEM
        }
        $script:sbHome = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:sbHome | Out-Null
        $env:USERPROFILE = $script:sbHome
        $env:HOME = $script:sbHome
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:sbHome ".gitconfig"
        $env:GIT_CONFIG_SYSTEM = Join-Path $script:sbHome "no-system-config"
        $script:cfg = Join-Path $script:sbHome ".gitconfig"
        $script:local = Join-Path $script:sbHome ".gitconfig.local"
    }

    function Reset-Sandbox {
        $env:USERPROFILE = $script:saved.USERPROFILE
        $env:HOME = $script:saved.HOME
        $env:GIT_CONFIG_GLOBAL = $script:saved.G
        $env:GIT_CONFIG_SYSTEM = $script:saved.S
    }
}

Describe "The template leaves machine settings to ~/.gitconfig.local (#231)" -Tag 'Unit' {
    It "doesn't set <_>" -ForEach @('user.signingkey', 'commit.gpgsign', 'core.editor') {
        & git config --file (Join-Path $script:repoRoot ".gitconfig.template") --get $_ 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}

Describe "Move-TemplateSettingsToLocal" -Tag 'Unit' {
    BeforeEach { Set-Sandbox; $script:old = Join-Path $script:sbHome "old.gitconfig" }
    AfterEach { Reset-Sandbox }

    It "moves the key, gpgsign and editor into a missing ~/.gitconfig.local" {
        New-OldGitConfig -Path $script:old
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeTrue
        (& git config --file $script:local --get user.signingkey) | Should -Be $script:oldKey
        (& git config --file $script:local --get commit.gpgsign) | Should -Be "true"
        (& git config --file $script:local --get core.editor) | Should -Be "code --wait"
    }

    It "leaves a key ~/.gitconfig.local sets and still carries gpgsign" {
        New-OldGitConfig -Path $script:old
        [IO.File]::WriteAllText($script:local, "[user]`n`tsigningkey = ~/.ssh/claude_desktop.pub`n")
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeTrue
        @(& git config --file $script:local --get-all user.signingkey) | Should -Be @("~/.ssh/claude_desktop.pub")
        (& git config --file $script:local --get commit.gpgsign) | Should -Be "true"
    }

    It "doesn't carry gpgsign without a signing key" {
        [IO.File]::WriteAllText($script:old, "[commit]`n`tgpgsign = true`n[core]`n`teditor = nano`n")
        $out = Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>&1 | Out-String
        $out | Should -Match "no signing key is configured"
        & git config --file $script:local --get commit.gpgsign 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        (& git config --file $script:local --get core.editor) | Should -Be "nano"
    }

    It "doesn't carry gpgsign that was off" {
        [IO.File]::WriteAllText($script:old, "[user]`n`tsigningkey = $($script:oldKey)`n[commit]`n`tgpgsign = no`n")
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeTrue
        & git config --file $script:local --get commit.gpgsign 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It "doesn't copy a key the new template still sets" {
        [IO.File]::WriteAllText($script:old, "[core]`n`teditor = nano`n")
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "[core]`n`teditor = emacs`n" -LocalPath $script:local 6>$null | Should -BeTrue
        $script:local | Should -Not -Exist
    }

    It "keeps an editor value with quotes and spaces exactly" {
        $editor = '"C:/Program Files/Microsoft VS Code/Code.exe" --wait'
        [IO.File]::WriteAllText($script:old, "[core]`n`teditor = `"\`"C:/Program Files/Microsoft VS Code/Code.exe\`" --wait`"`n")
        (& git config --file $script:old --get core.editor) | Should -Be $editor
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeTrue
        (& git config --file $script:local --get core.editor) | Should -Be $editor
    }

    It "returns false and writes nothing when ~/.gitconfig.local can't be read" {
        New-OldGitConfig -Path $script:old
        [IO.File]::WriteAllText($script:local, "[broken`n")
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeFalse
        (Get-Content -LiteralPath $script:local -Raw) | Should -Be "[broken`n"
    }

    It "returns false when ~/.gitconfig.local can't be written" {
        New-OldGitConfig -Path $script:old
        # A stale lock makes every git config write to the file fail.
        Set-Content -LiteralPath "$($script:local).lock" -Value ""
        Move-TemplateSettingsToLocal -PreviousPath $script:old -NewContent "" -LocalPath $script:local 6>$null | Should -BeFalse
    }

    It "Get-DroppedGitConfigKeys leaves out what ~/.gitconfig.local sets" {
        [IO.File]::WriteAllText($script:old, "[core]`n`teditor = nano`n[foo]`n`tbar = 1`n")
        [IO.File]::WriteAllText($script:local, "[core]`n`teditor = nano`n")
        $dropped = @(Get-DroppedGitConfigKeys -ExistingPath $script:old -NewContent "" -LocalPath $script:local)
        $dropped | Should -Contain "foo.bar"
        $dropped | Should -Not -Contain "core.editor"
    }
}

Describe "Auto-update regeneration keeps signing and the editor (#231)" -Tag 'Unit' {
    BeforeEach { Set-Sandbox }
    AfterEach { Reset-Sandbox }

    It "file key in ~/.gitconfig.local (server/Windows-like): signing stays on, the editor moves" {
        New-OldGitConfig -Path $script:cfg
        [IO.File]::WriteAllText($script:local, "[user]`n`tsigningKey = ~/.ssh/id_ed25519_signing`n[commit]`n`tgpgsign = true`n")
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $script:cfg -Raw) | Should -Not -Match "signingkey"
        Get-Effective user.signingkey | Should -Be "~/.ssh/id_ed25519_signing"
        Get-Effective commit.gpgsign | Should -Be "true"
        Get-Effective core.editor | Should -Be "code --wait"
    }

    It "key in ~/.gitconfig.local without gpgsign (mac-like): gpgsign is carried over" {
        New-OldGitConfig -Path $script:cfg
        [IO.File]::WriteAllText($script:local, "[user]`n`tsigningkey = ~/.ssh/claude_desktop.pub`n")
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 0
        Get-Effective user.signingkey | Should -Be "~/.ssh/claude_desktop.pub"
        Get-Effective commit.gpgsign | Should -Be "true"
        Get-Effective core.editor | Should -Be "code --wait"
    }

    It "agent signing (key only in the template): the key moves into ~/.gitconfig.local" {
        New-OldGitConfig -Path $script:cfg
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 0
        $script:local | Should -Exist
        Get-Effective user.signingkey | Should -Be $script:oldKey
        Get-Effective commit.gpgsign | Should -Be "true"
        Get-Effective core.editor | Should -Be "code --wait"
    }

    It "local values are left alone and still win" {
        New-OldGitConfig -Path $script:cfg
        [IO.File]::WriteAllText($script:local, "[core]`n`teditor = vim`n[commit]`n`tgpgsign = false`n")
        & $script:initGit -Force *> $null
        Get-Effective core.editor | Should -Be "vim"
        Get-Effective commit.gpgsign | Should -Be "false"
        @(& git config --file $script:local --get-all core.editor) | Should -Be @("vim")
    }

    It "a second run changes nothing" {
        New-OldGitConfig -Path $script:cfg
        & $script:initGit -Force *> $null
        $before = Get-Content -LiteralPath $script:local -Raw
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $script:local -Raw) | Should -Be $before
    }

    It "leaves ~/.gitconfig as it was when ~/.gitconfig.local can't be written, and finishes next time" {
        New-OldGitConfig -Path $script:cfg
        $before = Get-Content -LiteralPath $script:cfg -Raw
        Set-Content -LiteralPath "$($script:local).lock" -Value ""
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath $script:cfg -Raw) | Should -Be $before

        Remove-Item -LiteralPath "$($script:local).lock" -Force
        & $script:initGit -Force *> $null
        $LASTEXITCODE | Should -Be 0
        Get-Effective user.signingkey | Should -Be $script:oldKey
        Get-Effective commit.gpgsign | Should -Be "true"
    }
}

Describe "Initialize-LocalConfig.ps1 signing and editor (#231)" -Tag 'Unit' {
    BeforeEach {
        Set-Sandbox
        $script:savedCode = $env:GITCONFIG_CODE_BIN
        $script:savedSsh = @{ C = $env:SSH_CONNECTION; L = $env:SSH_CLIENT; T = $env:SSH_TTY }
        $env:SSH_CONNECTION = $null; $env:SSH_CLIENT = $null; $env:SSH_TTY = $null
        $env:GITCONFIG_CODE_BIN = ""
        & git config --global user.email "sandbox@example.com"
    }
    AfterEach {
        $env:GITCONFIG_CODE_BIN = $script:savedCode
        $env:SSH_CONNECTION = $script:savedSsh.C; $env:SSH_CLIENT = $script:savedSsh.L; $env:SSH_TTY = $script:savedSsh.T
        Reset-Sandbox
    }

    It "an on-disk key file: signingkey and gpgsign, signed by ssh-keygen (no program)" {
        $ssh = Join-Path $script:sbHome ".ssh"
        New-Item -ItemType Directory -Path $ssh | Out-Null
        Set-Content -LiteralPath (Join-Path $ssh "id_ed25519_signing") -Value "private"
        Set-Content -LiteralPath (Join-Path $ssh "id_ed25519_signing.pub") -Value "ssh-ed25519 AAAAFILEKEY me"
        & git config --global user.signingkey "~/.ssh/id_ed25519_signing"
        & $script:initLocal -Force *> $null
        (& git config --file $script:local --get user.signingkey) | Should -Be "~/.ssh/id_ed25519_signing"
        (& git config --file $script:local --get commit.gpgsign) | Should -Be "true"
        (& git config --file $script:local --get gpg.format) | Should -Be "ssh"
        & git config --file $script:local --get gpg.ssh.program 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        (Get-Content (Join-Path $ssh "allowed_signers") -Raw) | Should -Match "ssh-ed25519 AAAAFILEKEY"
    }

    It "a key file that doesn't exist: the key is kept but signing stays off" {
        & git config --global user.signingkey "~/.ssh/missing_key"
        $out = & $script:initLocal -Force 6>&1 | Out-String
        $out | Should -Match "doesn't exist"
        (& git config --file $script:local --get user.signingkey) | Should -Be "~/.ssh/missing_key"
        & git config --file $script:local --get commit.gpgsign 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It "a literal key (1Password agent): signingkey, gpgsign and op-ssh-sign" {
        & git config --global user.signingkey $script:oldKey
        & $script:initLocal -Force *> $null
        (& git config --file $script:local --get user.signingkey) | Should -Be $script:oldKey
        (& git config --file $script:local --get commit.gpgsign) | Should -Be "true"
        (& git config --file $script:local --get gpg.ssh.program) | Should -Match "op-ssh-sign\.exe$"
    }

    It "no key: signing is left off" {
        $out = & $script:initLocal -Force 6>&1 | Out-String
        $out | Should -Match "No user.signingkey is configured"
        & git config --file $script:local --get commit.gpgsign 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        & git config --file $script:local --get user.signingkey 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It "VS Code installed, local session: core.editor is code --wait" {
        $env:GITCONFIG_CODE_BIN = "code"
        & $script:initLocal -Force *> $null
        (& git config --file $script:local --get core.editor) | Should -Be "code --wait"
    }

    It "VS Code installed but an SSH session: core.editor is left unset" {
        $env:GITCONFIG_CODE_BIN = "code"
        $env:SSH_CONNECTION = "10.0.0.1 1 10.0.0.2 22"
        & $script:initLocal -Force *> $null
        & git config --file $script:local --get core.editor 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        (Get-Content -LiteralPath $script:local -Raw) | Should -Match "SSH session"
    }

    It "no VS Code: core.editor is left unset" {
        & $script:initLocal -Force *> $null
        & git config --file $script:local --get core.editor 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It "-Force keeps the editor an existing ~/.gitconfig.local sets" {
        $env:GITCONFIG_CODE_BIN = "code"
        [IO.File]::WriteAllText($script:local, "[core]`n`teditor = vim`n")
        & $script:initLocal -Force *> $null
        @(& git config --file $script:local --get-all core.editor) | Should -Be @("vim")
    }
}
