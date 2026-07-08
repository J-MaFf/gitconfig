# Resolve the Python interpreter per the repo rule: py -> python3 -> python.
# Never bare `python` first — it's the WindowsApps stub on Windows and absent
# on macOS/Linux. Script-body functions exist only during Pester's discovery
# phase, so the same loop is inlined again in BeforeAll for the run phase.
function Resolve-TestPython {
    foreach ($name in 'py', 'python3', 'python') {
        if (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) {
            return $name
        }
    }
}

BeforeDiscovery { $script:python = Resolve-TestPython }

BeforeAll {
    # Inlined copy of Resolve-TestPython (discovery-only function; see above).
    $script:python = foreach ($name in 'py', 'python3', 'python') {
        if (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) {
            $name
            break
        }
    }
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:helperScript = Join-Path $script:repoRoot "gitconfig_helper.py"
    # Cross-platform temp root for throwaway git fixtures. $env:TEMP is
    # Windows-only; on macOS it's empty, which turned fixture paths into
    # unwritable root-level paths, left the fixture dirs null, and let the
    # fixture git commands run against the developer's checkout (#174).
    $script:tempRoot = [System.IO.Path]::GetTempPath()
}

# No interpreter anywhere -> skip the whole file with one clear reason instead
# of 28 confusing CommandNotFound failures.
Describe "gitconfig_helper.py" -Skip:(-not $script:python) {

    Context "Script Validation" {
        It "Script exists and is readable" {
            $helperScript | Should -Exist
            (Get-Item $helperScript).Length | Should -BeGreaterThan 0
        }

        It "Script has valid Python syntax" {
            & $script:python -m py_compile $script:helperScript 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "Script contains only ASCII characters" {
            # rich falls back to the cp1252 renderer on the legacy Windows
            # console, which raises UnicodeEncodeError on non-ASCII glyphs
            # (e.g. checkmarks, box-drawing). Keep the helper ASCII-only.
            $text = [System.IO.File]::ReadAllText($script:helperScript)
            $nonAscii = [regex]::Matches($text, '[^\x00-\x7F]')
            $detail = ($nonAscii |
                ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } |
                Select-Object -Unique) -join ', '
            $nonAscii.Count | Should -Be 0 -Because "non-ASCII glyphs crash rich on the legacy Windows console (found: $detail)"
        }

        It "Script can be imported without errors" {
            $repoRootForward = $script:repoRoot -replace '\\', '/'
            $pythonCode = @"
import sys
sys.path.insert(0, '$repoRootForward')
import gitconfig_helper
"@
            & $script:python -c $pythonCode 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "print_aliases Function" {
        It "Should accept 'print_aliases' function name" {
            & $script:python $script:helperScript print_aliases 2>&1
            # Should complete without error (exit code 0)
            # Output might be empty if no aliases are configured
            $LASTEXITCODE | Should -Be 0
        }

        It "Should return formatted output when called" {
            $result = & $script:python $script:helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # Should contain some output (either aliases or empty table)
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should output contain 'Git Aliases' table header" {
            $result = & $script:python $script:helperScript print_aliases 2>&1
            $output = $result -join "`n"
            # The table should mention aliases
            ($output -like "*alias*" -or $output -like "*Git*") | Should -Be $true
        }
    }

    Context "cleanup Function" {
        # `cleanup` is DESTRUCTIVE: it switches HEAD to main and (with --force/-f)
        # deletes local-only branches. Running it against the current directory
        # would maul the developer's working clone when the suite is run from a
        # checkout (this deleted a freshly created feat/ branch during PR #141).
        # So each test runs inside a throwaway repo, mirroring the switch_to_main /
        # update_all_main contexts below.
        BeforeEach {
            # Parent temp dir holds both the working repo and its bare "remote".
            # -ErrorAction Stop everywhere: if fixture setup fails for ANY
            # reason the test must abort here — a swallowed failure once let
            # these git commands run against the developer's checkout (#174).
            $script:cleanupPushed = $false
            $script:cleanupParent = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "git_cleanup_$(Get-Random)") -Force -ErrorAction Stop
            $repo = Join-Path $script:cleanupParent "repo"
            $bare = Join-Path $script:cleanupParent "remote.git"
            New-Item -ItemType Directory -Path $repo -ErrorAction Stop | Out-Null
            Push-Location $repo -ErrorAction Stop
            $script:cleanupPushed = $true

            & git init 2>&1 | Out-Null
            & git checkout -b main 2>&1 | Out-Null
            & git config user.email "test@example.com" 2>&1 | Out-Null
            & git config user.name "Test User" 2>&1 | Out-Null
            & git config commit.gpgsign false 2>&1 | Out-Null
            & git config init.defaultBranch main 2>&1 | Out-Null

            # Initial commit on main, wired to a bare remote so fetch/pull succeed.
            New-Item -Path "a.txt" -Value "a" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "init" 2>&1 | Out-Null
            & git init --bare $bare 2>&1 | Out-Null
            & git remote add origin $bare 2>&1 | Out-Null
            & git push -u origin main 2>&1 | Out-Null

            # A branch whose upstream was deleted ("[origin/...: gone]") -> cleanup
            # auto-deletes it even without --force (the merged-branch case).
            & git checkout -b feature-gone 2>&1 | Out-Null
            & git push -u origin feature-gone 2>&1 | Out-Null
            & git push origin --delete feature-gone 2>&1 | Out-Null

            # A local-only branch (never pushed, no upstream) -> only --force deletes it.
            & git checkout main 2>&1 | Out-Null
            & git branch local-only 2>&1 | Out-Null

            # Prune the stale remote-tracking ref so feature-gone reads as ": gone]".
            & git fetch -p 2>&1 | Out-Null
        }

        AfterEach {
            # Pop only what BeforeEach pushed — an unconditional Pop-Location
            # after a failed setup walks the stack past the caller's location.
            if ($script:cleanupPushed) { Pop-Location }
            if ($script:cleanupParent) {
                Remove-Item -Path $script:cleanupParent -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should accept 'cleanup' function name without arguments" {
            $result = & $script:python $script:helperScript cleanup 2>&1
            # Should complete execution (may return 0 or non-zero depending on git state)
            $result | Should -Not -BeNullOrEmpty

            # Without --force: the gone-remote branch is deleted, the local-only branch survives.
            $branches = & git branch --format='%(refname:short)'
            $branches | Should -Not -Contain "feature-gone"
            $branches | Should -Contain "local-only"
        }

        It "Should accept --force flag" {
            $result = & $script:python $script:helperScript cleanup --force 2>&1
            # Should complete execution with --force flag
            $result | Should -Not -BeNullOrEmpty

            # With --force: both the gone-remote branch AND the local-only branch are deleted.
            $branches = & git branch --format='%(refname:short)'
            $branches | Should -Not -Contain "feature-gone"
            $branches | Should -Not -Contain "local-only"
        }

        It "Should accept -f shorthand flag" {
            $result = & $script:python $script:helperScript cleanup -f 2>&1
            # Should complete execution with -f flag
            $result | Should -Not -BeNullOrEmpty

            # -f behaves exactly like --force: both branches are deleted.
            $branches = & git branch --format='%(refname:short)'
            $branches | Should -Not -Contain "feature-gone"
            $branches | Should -Not -Contain "local-only"
        }

        It "Should handle non-git directory gracefully" {
            $origDir = Get-Location
            try {
                Set-Location $script:tempRoot -ErrorAction Stop
                $result = & $script:python $helperScript cleanup 2>&1
                # Should either complete or show error message about not being in a git repo
                $result | Should -Not -BeNullOrEmpty
            }
            finally {
                Set-Location $origDir
            }
        }
    }

    Context "skill aliases" {
        It "no longer describes the removed dashed skill aliases in ALIAS_METADATA" {
            # #144 migrated skill-sync/skill-sync-status/skill-publish to the
            # `git skill <subcommand>` form, so the dashed names are gone from
            # ALIAS_METADATA (only the single `skill` row remains). Match on the
            # metadata-tuple form so the SKILL_SCRIPTS values (e.g. "skill-sync")
            # don't trip this assertion.
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Not -Match '"skill-sync":\s*\('
            $scriptContent | Should -Not -Match '"skill-sync-status":\s*\('
            $scriptContent | Should -Not -Match '"skill-publish":\s*\('
        }

        It "should no longer define the obsolete skill_push helper" {
            # skill publishing now lives in the claude-skills publish-skill script,
            # which opens a PR (its main is branch-protected); the helper must not
            # push straight to main any more.
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Not -Match "def skill_push"
        }

        It "defines list_skills and a skill dispatcher wired from __main__" {
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match 'def list_skills\('
            $scriptContent | Should -Match 'def skill\('
            $scriptContent | Should -Match 'function_name == "skill"'
        }

        It "skill dispatcher routes sync/status/publish to per-OS wrapper scripts" {
            # list runs in Python; sync/status/publish delegate to the claude-skills
            # wrapper scripts (.ps1 on Windows, .sh elsewhere) via SKILL_SCRIPTS.
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match 'SKILL_SCRIPTS'
            $scriptContent | Should -Match '"sync":\s*"skill-sync"'
            $scriptContent | Should -Match '"status":\s*"skill-sync-status"'
            $scriptContent | Should -Match '"publish":\s*"publish-skill"'
            $scriptContent | Should -Match 'def _run_skill_script\('
        }

        It "skill dispatcher prefers pwsh and gates PS7-only scripts (#188)" {
            # publish-skill.ps1 declares '#Requires -Version 7'; Windows PowerShell
            # 5.1 refuses to start it, so the dispatcher must resolve pwsh first.
            # Falling back to 'powershell' is allowed only for the WinPS-compatible
            # scripts (sync/status); PS7-only scripts get an actionable error.
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match 'shutil\.which\("pwsh"\)'
            $scriptContent | Should -Match 'PS7_SCRIPTS\s*=\s*\{"publish-skill"\}'
            $scriptContent | Should -Not -Match 'cmd = \["powershell"'
        }

        It "list_skills reads a description and a last-updated date per skill" {
            $scriptContent = Get-Content $helperScript -Raw
            $scriptContent | Should -Match 'def _read_skill_description\('
            $scriptContent | Should -Match 'def _skill_last_updated\('
            # last-updated uses the skills repo git log, short date format
            $scriptContent | Should -Match '--format=%cs'
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
            $result = & $script:python $helperScript nonexistent_function 2>&1
            # Should display error message
            $output = $result -join "`n"
            ($output -match "not found" -or $output -match "Error") | Should -Be $true
        }

        It "Should handle no function name provided" {
            $result = & $script:python $helperScript 2>&1
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
            # Create a temporary test repository. -ErrorAction Stop so a failed
            # setup aborts the test instead of letting the git fixture commands
            # below run against the developer's checkout (#174).
            $script:testDirPushed = $false
            $script:testDir = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "git_test_$(Get-Random)") -Force -ErrorAction Stop
            Push-Location $script:testDir -ErrorAction Stop
            $script:testDirPushed = $true

            # Initialize git repo
            & git init 2>&1 | Out-Null
            & git config user.email "test@example.com" 2>&1 | Out-Null
            & git config user.name "Test User" 2>&1 | Out-Null
        }

        AfterEach {
            # Clean up test repository; pop only what BeforeEach pushed.
            if ($script:testDirPushed) { Pop-Location }
            if ($script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should fail when not in a git repository" {
            # No Pop-Location first: Push-Location moves absolutely, and popping
            # the fixture frame here left AfterEach popping a frame it didn't
            # own, walking the CWD back into the developer's checkout.
            $tempDir = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "not_git_$(Get-Random)") -Force -ErrorAction Stop
            Push-Location $tempDir -ErrorAction Stop
            try {
                $result = & $script:python $script:helperScript switch_to_main 2>&1
                $output = $result -join "`n"

                $output | Should -Match "not in a git repository"
                $LASTEXITCODE | Should -Be 1
            }
            finally {
                Pop-Location
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should fail when there are uncommitted changes" {
            # Create initial commit on main
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Make uncommitted changes
            Add-Content -Path "test.txt" -Value "uncommitted"

            $result = & $script:python $script:helperScript switch_to_main 2>&1
            $output = $result -join "`n"

            $output | Should -Match "uncommitted changes"
            $output | Should -Match "commit or stash"
            $LASTEXITCODE | Should -Be 1
        }

        It "Should succeed when already on clean main branch" {
            # Create a bare repository to act as remote
            $bareRepo = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "bare_$(Get-Random)") -Force -ErrorAction Stop
            & git init --bare $bareRepo 2>&1 | Out-Null

            # Create initial commit
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Set up local bare repo as remote
            & git remote add origin $bareRepo 2>&1 | Out-Null
            & git push -u origin main 2>&1 | Out-Null
            & git branch -u origin/main 2>&1 | Out-Null

            $result = & $script:python $script:helperScript switch_to_main 2>&1
            $output = $result -join "`n"

            # Should show we're already on main or processing successfully
            ($output -match "already on main" -or $output -match "Fetching") | Should -Be $true
            # Test should verify exit code 0 for clean state
            $LASTEXITCODE | Should -Be 0

            # Cleanup
            Remove-Item $bareRepo -Recurse -Force -ErrorAction SilentlyContinue
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
            # Create a local repo on main branch without a valid remote
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null
            & git branch -M main 2>&1 | Out-Null

            # When there's no remote configured, fetch doesn't error but pull may
            # The function should handle this gracefully with appropriate exit code
            & $script:python $script:helperScript switch_to_main 2>&1 | Out-Null
            # With no valid remote, pull will fail and return exit code 1
            $LASTEXITCODE | Should -Be 1
        }

        It "Should return exit code 0 on success" {
            # Create a bare repository to act as remote
            $bareRepo = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "bare_$(Get-Random)") -Force -ErrorAction Stop
            & git init --bare $bareRepo 2>&1 | Out-Null

            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null

            # Set up local bare repo as remote
            & git remote add origin $bareRepo 2>&1 | Out-Null
            & git push -u origin main 2>&1 | Out-Null
            & git branch -u origin/main 2>&1 | Out-Null

            & $script:python $script:helperScript switch_to_main 2>&1 | Out-Null
            # Successful execution should always return exit code 0
            $LASTEXITCODE | Should -Be 0

            # Cleanup
            Remove-Item $bareRepo -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should return non-zero exit code on failure" {
            # Test failure case: uncommitted changes
            New-Item -Path "test.txt" -Value "test" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "Initial commit" 2>&1 | Out-Null
            Add-Content -Path "test.txt" -Value "uncommitted"

            & $script:python $script:helperScript switch_to_main 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }

    Context "update_all_main Function (git main --all)" {
        BeforeEach {
            # Parent directory that holds the child repos the sweep scans.
            # -ErrorAction Stop: abort on any setup failure rather than letting
            # the fixture git commands run against the developer's checkout (#174).
            $script:parentDir = New-Item -ItemType Directory -Path (Join-Path $script:tempRoot "git_all_$(Get-Random)") -Force -ErrorAction Stop

            # Clean child repo on main, wired to a bare remote so the
            # switch-to-main flow (fetch/pull/cleanup) succeeds.
            $script:cleanRepo = Join-Path $script:parentDir "clean"
            New-Item -ItemType Directory -Path $script:cleanRepo -ErrorAction Stop | Out-Null
            Push-Location $script:cleanRepo -ErrorAction Stop
            & git init 2>&1 | Out-Null
            & git checkout -b main 2>&1 | Out-Null
            & git config user.email "test@example.com" 2>&1 | Out-Null
            & git config user.name "Test User" 2>&1 | Out-Null
            & git config commit.gpgsign false 2>&1 | Out-Null
            New-Item -Path "a.txt" -Value "a" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "init" 2>&1 | Out-Null
            $bare = Join-Path $script:parentDir "clean_remote.git"
            & git init --bare $bare 2>&1 | Out-Null
            & git remote add origin $bare 2>&1 | Out-Null
            & git push -u origin main 2>&1 | Out-Null
            Pop-Location

            # Dirty child repo: on a feature branch with an uncommitted file.
            $script:dirtyRepo = Join-Path $script:parentDir "dirty"
            New-Item -ItemType Directory -Path $script:dirtyRepo -ErrorAction Stop | Out-Null
            Push-Location $script:dirtyRepo -ErrorAction Stop
            & git init 2>&1 | Out-Null
            & git checkout -b main 2>&1 | Out-Null
            & git config user.email "test@example.com" 2>&1 | Out-Null
            & git config user.name "Test User" 2>&1 | Out-Null
            & git config commit.gpgsign false 2>&1 | Out-Null
            New-Item -Path "a.txt" -Value "a" -Force | Out-Null
            & git add . 2>&1 | Out-Null
            & git commit -m "init" 2>&1 | Out-Null
            & git checkout -b feature-x 2>&1 | Out-Null
            Set-Content -Path "wip.txt" -Value "work in progress"   # untracked change
            Pop-Location
        }

        AfterEach {
            if ($script:parentDir) {
                Remove-Item -Path $script:parentDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should skip dirty repos with a triage report instead of switching them" {
            Push-Location $script:parentDir
            $result = & $script:python $script:helperScript switch_to_main --all 2>&1
            $output = $result -join "`n"
            Pop-Location

            # Dirty repo is reported as skipped with triage detail, not switched.
            $output | Should -Match "SKIPPED: uncommitted changes"
            $output | Should -Match "Skipped \(dirty\)"
            $output | Should -Match "working tree:"

            # The dirty repo's working tree was never touched: still on feature-x.
            (& git -C $script:dirtyRepo rev-parse --abbrev-ref HEAD).Trim() | Should -Be "feature-x"
        }

        It "Should classify outcomes separately and not count skips as failures" {
            Push-Location $script:parentDir
            $result = & $script:python $script:helperScript switch_to_main --all 2>&1
            $output = $result -join "`n"
            $exitCode = $LASTEXITCODE
            Pop-Location

            # Clean repo updated, dirty repo skipped, nothing failed.
            $output | Should -Match "Updated 1, skipped 1, failed 0"
            # Skips alone must not produce a non-zero exit code.
            $exitCode | Should -Be 0
        }
    }

    Context "Alias categorization" {
        BeforeAll { $script:src = Get-Content $script:helperScript -Raw }

        It "Defines CATEGORY_ORDER and ALIAS_METADATA" {
            $script:src | Should -Match "CATEGORY_ORDER"
            $script:src | Should -Match "ALIAS_METADATA"
        }

        It "Categorizes the new aliases" {
            $script:src | Should -Match '"pushf":\s*\("Branch & Sync"'
            $script:src | Should -Match '"pr":\s*\("GitHub"'
            $script:src | Should -Match '"amend":\s*\("Commit"'
            $script:src | Should -Match '"s":\s*\("Inspect"'
            $script:src | Should -Match '"skill":\s*\("Claude Skills"'
        }

        It "get_git_aliases returns (name, description, category) tuples" {
            $script:src | Should -Match "aliases\.append\(\(alias_name, description, category\)\)"
        }
    }

    Context "print_aliases plain/interactive modes" {
        BeforeAll { $script:src = Get-Content $script:helperScript -Raw }

        It "Gates the interactive browser on an interactive TTY" {
            $script:src | Should -Match "sys\.stdout\.isatty\(\)"
        }

        It "Supports a --plain flag wired through __main__" {
            $script:src | Should -Match "force_plain"
            $script:src | Should -Match '"--plain" in sys\.argv'
        }

        It "Renders a grouped table with a Category column when plain" {
            $result = & $script:python $script:helperScript print_aliases --plain 2>&1
            $output = $result -join "`n"
            $output | Should -Match "Git Aliases"
            $output | Should -Match "Category"
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Interactive browser (Textual)" {
        BeforeAll { $script:src = Get-Content $script:helperScript -Raw }

        It "Defines the browser builder and launcher" {
            $script:src | Should -Match "def _build_alias_app"
            $script:src | Should -Match "def _launch_alias_browser"
        }

        It "Imports textual lazily so the module loads without it" {
            # The textual import must live inside a function (indented), not at
            # module top level, so 'import gitconfig_helper' works without textual.
            $script:src | Should -Match "from textual\.app import App"
            $script:src | Should -Not -Match "(?m)^from textual"
            $script:src | Should -Not -Match "(?m)^import textual"
        }

        It "Falls back to the static table when the browser is unavailable" {
            $script:src | Should -Match "def _print_aliases_table"
        }

        It "Binds row navigation and selection keys" {
            $script:src | Should -Match '\("enter", "select"'
            $script:src | Should -Match '\("up", "cursor_up"'
            $script:src | Should -Match '\("down", "cursor_down"'
        }

        It "Selects via Enter, a table row click, and emits a git command" {
            $script:src | Should -Match "def _selected_command"
            $script:src | Should -Match "def on_input_submitted"
            $script:src | Should -Match "def on_data_table_row_selected"
            $script:src | Should -Match 'return f"git \{row\[0\]\}"'
        }

        It "Supports --select output via --out wired through __main__" {
            $script:src | Should -Match "select_out"
            $script:src | Should -Match '"--out" in sys\.argv'
        }

        It "Copies the selection to the clipboard when typed (no --out)" {
            $script:src | Should -Match "def _copy_to_clipboard"
            # Per-platform clipboard tools.
            $script:src | Should -Match "pbcopy"
            $script:src | Should -Match '"clip"'
            $script:src | Should -Match "xclip"
            # The typed-`git alias` path copies the choice rather than just printing it.
            $script:src | Should -Match "_copy_to_clipboard\(choice\)"
        }

        It "Stays silent in selection mode (no static table dumped to the tty)" {
            # --out is the keybinding path; with no TTY the browser is skipped and
            # nothing should be printed (so the shell inserts an empty selection).
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                $result = & $script:python $script:helperScript print_aliases --out $tmp 2>&1
                $output = ($result -join "`n").Trim()
                $output | Should -Not -Match "Git Aliases"
                $LASTEXITCODE | Should -Be 0
            }
            finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Browser fallback diagnostics" {
        BeforeAll { $script:src = Get-Content $script:helperScript -Raw }

        It "Explains the fallback on stderr (only when stderr is a TTY)" {
            $script:src | Should -Match "def _note_browser_fallback"
            $script:src | Should -Match "sys\.stderr\.isatty\(\)"
            # The note always points users at --plain to silence it.
            $script:src | Should -Match "git alias --plain"
        }

        It "Reports a reason (textual missing / UI error) from the launcher" {
            # _launch_alias_browser now returns (ran, reason) and names textual.
            $script:src | Should -Match "is not installed for"
            $script:src | Should -Match "the interactive browser failed"
        }

        It "Draws the browser on /dev/tty, guarded for Windows" {
            $script:src | Should -Match "def _run_app_on_tty"
            $script:src | Should -Match '/dev/tty'
            $script:src | Should -Match 'os\.name != "nt"'
        }

        It "Stays quiet (no reason) when piped, and still shows the table" {
            # stdout+stderr both captured (not TTYs) -> static table, no note.
            $result = & $script:python $script:helperScript print_aliases 2>&1
            $output = $result -join "`n"
            $output | Should -Match "Git Aliases"
            $output | Should -Not -Match "git alias:"
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Ctrl-G shell keybinding widgets" {
        It "Ships bash, zsh, and PowerShell widget files" {
            foreach ($ext in @("bash", "zsh", "ps1")) {
                Join-Path $script:repoRoot "scripts/shell/git-alias-widget.$ext" | Should -Exist
            }
        }

        It "Widgets run the browser with --out and insert the result" {
            $bash = Get-Content (Join-Path $script:repoRoot "scripts/shell/git-alias-widget.bash") -Raw
            $bash | Should -Match 'git alias --out'
            $bash | Should -Match 'READLINE_LINE'
            $zsh = Get-Content (Join-Path $script:repoRoot "scripts/shell/git-alias-widget.zsh") -Raw
            $zsh | Should -Match 'git alias --out'
            $zsh | Should -Match 'LBUFFER'
            $ps = Get-Content (Join-Path $script:repoRoot "scripts/shell/git-alias-widget.ps1") -Raw
            $ps | Should -Match 'git alias --out'
            $ps | Should -Match 'PSConsoleReadLine'
        }

        It "Install and cleanup wire the keybinding idempotently" {
            $functions = Get-Content (Join-Path $script:repoRoot "scripts/shared/functions.sh") -Raw
            $functions | Should -Match "enable_git_alias_widget"
            $functions | Should -Match "disable_git_alias_widget"
            $macInstall = Get-Content (Join-Path $script:repoRoot "scripts/mac version/install.sh") -Raw
            $macInstall | Should -Match "enable_git_alias_widget"
        }
    }

    Context "start Function (git start)" {
        BeforeAll { $script:src = Get-Content $script:helperScript -Raw }

        It "Is defined and dispatched from __main__" {
            $script:src | Should -Match "def start_branch"
            $script:src | Should -Match 'function_name == "start"'
        }

        It "Maps issue labels to branch-name prefixes" {
            $script:src | Should -Match "LABEL_PREFIX"
            $script:src | Should -Match '"bug":\s*"fix"'
            $script:src | Should -Match '"enhancement":\s*"feat"'
            $script:src | Should -Match '"documentation":\s*"docs"'
        }

        It "Rejects a missing issue number" {
            $result = & $script:python $script:helperScript start 2>&1
            $output = $result -join "`n"
            $output | Should -Match "Usage: git start"
            $LASTEXITCODE | Should -Be 1
        }

        It "Rejects a non-numeric issue number" {
            $result = & $script:python $script:helperScript start abc 2>&1
            $output = $result -join "`n"
            $output | Should -Match "Usage: git start"
            $LASTEXITCODE | Should -Be 1
        }
    }
}
