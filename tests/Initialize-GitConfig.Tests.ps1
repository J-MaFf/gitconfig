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
            # Aliases should use {{REPO_PATH}} placeholder
            $templateContent | Should -Match 'alias\s*=.*\{\{REPO_PATH\}\}'
        }
    }

    Context "Config Generation" {
        BeforeAll {
            # Generate config for testing
            & $script:scriptPath -Force | Out-Null
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
            # Git config requires forward slashes, not backslashes.
            # The helper is now invoked via the py/python3/python loop as
            # `exec "$p" <path>/gitconfig_helper.py`, so match the absolute
            # path directly (same pattern as "should contain absolute paths").
            if ($generatedContent -match '((?:[A-Za-z]:)?/[^\s"]*gitconfig_helper\.py)') {
                $helperPath = $matches[1]
                $helperPath | Should -Not -Match '\\'
            }
        }

        It "Generated config should have valid INI format" {
            # Git should be able to parse it without errors
            $result = & git config -f $script:outputPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Generated config should contain absolute paths" {
            $generatedContent = Get-Content $script:outputPath -Raw
            # The helper is invoked as `exec "$p" <abs-path>/gitconfig_helper.py` (the
            # py/python3/python loop), so assert an absolute path to it - placeholder
            # substituted, not relative. Matches Unix (/path/to/gitconfig_helper.py)
            # and Windows (C:/path/to/gitconfig_helper.py).
            $generatedContent | Should -Match '(?:[A-Za-z]:)?/[^\s"]*gitconfig_helper\.py'
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

            # Check backup was created
            $backupPath = "$($script:outputPath).bak"
            $backupPath | Should -Exist

            # Verify backup contains old content
            $backupContent = Get-Content $backupPath -Raw
            $backupContent | Should -Match "# Test config"

            # Clean up backup
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force
            }
        }
    }

    Context "Error Handling" {
        It "Should fail gracefully if template is missing" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match 'Template not found'
        }
    }
}
