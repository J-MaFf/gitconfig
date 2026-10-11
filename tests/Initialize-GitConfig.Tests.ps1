BeforeAll {
    # Setup variables
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\windows version\Initialize-GitConfig.ps1"
    $script:templatePath = Join-Path $script:repoRoot ".gitconfig.template"

    # Sandbox HOME so generation never touches the real ~/.gitconfig (#162).
    # Initialize-GitConfig.ps1 reads $env:USERPROFILE at runtime, so redirecting it
    # (plus HOME and git's global/system config) points every write at TestDrive.
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

    $script:outputPath = Join-Path $script:testHome ".gitconfig"
}

AfterAll {
    $env:USERPROFILE = $script:savedUserProfile
    $env:HOME = $script:savedHome
    $env:GIT_CONFIG_GLOBAL = $script:savedGlobal
    $env:GIT_CONFIG_SYSTEM = $script:savedSystem
}

Describe "Initialize-GitConfig.ps1" {

    Context "Script Parameters" {
        It "Should accept -Force parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "param\s*\(\s*\[switch\]\`$Force"
        }

        It "Should accept -Help parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match "\[switch\]\`$Help"
        }
    }

    Context "Template File" {
        It "Should have .gitconfig.template file" {
            $script:templatePath | Should -Exist
        }

        It "Template should contain placeholders" {
            $templateContent = Get-Content $script:templatePath -Raw
            $templateContent | Should -Match '\{\{REPO_PATH\}\}'
            $templateContent | Should -Match '\{\{HOME_DIR\}\}'
        }

        It "Template should not contain hardcoded paths" {
            $templateContent = Get-Content $script:templatePath -Raw
            # Should not have Windows-style absolute paths like C:\Users\username
            $templateContent | Should -Not -Match 'C:\\Users\\'
            $templateContent | Should -Not -Match 'C:/Users/'
        }

        It "Template should have [include] section for .gitconfig.local" {
            $templateContent = Get-Content $script:templatePath -Raw
            $templateContent | Should -Match '\[include\]'
            $templateContent | Should -Match 'path\s*=\s*~\/\.gitconfig\.local'
        }

        It "Template should have [user] section" {
            $templateContent = Get-Content $script:templatePath -Raw
            $templateContent | Should -Match '\[user\]'
            $templateContent | Should -Match 'name\s*='
            $templateContent | Should -Match 'email\s*='
        }

        It "Template should have [alias] section with placeholders" {
            $templateContent = Get-Content $script:templatePath -Raw
            $templateContent | Should -Match '\[alias\]'
            # The helper dispatcher (h) reaches the helper through the
            # {{REPO_PATH}} placeholder; the other helper aliases go through h.
            $templateContent | Should -Match '(?m)^\s*h\s*=.*\{\{REPO_PATH\}\}'
            $templateContent | Should -Match '(?m)^\s*alias\s*=\s*!git h print_aliases'
        }
    }

    Context "Config Generation" {
        BeforeAll {
            # Generate config for testing
            & $script:scriptPath -Force | Out-Null

            # Initialize-GitConfig.ps1 writes {{REPO_PATH}} as the repo root with
            # backslashes turned into forward slashes.
            $script:expectedHelperPath = ($script:repoRoot -replace '\\', '/') + '/gitconfig_helper.py'

            # Every path the generated config uses to reach the helper: the
            # single-quoted word that ends in gitconfig_helper.py (quoted so a
            # repo path with spaces stays one argument, #231).
            function Get-HelperReference([string]$Content) {
                [regex]::Matches($Content, "'([^']*gitconfig_helper\.py)'") | ForEach-Object { $_.Groups[1].Value }
            }
        }

        It "Should generate .gitconfig in home directory" {
            $script:outputPath | Should -Exist
        }

        It "Generated config should have no placeholders" {
            $generatedContent = Get-Content $script:outputPath -Raw
            $generatedContent | Should -Not -Match '\{\{REPO_PATH\}\}'
            $generatedContent | Should -Not -Match '\{\{HOME_DIR\}\}'
        }

        It "Generated config should use forward slashes in paths" {
            $generatedContent = Get-Content $script:outputPath -Raw
            # Git config requires forward slashes, not backslashes. Check every
            # helper reference is the whole repo path in forward-slash form; a
            # looser pattern also matched just "/gitconfig_helper.py" (#262).
            $helperRefs = @(Get-HelperReference $generatedContent)
            $helperRefs.Count | Should -BeGreaterThan 0
            foreach ($ref in $helperRefs) {
                $ref | Should -Not -Match '\\'
                $ref | Should -BeExactly $script:expectedHelperPath
            }
        }

        It "Generated config should have valid INI format" {
            # Git should be able to parse it without errors
            $result = & git config -f $script:outputPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Generated config should contain absolute paths" {
            $generatedContent = Get-Content $script:outputPath -Raw
            # The helper is invoked as `exec "$p" '<abs-path>/gitconfig_helper.py'`
            # (the py/python3/python loop in h), so assert each reference is the absolute path
            # to this repo's helper - placeholder substituted, not relative (#262).
            [System.IO.Path]::IsPathRooted($script:expectedHelperPath) | Should -BeTrue
            $helperRefs = @(Get-HelperReference $generatedContent)
            $helperRefs.Count | Should -BeGreaterThan 0
            foreach ($ref in $helperRefs) { $ref | Should -BeExactly $script:expectedHelperPath }
        }

        It "Generated config should preserve [include] section" {
            $generatedContent = Get-Content $script:outputPath -Raw
            $generatedContent | Should -Match '\[include\]'
            $generatedContent | Should -Match 'path\s*=\s*~\/\.gitconfig\.local'
        }

        It "Generated config should preserve [user] section" {
            $generatedContent = Get-Content $script:outputPath -Raw
            $generatedContent | Should -Match '\[user\]'
            $generatedContent | Should -Match 'name\s*='
            $generatedContent | Should -Match 'email\s*='
        }

        It "Generated config should preserve [alias] section" {
            $generatedContent = Get-Content $script:outputPath -Raw
            $generatedContent | Should -Match '\[alias\]'
        }
    }

    Context "Backup Handling" {
        It "Should create backup when overwriting existing .gitconfig" {
            # Create a dummy .gitconfig
            $dummyContent = "# Test config"
            Set-Content -Path $script:outputPath -Value $dummyContent -Force

            # Run generation with Force
            & $script:scriptPath -Force | Out-Null

            # Check a timestamped backup was created
            $backups = @(Get-ChildItem -LiteralPath $script:testHome -Force -Filter ".gitconfig.bak.*")
            $backups.Count | Should -Be 1
            $backups[0].Name | Should -Match '^\.gitconfig\.bak\.\d{8}-\d{6}$'

            # Verify backup contains old content
            $backupContent = Get-Content $backups[0].FullName -Raw
            $backupContent | Should -Match "# Test config"

            # Clean up backup
            $backups | Remove-Item -Force
        }
    }

    Context "Overwrite prompt (#256)" {
        BeforeAll {
            # A global function shadows the Read-Host cmdlet inside the script
            # (which runs in this session): it records the prompt and answers
            # with $global:igcAnswer, so no test ever waits for input.
            function global:Read-Host {
                param([string]$Prompt)
                $global:igcPrompts += $Prompt
                $global:igcAnswer
            }
        }

        AfterAll {
            Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
            Remove-Variable igcPrompts, igcAnswer -Scope Global -ErrorAction SilentlyContinue
        }

        BeforeEach {
            $global:igcPrompts = @()
            $global:igcAnswer = 'n'
            Get-ChildItem -LiteralPath $script:testHome -Force -Filter ".gitconfig*" | Remove-Item -Force
        }

        It "Should not prompt when ~/.gitconfig already matches the template" {
            & $script:scriptPath -Force | Out-Null
            $before = Get-Content $script:outputPath -Raw

            & $script:scriptPath *> $null

            $LASTEXITCODE | Should -Be 0
            $global:igcPrompts.Count | Should -Be 0
            (Get-Content $script:outputPath -Raw) | Should -Be $before
            @(Get-ChildItem -LiteralPath $script:testHome -Force -Filter ".gitconfig.bak*").Count | Should -Be 0
        }

        It "Should still prompt before replacing a ~/.gitconfig that differs, and keep it on 'n'" {
            Set-Content -Path $script:outputPath -Value "# hand-written config"

            & $script:scriptPath *> $null

            $LASTEXITCODE | Should -Be 0
            $global:igcPrompts.Count | Should -Be 1
            $global:igcPrompts[0] | Should -Match 'Overwrite'
            (Get-Content $script:outputPath -Raw) | Should -Match '# hand-written config'
            @(Get-ChildItem -LiteralPath $script:testHome -Force -Filter ".gitconfig.bak*").Count | Should -Be 0
        }

        It "Should replace a ~/.gitconfig that differs when the answer is 'y'" {
            Set-Content -Path $script:outputPath -Value "# hand-written config"
            $global:igcAnswer = 'y'

            & $script:scriptPath *> $null

            $LASTEXITCODE | Should -Be 0
            $global:igcPrompts.Count | Should -Be 1
            (Get-Content $script:outputPath -Raw) | Should -Not -Match '# hand-written config'
            (Get-Content $script:outputPath -Raw) | Should -Match '\[alias\]'
        }
    }

    Context "Encoding and path substitution (#230)" {
        # Windows PowerShell 5.1 read the template and wrote ~/.gitconfig as
        # ANSI, and -replace expanded a '$1' or '$&' in the repo path. Runs a
        # copy of the script from a repo folder whose name has both, with a
        # home folder whose name is non-ASCII.
        BeforeAll {
            # Spelled with char codes so this file stays ASCII: e-acute and a CJK character.
            $nonAscii = "Jos" + [char]0xE9 + " " + [char]0x4E2D
            $script:copyRepo = Join-Path $TestDrive ('repo ' + $nonAscii + ' $1 $& $_')
            $copyDir = Join-Path (Join-Path $script:copyRepo "scripts") "windows version"
            New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
            Copy-Item -LiteralPath $script:scriptPath -Destination $copyDir
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $script:scriptPath) "Functions.ps1") -Destination $copyDir
            Copy-Item -LiteralPath $script:templatePath -Destination $script:copyRepo
            $script:copyScript = Join-Path $copyDir "Initialize-GitConfig.ps1"
            $script:encHome = Join-Path $TestDrive ("home " + $nonAscii)
        }

        BeforeEach {
            if (Test-Path -LiteralPath $script:encHome) { Remove-Item -LiteralPath $script:encHome -Recurse -Force }
            New-Item -ItemType Directory -Path $script:encHome | Out-Null
            $env:USERPROFILE = $script:encHome
            $env:HOME = $script:encHome
        }

        AfterEach {
            $env:USERPROFILE = $script:testHome
            $env:HOME = $script:testHome
        }

        It "writes ~/.gitconfig as UTF-8 without a BOM, with the repo path copied as is" {
            & $script:copyScript -Force *> $null
            $LASTEXITCODE | Should -Be 0

            $out = Join-Path $script:encHome ".gitconfig"
            $bytes = [System.IO.File]::ReadAllBytes($out)
            $bytes[0] | Should -Not -Be 0xEF
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $text | Should -Not -Match '\{\{REPO_PATH\}\}'
            $repoForward = $script:copyRepo -replace '\\', '/'
            $text.Contains("$repoForward/gitconfig_helper.py") | Should -BeTrue
            # git reads the same path back (the helper aliases dispatch through
            # alias.h, which holds the path, #231).
            $alias = & git config --file $out --get alias.h
            ($alias -join "`n").Contains("$repoForward/gitconfig_helper.py") | Should -BeTrue
        }

        It "sees its own non-ASCII output as up to date on the next run" {
            & $script:copyScript -Force *> $null
            $before = [System.IO.File]::ReadAllBytes((Join-Path $script:encHome ".gitconfig"))

            $output = & $script:copyScript -Force *>&1 | Out-String

            $output | Should -Match 'already up to date'
            [System.IO.File]::ReadAllBytes((Join-Path $script:encHome ".gitconfig")) | Should -Be $before
            @(Get-ChildItem -LiteralPath $script:encHome -Force -Filter ".gitconfig.bak*").Count | Should -Be 0
        }
    }

    Context "Error Handling" {
        It "Should fail gracefully if template is missing" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match 'Template not found'
        }
    }
}
