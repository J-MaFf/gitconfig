BeforeAll {
    # Setup variables
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot "scripts\windows version\Update-GitConfig.ps1"
    $script:testRepo = Join-Path $TestDrive "test-repo"
    $script:logFile = Join-Path $script:testRepo "docs\update-gitconfig.log"

    # Check if running on Windows
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $script:platformIsWindows = $IsWindows
    }
    else {
        $script:platformIsWindows = $true
    }

    # Helper function to create a test git repository
    function New-TestRepository {
        param([string]$Path)

        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Push-Location $Path

        # Initialize git repo
        git init 2>&1 | Out-Null
        git config user.email "test@example.com"
        git config user.name "Test User"
        git config commit.gpgsign false   # fake HOME has no signing key; don't sign

        # Create initial commit on main
        New-Item -Path "docs" -ItemType Directory -Force | Out-Null
        "# Test Repo" | Out-File -FilePath "README.md" -Encoding utf8
        git add .
        git commit -m "Initial commit" 2>&1 | Out-Null

        # Rename master to main if needed
        $currentBranch = git branch --show-current
        if ($currentBranch -eq "master") {
            git branch -m main 2>&1 | Out-Null
        }

        Pop-Location
    }

    # Helper function to create a remote repository
    function New-RemoteRepository {
        param([string]$Path)

        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Push-Location $Path
        git init --bare 2>&1 | Out-Null
        Pop-Location
    }

    # The convergence step now runs on every invocation and writes ~/.gitconfig.
    # Redirect HOME to a throwaway dir for the whole suite so tests never touch the
    # developer's real ~/.gitconfig. (Step 2b overrides this per-test with its own
    # fake home using different variables, so there is no collision.)
    $script:realUserProfile = $env:USERPROFILE
    $script:realHome = $env:HOME
    $script:fakeHomeGlobal = Join-Path ([System.IO.Path]::GetTempPath()) ("ugc-home-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:fakeHomeGlobal | Out-Null
    $env:USERPROFILE = $script:fakeHomeGlobal
    $env:HOME = $script:fakeHomeGlobal
}

