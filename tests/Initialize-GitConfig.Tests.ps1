BeforeAll {
    # Setup variables
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\Initialize-GitConfig.ps1"
    $script:templatePath = Join-Path $script:repoRoot ".gitconfig.template"
    $script:testHome = $env:USERPROFILE
    if (-not $script:testHome) {
        $script:testHome = $env:HOME  # Unix/Linux fallback
    }
    $script:outputPath = Join-Path $script:testHome ".gitconfig"
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
            # Git config requires forward slashes, not backslashes
            if ($generatedContent -match 'python\s+([^\s]+)') {
                $pythonPath = $matches[1]
                $pythonPath | Should -Not -Match '\\'
            }
        }

        It "Generated config should have valid INI format" {
            # Git should be able to parse it without errors
            $result = & git config -f $script:outputPath --list 2>$null
            $result | Should -Not -BeNullOrEmpty
        }

        It "Generated config should contain absolute paths" {
            $generatedContent = Get-Content $script:outputPath -Raw
            # Should have actual repository path, not relative or placeholder
            # Matches both Unix (/path/to/gitconfig_helper.py) and Windows (C:/path/to/gitconfig_helper.py)
            $generatedContent | Should -Match 'python\s+[A-Za-z]?:?/.*gitconfig_helper\.py'
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
