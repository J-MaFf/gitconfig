BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $repoRoot ".gitconfig.template"

    # The aliases that run gitconfig_helper.py. Each dispatches through the
    # single `h` alias (#231), which resolves the Python interpreter as
    # py -> python3 -> python so the Windows Microsoft Store stub (which
    # masquerades as python3) is never invoked first.
    $pythonAliases = @(
        @{ Alias = 'alias'; Subcommand = 'print_aliases' }
        @{ Alias = 'cleanup'; Subcommand = 'cleanup' }
        @{ Alias = 'main'; Subcommand = 'switch_to_main' }
        @{ Alias = 'start'; Subcommand = 'start' }
        @{ Alias = 'skill'; Subcommand = 'skill' }
        @{ Alias = 'issues'; Subcommand = 'issues' }
    )

    # Simple (non-helper) aliases added for the categorized browser. Each must be
    # defined exactly once in the template.
    $simpleAliases = @(
        @{ Alias = 's' }
        @{ Alias = 'lg' }
        @{ Alias = 'last' }
        @{ Alias = 'recent' }
        @{ Alias = 'find' }
        @{ Alias = 'amend' }
        @{ Alias = 'reword' }
        @{ Alias = 'undo' }
        @{ Alias = 'unstage' }
        @{ Alias = 'wip' }
        @{ Alias = 'nb' }
        @{ Alias = 'pushf' }
        @{ Alias = 'sync' }
        @{ Alias = 'pr' }
        @{ Alias = 'prs' }
    )
}

Describe ".gitconfig.template Python alias resolution" -Tag 'Unit' {

    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $script:templateLines = Get-Content (Join-Path $repoRoot ".gitconfig.template")
        # The single dispatcher every helper alias goes through (#231).
        $script:hLine = $templateLines | Where-Object { $_ -match '^\s*h\s*=' } | Select-Object -First 1
    }

    Context "the h dispatcher" {

        It "is defined exactly once" {
            ($templateLines | Where-Object { $_ -match '^\s*h\s*=' }).Count | Should -Be 1
        }

        It "tries 'py' before 'python3' and 'python'" {
            $hLine | Should -Match '\bpy\b'
            $pyIdx = $hLine.IndexOf(' py ')
            $py3Idx = $hLine.IndexOf('python3')
            $pyIdx | Should -BeGreaterThan -1 -Because "the Python Launcher 'py' must be a resolution candidate"
            $pyIdx | Should -BeLessThan $py3Idx -Because "py must be tried before the Microsoft Store stub 'python3'"
        }

        It "verifies the interpreter runs before using it (rejects the Store stub)" {
            $hLine | Should -Match "-c ''"
        }

        It "does not use the old python3-first resolution" {
            $hLine | Should -Not -Match 'command -v python3 >/dev/null &&'
        }

        It "quotes the helper path so a repo path with a space works (#231)" {
            $hLine | Should -Match "exec \\""\`$p\\"" '\{\{REPO_PATH\}\}/gitconfig_helper\.py' \\""\`$@\\"""
        }

        It "is the only alias with the find-a-Python loop" {
            ($templateLines | Where-Object { $_ -match 'for p in py python3 python' }).Count | Should -Be 1
        }
    }

    Context "<Alias>" -ForEach $pythonAliases {

        It "is defined exactly once" {
            ($templateLines | Where-Object { $_ -match "^\s*$Alias\s*=" }).Count | Should -Be 1
        }

        It "dispatches through 'git h <Subcommand>'" {
            $line = $templateLines | Where-Object { $_ -match "^\s*$Alias\s*=" } | Select-Object -First 1
            $line | Should -Match "^\s*$Alias\s*=\s*!git h $Subcommand\s*$"
        }
    }
}

Describe ".gitconfig.template simple aliases" -Tag 'Unit' {

    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $script:templateLines = Get-Content (Join-Path $repoRoot ".gitconfig.template")
    }

    Context "<Alias>" -ForEach $simpleAliases {

        It "is defined exactly once" {
            ($script:templateLines | Where-Object { $_ -match "^\s*$Alias\s*=" }).Count |
                Should -Be 1
        }
    }

    It "pushf pairs --force-with-lease with --force-if-includes (#251)" {
        # A bare --force-with-lease is disarmed by any background fetch; the
        # behavioural check lives in tests/shared/test_gitconfig_helper.py.
        $line = $script:templateLines | Where-Object { $_ -match '^\s*pushf\s*=' } | Select-Object -First 1
        $line | Should -Match '^\s*pushf\s*=\s*push\s'
        $line | Should -Match '--force-with-lease'
        $line | Should -Match '--force-if-includes'
        $line | Should -Not -Match '--force(\s|$)'
    }

    It "forwards arguments to the helper so 'git alias --plain' works" {
        # git appends an alias's arguments to its command, so `!git h
        # print_aliases` passes --plain on; h forwards them with "$@". The
        # behavioural check lives in tests/shared/test_gitconfig_helper.py.
        $line = $script:templateLines | Where-Object { $_ -match '^\s*alias\s*=' } | Select-Object -First 1
        $line | Should -Match '!git h print_aliases\s*$'
        $hLine = $script:templateLines | Where-Object { $_ -match '^\s*h\s*=' } | Select-Object -First 1
        $hLine | Should -Match 'gitconfig_helper\.py'' \\"\$@\\"'
    }

    It "unstage uses restore --staged, which works before the first commit (#231)" {
        $line = $script:templateLines | Where-Object { $_ -match '^\s*unstage\s*=' } | Select-Object -First 1
        $line | Should -Match '^\s*unstage\s*=\s*restore --staged --\s*$'
    }

    It "leaves machine-specific settings to ~/.gitconfig.local (#231)" {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $template = Join-Path $repoRoot ".gitconfig.template"
        foreach ($key in 'user.signingkey', 'commit.gpgsign', 'core.editor') {
            & git config --file $template --get $key | Out-Null
            $LASTEXITCODE | Should -Be 1 -Because "$key is machine-specific"
        }
        # And ~/.gitconfig.local is still included last, so its values win.
        $last = $script:templateLines | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | Select-Object -Last 1
        $last | Should -Match '^\s*path\s*=\s*~/\.gitconfig\.local\s*$'
    }

    It "localconfig defaults to --edit and forwards arguments (#263)" {
        # Bare 'git config --file X' exits 129 ("no action specified"). The
        # behavioural check lives in tests/shared/test_gitconfig_helper.py.
        $line = $script:templateLines | Where-Object { $_ -match '^\s*localconfig\s*=' } | Select-Object -First 1
        $line | Should -Match '\[ \$# -eq 0 \] && set -- --edit'
        $line | Should -Match 'git config --file ~/\.gitconfig\.local \\"\$@\\"'
    }
}
