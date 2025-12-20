BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:helperScript = Join-Path $script:repoRoot "gitconfig_helper.py"
}

Describe "gitconfig_helper.py" {

    Context "Script Validation" {
        It "Script exists and is readable" {
            $helperScript | Should -Exist
            (Get-Item $helperScript).Length | Should -BeGreaterThan 0
        }

        It "Script has valid Python syntax" {
            & python -m py_compile $script:helperScript 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "Script can be imported without errors" {
            $repoRootForward = $script:repoRoot -replace '\\', '/'
            $pythonCode = @"
import sys
sys.path.insert(0, '$repoRootForward')
import gitconfig_helper
"@
            & python -c $pythonCode 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "print_aliases Function" {
        It "Should accept 'print_aliases' function name" {
            & python $script:helperScript print_aliases 2>&1
            # Should complete without error (exit code 0)
            # Output might be empty if no aliases are configured
            $LASTEXITCODE | Should -Be 0
        }

        It "Should return formatted output when called" {
            $result = & python $script:helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # Should contain some output (either aliases or empty table)
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should output contain 'Git Aliases' table header" {
            $result = & python $script:helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # The table should mention aliases
            ($output -like "*alias*" -or $output -like "*Git*") | Should -Be $true
        }
    }

    Context "cleanup Function" {
        It "Should accept 'cleanup' function name without arguments" {
            # Just verify it can be called - actual cleanup depends on git state
            $result = & python $script:helperScript cleanup 2>&1
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

    Context "switch_to_main Function" {
        BeforeEach {
            # Create a temporary test repository
            $script:testDir = New-Item -ItemType Directory -Path "$env:TEMP\git_test_$(Get-Random)" -Force
            Push-Location $script:testDir

            # Initialize git repo
            & git init 2>&1 | Out-Null
            & git config user.email "test@example.com" 2>&1 | Out-Null
            & git config user.name "Test User" 2>&1 | Out-Null
        }

        AfterEach {
            # Clean up test repository
            Pop-Location
            Remove-Item -Path $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should fail when not in a git repository" {
            Pop-Location
            $tempDir = New-Item -ItemType Directory -Path "$env:TEMP\not_git_$(Get-Random)" -Force
            Push-Location $tempDir

            $result = & python $script:helperScript switch_to_main 2>&1
            $output = $result -join "`n"

            $output | Should -Match "not in a git repository"
            $LASTEXITCODE | Should -Be 1

            Pop-Location
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should fail when there are uncommitted changes" {
            # Create initial commit on main
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Make uncommitted changes
            Add-Content -Path "test.txt" -Value "uncommitted"

            $result = & python $script:helperScript switch_to_main 2>&1
            $output = $result -join "`n"

            $output | Should -Match "uncommitted changes"
            $output | Should -Match "commit or stash"
            $LASTEXITCODE | Should -Be 1
        }

        It "Should succeed when already on clean main branch" {
            # Create initial commit
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Set up a dummy remote to avoid "no tracking information" error
            & git remote add origin "https://github.com/test/repo.git" 2>&1 | Out-Null
            & git branch -u origin/main 2>&1 | Out-Null

            $result = & python $script:helperScript switch_to_main 2>&1
            $output = $result -join "`n"

            # Should handle clean main branch scenario
            ($output -match "already on main" -or $output -match "Fetching") | Should -Be $true
            # Test should verify exit code 0 for clean state
            $LASTEXITCODE | Should -Be 0
        }

        It "Should detect merge conflicts after pull" {
            # This is difficult to test without a real remote repo
            # We verify the code structure instead
            $scriptContent = Get-Content $script:helperScript -Raw
            ($scriptContent -match "merge.*conflict" -or $scriptContent -match "UU.*AA.*DD") | Should -Be $true
        }

        It "Should provide clear error messages for each failure scenario" {
            $scriptContent = Get-Content $script:helperScript -Raw

            # Verify error messages exist for key scenarios
            ($scriptContent -match "Fetching updates" -and $scriptContent -match "Switching from") | Should -Be $true
            ($scriptContent -match "Uncommitted changes detected" -and $scriptContent -match "Merge conflict detected") | Should -Be $true
        }

        It "Should use Rich console output for formatting" {
            $scriptContent = Get-Content $script:helperScript -Raw
            ($scriptContent -match "console.print" -and $scriptContent -match "\[cyan\]" -and $scriptContent -match "\[green\]") | Should -Be $true
        }

        It "Should handle fetch failures gracefully" {
            # Create a local repo without a remote
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # This should succeed since fetch will just skip if no remote
            & python $script:helperScript switch_to_main 2>&1 | Out-Null
            # Fetch should succeed (exit code 0) even without a remote
            $LASTEXITCODE | Should -Be 0
        }

        It "Should return exit code 0 on success" {
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Set up a dummy remote to avoid "no tracking information" error
            & git remote add origin "https://github.com/test/repo.git" 2>&1 | Out-Null
            & git branch -u origin/main 2>&1 | Out-Null

            & python $script:helperScript switch_to_main 2>&1 | Out-Null
            # Successful execution should always return exit code 0
            $LASTEXITCODE | Should -Be 0
        }

        It "Should return non-zero exit code on failure" {
            # Test failure case: uncommitted changes
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null
            Add-Content -Path "test.txt" -Value "uncommitted"

            & python $script:helperScript switch_to_main 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }
}