Describe "Update-GitConfig.ps1" {

    Context "Script Validation" {
        It "Should exist" {
            $script:scriptPath | Should -Exist
        }

        It "Should be a valid PowerShell script" {
            # PSParser::Tokenize never throws on syntax errors (it reports them
            # via the discarded [ref] parameter), so a Should -Not -Throw around
            # it is vacuous - an unparseable script would still pass (#201).
            # Capture and count parse errors instead.
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
        }

        It "Should accept RepoPath parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match 'param\s*\(\s*\[string\]\s*\$RepoPath'
        }

        It "Should ensure Python deps via the shared Install-PythonDeps routine (idempotent, best-effort)" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            # The dep logic now lives in the shared routine; the update just calls it.
            $scriptContent | Should -Match 'Install-PythonDeps'
        }

        It "Should declare 'textual' as an optional (tui) dependency in pyproject.toml" {
            $repoRoot = Split-Path -Parent $PSScriptRoot
            $pyproject = Get-Content (Join-Path $repoRoot "pyproject.toml") -Raw
            $pyproject | Should -Match 'textual'
        }
    }

    Context "Logging Functionality" {
        BeforeEach {
            # Create test repository
            New-TestRepository -Path $script:testRepo

            # Remove existing log file
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }
        }

        AfterEach {
            if (Test-Path $script:testRepo) {
                Remove-Item $script:testRepo -Recurse -Force
            }
        }

        It "Should create log file if it doesn't exist" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Verify log file was created
            $script:logFile | Should -Exist
        }

        It "Should log with timestamp format" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify timestamp format (yyyy-MM-dd HH:mm:ss)
            $logContent | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
        }

        It "Should log start message" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify start message
            $logContent | Should -Match "Starting git repository synchronization"
        }

        It "Should log completion message" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify completion message
            $logContent | Should -Match "Repository synchronization process completed"
        }
    }

    Context "Step 1: Stay on the Current Branch" {
        # Off main, the updater must leave the user's branch checked out (it used
        # to `git checkout main`, yanking a work-in-progress branch at login) and
        # fast-forward main in place with `git fetch origin main:main` (#225).
        BeforeEach {
            $suffix = [guid]::NewGuid().ToString("N")
            $script:testRepo = Join-Path $TestDrive "test-repo-$suffix"
            $script:logFile = Join-Path $script:testRepo "docs\update-gitconfig.log"
            $script:remoteRepo = Join-Path $TestDrive "remote-repo-$suffix"
            New-RemoteRepository -Path $script:remoteRepo

            New-Item -Path $script:testRepo -ItemType Directory -Force | Out-Null
            Push-Location $script:testRepo
            try {
                git clone $script:remoteRepo . 2>&1 | Out-Null
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false
                New-Item -Path "docs" -ItemType Directory -Force | Out-Null
                "# Test" | Out-File -FilePath "README.md" -Encoding utf8
                git add . 2>&1 | Out-Null
                git commit -m "Initial" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null
                git checkout -b main 2>&1 | Out-Null
                git branch --set-upstream-to=origin/main main 2>&1 | Out-Null
                git checkout -b feature-branch 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            # Advance origin/main from a throwaway clone so main has something to catch up to.
            $work = Join-Path $TestDrive "work-$suffix"
            git clone $script:remoteRepo $work 2>&1 | Out-Null
            Push-Location $work
            try {
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false
                "upstream" | Out-File -FilePath "upstream.txt" -Encoding utf8
                git add . 2>&1 | Out-Null
                git commit -m "Upstream change" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null
                $script:upstreamHead = git rev-parse HEAD
            }
            finally {
                Pop-Location
            }
        }

        AfterEach {
            foreach ($p in @($script:testRepo, $script:remoteRepo)) {
                if ($p -and (Test-Path $p)) {
                    Remove-Item $p -Recurse -Force
                }
            }
        }

        It "Should leave the feature branch checked out" {
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            Pop-Location
            $currentBranch | Should -Be "feature-branch"
        }

        It "Should fast-forward main in place without checking it out" {
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            Push-Location $script:testRepo
            $mainHead = git rev-parse main
            Pop-Location
            $mainHead | Should -Be $script:upstreamHead

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "SUCCESS: main up to date \(still on 'feature-branch'\)"
            $logContent | Should -Not -Match "could not switch to main"
        }

        It "Should keep a dirty feature branch and its edits" {
            $readme = Join-Path $script:testRepo "README.md"
            "local edit" | Out-File -FilePath $readme -Encoding utf8

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            Pop-Location
            $currentBranch | Should -Be "feature-branch"
            (Get-Content $readme -Raw) | Should -Match "local edit"
        }

        It "Should warn and carry on when main cannot be fast-forwarded" {
            # A local commit on main makes the fetch a non-fast-forward, which
            # git refuses; the run must log it and still finish.
            Push-Location $script:testRepo
            try {
                git checkout main 2>&1 | Out-Null
                "diverge" | Out-File -FilePath "local.txt" -Encoding utf8
                git add . 2>&1 | Out-Null
                git commit -m "Local only" 2>&1 | Out-Null
                git checkout feature-branch 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            { & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null } | Should -Not -Throw

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "WARN: could not fast-forward main"
            $logContent | Should -Match "Repository synchronization process completed"
        }
    }

    Context "Step 2: Pull Latest Changes" {
        BeforeEach {
            # Create remote and local repositories
            $remoteRepo = Join-Path $TestDrive "remote-repo"
            New-RemoteRepository -Path $remoteRepo

            # Create local test repository
            New-Item -Path $script:testRepo -ItemType Directory -Force | Out-Null
            Push-Location $script:testRepo

            try {
                # Clone from remote
                git clone $remoteRepo . 2>&1 | Out-Null
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false   # fake HOME has no signing key

                # Create initial commit
                New-Item -Path "docs" -ItemType Directory -Force | Out-Null
                "# Test" | Out-File -FilePath "README.md" -Encoding utf8
                git add .
                git commit -m "Initial" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null

                # Set main as default branch
                git checkout -b main 2>&1 | Out-Null
                git branch --set-upstream-to=origin/main main 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            # Remove existing log file
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }
        }

        AfterEach {
            if (Test-Path $script:testRepo) {
                Remove-Item $script:testRepo -Recurse -Force
            }
            $remoteRepo = Join-Path $TestDrive "remote-repo"
            if (Test-Path $remoteRepo) {
                Remove-Item $remoteRepo -Recurse -Force
            }
        }

        It "Should pull latest changes successfully" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify the fetch/fast-forward step ran
            $logContent | Should -Match "Fetching and fast-forwarding"
        }

        It "Should log pull success" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify success message
            $logContent | Should -Match "SUCCESS: repo up to date"
        }

        It "Should handle pull failure gracefully" {
            # Break the remote reference to force failure
            Push-Location $script:testRepo
            git remote remove origin 2>&1 | Out-Null
            Pop-Location

            # Run script (should not throw)
            { & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null } | Should -Not -Throw

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify the failed pull was logged as a warning (non-fatal now)
            $logContent | Should -Match "WARN: pull failed"
        }
    }

    Context "Step 3: Prune Merged Branches" {
        BeforeEach {
            # Use a unique repo path per test. The script's early-exit paths can
            # leave the process CWD inside the repo, which blocks directory cleanup
            # on Windows; a unique path keeps a locked leftover from polluting the
            # next test (which asserts on exact branch state).
            $suffix = [guid]::NewGuid().ToString("N")
            $script:testRepo = Join-Path $TestDrive "test-repo-$suffix"
            $script:logFile = Join-Path $script:testRepo "docs\update-gitconfig.log"
            $remoteRepo = Join-Path $TestDrive "remote-repo-$suffix"
            New-RemoteRepository -Path $remoteRepo

            # Create local test repository
            New-Item -Path $script:testRepo -ItemType Directory -Force | Out-Null
            Push-Location $script:testRepo

            try {
                # Clone from remote
                git clone $remoteRepo . 2>&1 | Out-Null
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false

                # Create initial commit on main with an upstream
                New-Item -Path "docs" -ItemType Directory -Force | Out-Null
                "# Test" | Out-File -FilePath "README.md" -Encoding utf8
                git add .
                git commit -m "Initial" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null
                git checkout -b main 2>&1 | Out-Null
                git branch --set-upstream-to=origin/main main 2>&1 | Out-Null

                # feature-gone: tracks a remote branch that we then delete on the
                # remote (simulates a squash-merged PR branch). Should be pruned.
                git checkout -b feature-gone 2>&1 | Out-Null
                "Gone" | Out-File -FilePath "gone.txt" -Encoding utf8
                git add .
                git commit -m "Feature gone" 2>&1 | Out-Null
                git push -u origin feature-gone 2>&1 | Out-Null

                # feature-live: tracks a remote branch that still exists. Should be kept.
                git checkout main 2>&1 | Out-Null
                git checkout -b feature-live 2>&1 | Out-Null
                "Live" | Out-File -FilePath "live.txt" -Encoding utf8
                git add .
                git commit -m "Feature live" 2>&1 | Out-Null
                git push -u origin feature-live 2>&1 | Out-Null

                # Back on main; delete feature-gone on the remote.
                git checkout main 2>&1 | Out-Null
                git push origin --delete feature-gone 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            # Remove existing log file
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }
        }

        AfterEach {
            if (Test-Path $script:testRepo) {
                Remove-Item $script:testRepo -Recurse -Force
            }
            $remoteRepo = Join-Path $TestDrive "remote-repo"
            if (Test-Path $remoteRepo) {
                Remove-Item $remoteRepo -Recurse -Force
            }
        }

        It "Should fetch with prune successfully" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify prune step ran
            $logContent | Should -Match "Pruning merged branches"
            $logContent | Should -Match "SUCCESS: git fetch --prune completed"
        }

        It "Should delete local branches whose remote was deleted" {
            # Verify feature-gone exists locally before the run
            Push-Location $script:testRepo
            $branches = git branch --format='%(refname:short)'
            Pop-Location
            $branches | Should -Contain "feature-gone"

            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # feature-gone should be deleted; feature-live should remain
            Push-Location $script:testRepo
            $branches = git branch --format='%(refname:short)'
            Pop-Location
            $branches | Should -Not -Contain "feature-gone"
            $branches | Should -Contain "feature-live"
        }

        It "Should log the deleted merged branch" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify the gone branch was logged as deleted, the live one was not
            $logContent | Should -Match "Deleted merged branch: feature-gone"
            $logContent | Should -Not -Match "Deleted merged branch: feature-live"
        }

        It "Should log successful prune" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify success message
            $logContent | Should -Match "SUCCESS: Merged branches pruned"
        }

        It "Should not delete branches whose remote still exists" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # feature-live tracks an existing remote, so it must survive
            Push-Location $script:testRepo
            $branches = git branch --format='%(refname:short)'
            Pop-Location
            $branches | Should -Contain "feature-live"
        }

        It "Should handle a repo with no branches to prune gracefully" {
            # Prune once so feature-gone is already removed; a second run has nothing to do
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }

            { & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null } | Should -Not -Throw

            # Read log content
            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "SUCCESS: Merged branches pruned"
        }
    }

    Context "Error Handling" {
        It "Should fail with exit 1 and create nothing for a non-existent repository path" {
            $nonExistentPath = Join-Path $TestDrive "non-existent-repo"

            # The path is checked before the docs dir is created, so a wrong path
            # is reported instead of being half-created (#225).
            { & $script:scriptPath -RepoPath $nonExistentPath 2>$null | Out-Null } | Should -Not -Throw
            $LASTEXITCODE | Should -Be 1
            $nonExistentPath | Should -Not -Exist
        }

        It "Should default RepoPath to the repo the script lives in" {
            # Lay out a repo with the updater inside it and run it with no
            # -RepoPath: the log must land in that repo, not ~/Documents/Scripts.
            New-TestRepository -Path $script:testRepo
            $winDir = Join-Path $script:testRepo "scripts\windows version"
            New-Item -Path $winDir -ItemType Directory -Force | Out-Null
            $srcDir = Split-Path -Parent $script:scriptPath
            foreach ($f in @("Update-GitConfig.ps1", "Functions.ps1", "Initialize-GitConfig.ps1")) {
                Copy-Item (Join-Path $srcDir $f) $winDir
            }
            try {
                & (Join-Path $winDir "Update-GitConfig.ps1") 2>&1 | Out-Null
                $script:logFile | Should -Exist
                (Get-Content $script:logFile -Raw) | Should -Match "Repository synchronization process completed"
            }
            finally {
                Remove-Item $script:testRepo -Recurse -Force
            }
        }

        It "Should run git with GIT_TERMINAL_PROMPT=0 and restore the caller's value" {
            New-TestRepository -Path $script:testRepo
            # Globals: $script: inside the shim would resolve to the updater's scope.
            $global:ugcPromptSeen = [System.Collections.Generic.List[string]]::new()
            $global:ugcRealGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            # A function shadows the git executable inside the script (which
            # runs in this session), recording what each call sees.
            function global:git {
                $global:ugcPromptSeen.Add([string]$env:GIT_TERMINAL_PROMPT)
                & $global:ugcRealGit @args
            }
            $env:GIT_TERMINAL_PROMPT = 'caller-value'
            try {
                & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null
            }
            finally {
                Remove-Item Function:\git -ErrorAction SilentlyContinue
                $after = $env:GIT_TERMINAL_PROMPT
                Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
                Remove-Item $script:testRepo -Recurse -Force
            }
            $seen = @($global:ugcPromptSeen)
            Remove-Variable ugcPromptSeen, ugcRealGit -Scope Global -ErrorAction SilentlyContinue
            $seen.Count | Should -BeGreaterThan 0
            ($seen | Sort-Object -Unique) | Should -Be @('0')
            $after | Should -Be 'caller-value'
        }

        It "Should verify repository directory before processing" {
            # Create a test repo to verify the path checking logic
            New-TestRepository -Path $script:testRepo

            # Remove existing log file
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }

            # Run with valid path (should succeed)
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Verify it checked the path and logged the process
            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "Starting git repository synchronization"

            # Clean up
            if (Test-Path $script:testRepo) {
                Remove-Item $script:testRepo -Recurse -Force
            }
        }
    }

    Context "Integration: Complete Workflow" {
        BeforeEach {
            # Unique repo path per test (see Step 3 note) so a locked leftover from
            # an earlier test never pollutes this one's branch-state assertions.
            $suffix = [guid]::NewGuid().ToString("N")
            $script:testRepo = Join-Path $TestDrive "test-repo-$suffix"
            $script:logFile = Join-Path $script:testRepo "docs\update-gitconfig.log"
            $remoteRepo = Join-Path $TestDrive "remote-repo-$suffix"
            New-RemoteRepository -Path $remoteRepo

            # Create local test repository
            New-Item -Path $script:testRepo -ItemType Directory -Force | Out-Null
            Push-Location $script:testRepo

            try {
                # Clone from remote
                git clone $remoteRepo . 2>&1 | Out-Null
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false

                # Create initial structure
                New-Item -Path "docs" -ItemType Directory -Force | Out-Null
                "# Test" | Out-File -FilePath "README.md" -Encoding utf8
                git add .
                git commit -m "Initial" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null

                git checkout -b main 2>&1 | Out-Null
                git branch --set-upstream-to=origin/main main 2>&1 | Out-Null

                # merged-feature: tracks a remote branch deleted on the remote.
                # Should be pruned by the run.
                git checkout -b merged-feature 2>&1 | Out-Null
                "Merged Feature" | Out-File -FilePath "merged.txt" -Encoding utf8
                git add .
                git commit -m "Merged feature" 2>&1 | Out-Null
                git push -u origin merged-feature 2>&1 | Out-Null
                git checkout main 2>&1 | Out-Null
                git push origin --delete merged-feature 2>&1 | Out-Null

                # local-feature: local-only branch (no upstream). Should be kept,
                # and is the branch we're sitting on when the script runs.
                git checkout -b local-feature 2>&1 | Out-Null
                "Local Feature" | Out-File -FilePath "local.txt" -Encoding utf8
                git add .
                git commit -m "Local feature" 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            # Remove existing log file
            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }
        }

        AfterEach {
            if (Test-Path $script:testRepo) {
                Remove-Item $script:testRepo -Recurse -Force
            }
            $remoteRepo = Join-Path $TestDrive "remote-repo"
            if (Test-Path $remoteRepo) {
                Remove-Item $remoteRepo -Recurse -Force
            }
        }

        It "Should complete all synchronization steps successfully" {
            # Verify initial state: on local-feature, merged-feature still exists locally
            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            $branches = git branch --format='%(refname:short)'
            Pop-Location
            $currentBranch | Should -Be "local-feature"
            $branches | Should -Contain "merged-feature"

            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Verify final state
            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            $branches = git branch --format='%(refname:short)'
            Pop-Location

            # Stays on the branch the user left (#225)
            $currentBranch | Should -Be "local-feature"

            # merged-feature pruned (remote gone); local-only branch preserved
            $branches | Should -Not -Contain "merged-feature"
            $branches | Should -Contain "local-feature"

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify all steps were logged
            $logContent | Should -Match "Starting git repository synchronization"
            $logContent | Should -Match "SUCCESS: main up to date \(still on 'local-feature'\)"
            $logContent | Should -Match "SUCCESS: ~/.gitconfig converged to template"
            $logContent | Should -Match "Pruning merged branches"
            $logContent | Should -Match "SUCCESS: git fetch --prune completed"
            $logContent | Should -Match "Deleted merged branch: merged-feature"
            $logContent | Should -Match "SUCCESS: Merged branches pruned"
            $logContent | Should -Match "Repository synchronization process completed"
        }
    }

    Context "Step 2b: Regenerate ~/.gitconfig on Template Change" {
        BeforeEach {
            $script:remoteRepo = Join-Path $TestDrive "remote-repo"
            $script:fakeHome = Join-Path $TestDrive "fake-home"
            New-RemoteRepository -Path $script:remoteRepo
            New-Item -Path $script:fakeHome -ItemType Directory -Force | Out-Null

            # Local clone laid out like the gitconfig repo, tracking main
            New-Item -Path $script:testRepo -ItemType Directory -Force | Out-Null
            Push-Location $script:testRepo
            try {
                git clone $script:remoteRepo . 2>&1 | Out-Null
                git config user.email "test@example.com"
                git config user.name "Test User"
                git config commit.gpgsign false
                New-Item -Path "docs" -ItemType Directory -Force | Out-Null
                "[core]`n`teditor = nano`n" | Out-File -FilePath ".gitconfig.template" -Encoding utf8
                "# readme" | Out-File -FilePath "README.md" -Encoding utf8
                git add . 2>&1 | Out-Null
                git commit -m "Initial" 2>&1 | Out-Null
                git push origin HEAD:main 2>&1 | Out-Null
                git checkout -b main 2>&1 | Out-Null
                git branch --set-upstream-to=origin/main main 2>&1 | Out-Null
            }
            finally {
                Pop-Location
            }

            # Redirect home so regeneration never touches the real ~/.gitconfig
            $script:savedUserProfile = $env:USERPROFILE
            $script:savedHomeEnv = $env:HOME
            $env:USERPROFILE = $script:fakeHome
            $env:HOME = $script:fakeHome

            if (Test-Path $script:logFile) {
                Remove-Item $script:logFile -Force
            }
        }

        AfterEach {
            $env:USERPROFILE = $script:savedUserProfile
            $env:HOME = $script:savedHomeEnv
            foreach ($p in @($script:testRepo, $script:remoteRepo, $script:fakeHome)) {
                if ($p -and (Test-Path $p)) {
                    Remove-Item $p -Recurse -Force
                }
            }
        }

        # Push a change to the remote from a throwaway clone so the test repo's
        # pull produces a real before/after diff. Defined in BeforeAll so the
        # function is visible inside the It blocks under Pester v5 (functions
        # declared directly in a Context body are not).
        BeforeAll {
            function Push-RemoteChange {
                param([string]$File, [string]$Content, [string]$Message)
                $work = Join-Path $TestDrive ("work-" + [guid]::NewGuid().ToString("N"))
                git clone $script:remoteRepo $work 2>&1 | Out-Null
                Push-Location $work
                try {
                    git config user.email "test@example.com"
                    git config user.name "Test User"
                    git config commit.gpgsign false
                    $Content | Out-File -FilePath $File -Encoding utf8
                    git add . 2>&1 | Out-Null
                    git commit -m $Message 2>&1 | Out-Null
                    git push origin HEAD:main 2>&1 | Out-Null
                }
                finally {
                    Pop-Location
                }
                Remove-Item $work -Recurse -Force
            }
        }

        It "Should converge ~/.gitconfig even when the pull brings no template change" {
            # The classic failure mode: a no-op / docs-only pull used to skip regen,
            # leaving ~/.gitconfig stale. Convergence now regenerates it regardless.
            Push-RemoteChange -File "README.md" -Content "# updated readme" -Message "Docs only"

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "converged to template"
            (Join-Path $script:fakeHome ".gitconfig") | Should -Exist
        }

        It "Should replace a stale ~/.gitconfig that differs from the template" {
            $cfg = Join-Path $script:fakeHome ".gitconfig"
            Set-Content -Path $cfg -Value "STALE-MARKER-DO-NOT-KEEP"

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            (Get-Content $cfg -Raw) | Should -Not -Match "STALE-MARKER-DO-NOT-KEEP"
            # the stale version was backed up to a timestamped file
            $backups = @(Get-ChildItem -LiteralPath $script:fakeHome -Force -Filter ".gitconfig.bak.*")
            $backups.Count | Should -BeGreaterThan 0
            ($backups | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" | Should -Match "STALE-MARKER-DO-NOT-KEEP"
        }

        It "Should not rewrite ~/.gitconfig when it already matches the template" {
            # First run creates it from the template; the second run must be a no-op.
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null
            $cfg = Join-Path $script:fakeHome ".gitconfig"
            Get-ChildItem -LiteralPath $script:fakeHome -Force -Filter ".gitconfig.bak*" | Remove-Item -Force
            if (Test-Path $script:logFile) { Remove-Item $script:logFile -Force }

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "already up to date"
            # no rewrite => no backup made
            @(Get-ChildItem -LiteralPath $script:fakeHome -Force -Filter ".gitconfig.bak*").Count | Should -Be 0
        }
    }
}

AfterAll {
    $env:USERPROFILE = $script:realUserProfile
    $env:HOME = $script:realHome
    if ($script:fakeHomeGlobal -and (Test-Path $script:fakeHomeGlobal)) {
        Remove-Item $script:fakeHomeGlobal -Recurse -Force -ErrorAction SilentlyContinue
    }
}
