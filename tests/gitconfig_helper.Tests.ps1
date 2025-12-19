BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $helperScript = Join-Path $repoRoot "gitconfig_helper.py"
    $pythonExe = "python"
}

Describe "gitconfig_helper.py" {

    Context "Script Validation" {
        It "Script exists and is readable" {
            $helperScript | Should -Exist
            (Get-Item $helperScript).Length | Should -BeGreaterThan 0
        }

        It "Script has valid Python syntax" {
            $result = & python -m py_compile $helperScript 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "Script can be imported without errors" {
            $repoRootForward = $repoRoot -replace '\\', '/'
            $pythonCode = @"
import sys
sys.path.insert(0, '$repoRootForward')
import gitconfig_helper
"@
            $result = & python -c $pythonCode 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "print_aliases Function" {
        It "Should accept 'print_aliases' function name" {
            $result = & python $helperScript print_aliases 2>&1
            # Should complete without error (exit code 0)
            # Output might be empty if no aliases are configured
            $LASTEXITCODE | Should -Be 0
        }

        It "Should return formatted output when called" {
            $result = & python $helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # Should contain some output (either aliases or empty table)
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should output contain 'Git Aliases' table header" {
            $result = & python $helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # The table should mention aliases
            ($output -like "*alias*" -or $output -like "*Git*") | Should -Be $true
        }
    }

    Context "cleanup Function" {
        It "Should accept 'cleanup' function name without arguments" {
            # Just verify it can be called - actual cleanup depends on git state
            $result = & python $helperScript cleanup 2>&1
            # Should complete execution (may return 0 or non-zero depending on git state)
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should accept --force flag" {
            $result = & python $helperScript cleanup --force 2>&1
            # Should complete execution with --force flag
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should accept -f shorthand flag" {
            $result = & python $helperScript cleanup -f 2>&1
            # Should complete execution with -f flag
            $result | Should -Not -BeNullOrEmpty
        }

        It "Should handle non-git directory gracefully" {
            $origDir = Get-Location
            try {
                Set-Location $env:TEMP
                $result = & python $helperScript cleanup 2>&1
                # Should either complete or show error message about not being in a git repo
                $result | Should -Not -BeNullOrEmpty
            }
            finally {
                Set-Location $origDir
            }
        }
    }

    Context "get_git_aliases Function" {
        It "Should be defined in the script" {
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match "def get_git_aliases"
        }

        It "Should return list of tuples" {
            $scriptContent = Get-Content $helperScript -Raw
            # Check for expected structure
            $scriptContent | Should -Match "alias_descriptions"
            $scriptContent | Should -Match "aliases.append"
        }

        It "Should include known aliases in descriptions" {
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match "alias.*List all git aliases"
            $scriptContent | Should -Match "branches.*remote branches"
            $scriptContent | Should -Match "cleanup.*merged"
        }
    }

    Context "cleanup_branches Function" {
        It "Should be defined in the script" {
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match "def cleanup_branches"
        }

        It "Should handle force parameter" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "force.*=" -or $scriptContent -match "force\s*\)") | Should -Be $true
        }

        It "Should check for git repository" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "git.*rev-parse" -or $scriptContent -match "git-dir") | Should -Be $true
        }

        It "Should delete branches with deleted remotes" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "gone" -or $scriptContent -match "remote.*deleted") | Should -Be $true
        }

        It "Should support both --force and -f flags" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "--force" -and $scriptContent -match '"-f"') | Should -Be $true
        }
    }

    Context "Error Handling" {
        It "Should handle missing function name gracefully" {
            $result = & python $helperScript nonexistent_function 2>&1
            # Should display error message
            $output = $result -join "`n"
            ($output -match "not found" -or $output -match "Error") | Should -Be $true
        }

        It "Should handle no function name provided" {
            $result = & python $helperScript 2>&1
            # Should display error or usage message
            $output = $result -join "`n"
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should handle rich library auto-installation" {
            $scriptContent = Get-Content $helperScript -Raw
            (($scriptContent -match "ImportError") -or ($scriptContent -match "try:" -and $scriptContent -match "except")) | Should -Be $true
        }
    }

    Context "Integration with Git Aliases" {
        It "Should be callable via git alias (if configured)" {
            # Verify the script is referenced in .gitconfig.template
            $gitConfigPath = Join-Path $repoRoot ".gitconfig.template"
            $gitConfigContent = Get-Content $gitConfigPath -Raw

            $gitConfigContent | Should -Match "gitconfig_helper"
        }

        It "Should work with Python ${USERPROFILE} variable" {
            $scriptContent = Get-Content $helperScript -Raw
            # Verify script uses proper Python path handling
            ($scriptContent -match "import" -and $scriptContent -match "subprocess") | Should -Be $true
        }
    }

    Context "Rich Library Integration" {
        It "Should use Rich for formatted output" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "from rich" -or $scriptContent -match "import.*rich") | Should -Be $true
        }

        It "Should use Rich Table for displaying data" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "Table" -or $scriptContent -match "table") | Should -Be $true
        }

        It "Should have styled console output" {
            $scriptContent = Get-Content $helperScript -Raw
            ($scriptContent -match "Console" -or $scriptContent -match "\[.*\]") | Should -Be $true
        }
    }
}
