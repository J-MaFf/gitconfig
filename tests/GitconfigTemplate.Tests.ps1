BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $repoRoot ".gitconfig.template"

    # The aliases that shell out to gitconfig_helper.py. Each must resolve the
    # Python interpreter as py -> python3 -> python so the Windows Microsoft
    # Store stub (which masquerades as python3) is never invoked first.
    $pythonAliases = @(
        @{ Alias = 'alias' }
        @{ Alias = 'cleanup' }
        @{ Alias = 'main' }
        @{ Alias = 'start' }
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
    }

    Context "<Alias>" -ForEach $pythonAliases {

        BeforeAll {
            # Grab the single definition line for this alias (e.g. "    cleanup = ...").
            $script:line = $templateLines | Where-Object { $_ -match "^\s*$Alias\s*=" } | Select-Object -First 1
        }

        It "is defined exactly once" {
            ($templateLines | Where-Object { $_ -match "^\s*$Alias\s*=" }).Count | Should -Be 1
        }

        It "tries 'py' before 'python3' and 'python'" {
            $line | Should -Match '\bpy\b'
            $pyIdx = $line.IndexOf(' py ')
            $py3Idx = $line.IndexOf('python3')
            $pyIdx | Should -BeGreaterThan -1 -Because "the Python Launcher 'py' must be a resolution candidate"
            $pyIdx | Should -BeLessThan $py3Idx -Because "py must be tried before the Microsoft Store stub 'python3'"
        }

        It "verifies the interpreter runs before using it (rejects the Store stub)" {
            $line | Should -Match "-c ''"
        }

        It "does not use the old python3-first resolution" {
            $line | Should -Not -Match 'command -v python3 >/dev/null &&'
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

    It "forwards arguments to the helper so 'git alias --plain' works" {
        $line = $script:templateLines | Where-Object { $_ -match '^\s*alias\s*=' } | Select-Object -First 1
        $line | Should -Match 'print_aliases \\"\$@\\"'
    }
}
