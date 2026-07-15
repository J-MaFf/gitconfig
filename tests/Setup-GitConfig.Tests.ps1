# Discovery-time platform check. Pester evaluates an It's -Skip argument during
# Discovery (before BeforeAll runs), so this must live at script scope here, not
# in BeforeAll.
$script:onWindows = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\windows version\install.ps1"
    $script:initGitScript = Join-Path $script:repoRoot "scripts\windows version\Initialize-GitConfig.ps1"
    $script:initLocalScript = Join-Path $script:repoRoot "scripts\windows version\Initialize-LocalConfig.ps1"

    # Sandbox HOME and git's config scopes so nothing here touches the real machine
    # (#162). We deliberately do NOT run install.ps1: it mutates system-global state
    # a HOME redirect cannot sandbox (the login scheduled task via Cleanup, and the
    # real $PROFILE keybinding). The artifacts install produces - .gitconfig and
    # .gitconfig.local - come from the generators below, which are safe against a
    # temp HOME. Full install / symlink / scheduled-task coverage lives in
    # Integration.Tests.ps1 (Tag 'Integration', excluded from the default run).
    $script:savedUserProfile = $env:USERPROFILE
    $script:savedHome = $env:HOME
    $script:savedGlobal = $env:GIT_CONFIG_GLOBAL
    $script:savedSystem = $env:GIT_CONFIG_SYSTEM

    $script:testHome = Join-Path $TestDrive "home"
    New-Item -ItemType Directory -Path $script:testHome -Force | Out-Null
    $env:USERPROFILE = $script:testHome
    $env:HOME = $script:testHome
    $env:GIT_CONFIG_GLOBAL = Join-Path $script:testHome ".gitconfig"
    $env:GIT_CONFIG_SYSTEM = Join-Path $script:testHome "no-system-config"

    # Generate the config artifacts into the sandbox (Windows-only scripts).
    # Recompute the platform check here: the discovery-time $script:onWindows used by
    # -Skip does not carry into the Run-phase BeforeAll.
    $isWindowsRun = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
    if ($isWindowsRun) {
        & $script:initGitScript -Force | Out-Null
        & $script:initLocalScript -Force | Out-Null
    }
}

AfterAll {
    $env:USERPROFILE = $script:savedUserProfile
    $env:HOME = $script:savedHome
    $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
    $env:GIT_CONFIG_SYSTEM = $script:savedSystem
}

Describe "install.ps1" {

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "param\s*\(\s*\[switch\]\`$Force"
        }

        It "Should accept -NoTask parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\`$NoTask"
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\`$Help"
        }
    }

    Context "Python Dependencies" {
        # The install logic now lives in the shared Install-PythonDeps routine
        # (scripts/windows version/Functions.ps1), driven by the pyproject.toml
        # manifest. install.ps1 just delegates to it.
        It "Should delegate Python dependency install to the shared Install-PythonDeps routine" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "Install-PythonDeps"
        }

        It "Should declare 'rich' (required) in pyproject.toml" {
            $pyproject = Get-Content (Join-Path $script:repoRoot "pyproject.toml") -Raw
            $pyproject | Should -Match "rich"
        }

        It "The shared routine should pip-install deps and warn gracefully without pip" {
            $functions = Get-Content (Join-Path $script:repoRoot "scripts\windows version\Functions.ps1") -Raw
            $functions | Should -Match "pip install"
            $functions | Should -Match "\[WARN\].*pip"
        }

        It "STEP 7 verification should reuse Resolve-Python, not a separate first-hit Get-Command chain" {
            # Regression for #200: a standalone `Get-Command py / python3 / python`
            # chain can return a 0-byte WindowsApps stub that Resolve-Python
            # (used by STEP 6's Install-PythonDeps) deliberately treats as a
            # last resort, not a first choice - producing spurious
            # "[WARN] Python 'rich' not importable" right after STEP 6 succeeded
            # via the correctly resolved interpreter.
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "(?m)^\s*\`$pyCmd\s*=\s*Resolve-Python\s*$"
            $scriptContent | Should -Not -Match "elseif\s*\(Get-Command\s+python3"
        }
    }

    Context "Config Generation" {
        It "Should generate .gitconfig in home directory" -Skip:(-not $script:onWindows) {
            (Join-Path $script:testHome ".gitconfig") | Should -Exist
        }

        It "Generated .gitconfig should not be a symlink" -Skip:(-not $script:onWindows) {
            $item = Get-Item (Join-Path $script:testHome ".gitconfig")
            $item.LinkType | Should -Not -Be "SymbolicLink"
        }

        It "Generated .gitconfig should have no placeholders" -Skip:(-not $script:onWindows) {
            $content = Get-Content (Join-Path $script:testHome ".gitconfig") -Raw
            $content | Should -Not -Match '\{\{REPO_PATH\}\}'
            $content | Should -Not -Match '\{\{HOME_DIR\}\}'
        }
    }

    Context ".gitconfig.local Generation" {
        # Only assertions about content that actually lives in .gitconfig.local.
        # gpg.format / commit.gpgsign / user.signingKey come from the main
        # .gitconfig (template), so they are verified in "Git Configuration" below
        # via the effective config, not by grepping this file.
        It "Should create .gitconfig.local file" -Skip:(-not $script:onWindows) {
            (Join-Path $script:testHome ".gitconfig.local") | Should -Exist
        }

        It "Should have valid INI format" -Skip:(-not $script:onWindows) {
            $localConfigPath = Join-Path $script:testHome ".gitconfig.local"
            $result = & git config -f $localConfigPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should include [gpg ssh] program path" -Skip:(-not $script:onWindows) {
            $content = Get-Content (Join-Path $script:testHome ".gitconfig.local") -Raw
            $content | Should -Match '\[gpg\s+"ssh"\]'
            $content | Should -Match 'op-ssh-sign\.exe'
        }

        It "Should use forward slashes in Windows paths" -Skip:(-not $script:onWindows) {
            $content = Get-Content (Join-Path $script:testHome ".gitconfig.local") -Raw
            # op-ssh-sign.exe path should use forward slashes for git config compatibility
            $content | Should -Match 'C:/Users/.*/AppData/.*/op-ssh-sign\.exe'
        }

        It "Should include [safe] directory entries" -Skip:(-not $script:onWindows) {
            $content = Get-Content (Join-Path $script:testHome ".gitconfig.local") -Raw
            $content | Should -Match '\[safe\]'
            $content | Should -Match 'directory\s*='
        }
    }

    Context "Git Configuration (effective)" {
        # Read the effective config from the sandboxed GIT_CONFIG_GLOBAL (the
        # generated .gitconfig + its included .gitconfig.local). Push-Location into
        # the sandbox (not a git repo) so no repo-local config can shadow these.
        BeforeAll { Push-Location $script:testHome }
        AfterAll { Pop-Location }

        It "Should set gpg.format to ssh" -Skip:(-not $script:onWindows) {
            (& git config --get gpg.format 2>$null) | Should -Be "ssh"
        }

        It "Should set commit.gpgsign to true" -Skip:(-not $script:onWindows) {
            (& git config --get commit.gpgsign 2>$null) | Should -Be "true"
        }

        It "Should set user.signingKey" -Skip:(-not $script:onWindows) {
            $result = & git config --get user.signingKey 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "ssh-ed25519"
        }

        It "Should point gpg.ssh.program to op-ssh-sign.exe" -Skip:(-not $script:onWindows) {
            $result = & git config --get gpg.ssh.program 2>$null
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match "op-ssh-sign\.exe"
        }
    }
}
