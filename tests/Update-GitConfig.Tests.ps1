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
}

Describe "Update-GitConfig.ps1" {

    Context "Script Validation" {
        It "Should exist" {
            $script:scriptPath | Should -Exist
        }

        It "Should be a valid PowerShell script" {
            { $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $script:scriptPath -Raw), [ref]$null) } | Should -Not -Throw
        }

        It "Should accept RepoPath parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match 'param\s*\(\s*\[string\]\s*\$RepoPath'
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

    Context "Step 1: Switch to Main Branch" {
        BeforeEach {
            # Create test repository
            New-TestRepository -Path $script:testRepo

            # Create a feature branch and switch to it
            Push-Location $script:testRepo
            git checkout -b feature-branch 2>&1 | Out-Null
            Pop-Location

            # Ensure we're not in the test repo directory for cleanup
            $currentPath = Get-Location
            if ($currentPath.Path -eq $script:testRepo) {
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
        }

        It "Should switch to main branch successfully" {
            # Verify we're on feature branch
            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            Pop-Location
            $currentBranch | Should -Be "feature-branch"

            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Verify we switched to main
            Push-Location $script:testRepo
            $currentBranch = git branch --show-current
            Pop-Location
            $currentBranch | Should -Be "main"
        }

        It "Should log switch to main branch" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify log message
            $logContent | Should -Match "Switching to main branch"
        }

        It "Should handle failed branch switch gracefully" {
            # Delete main branch to force failure
            Push-Location $script:testRepo
            git branch -D main 2>&1 | Out-Null
            Pop-Location

            # Run script (should not throw)
            { & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null } | Should -Not -Throw

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify error was logged
            $logContent | Should -Match "ERROR: Failed to switch to main branch"
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

            # Verify pull was attempted
            $logContent | Should -Match "Pulling latest changes from main"
        }

        It "Should log pull success" {
            # Run script
            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify success message (either "Already up to date" or "SUCCESS: git pull completed")
            $logContent | Should -Match "(SUCCESS: git pull completed|Already up to date)"
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

            # Verify error was logged
            $logContent | Should -Match "ERROR: git pull failed"
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
        It "Should handle non-existent repository path" {
            $nonExistentPath = Join-Path $TestDrive "non-existent-repo"

            # NOTE: The script currently throws when trying to write to log file in non-existent directory.
            # This is a known limitation - the script attempts to log before verifying the path exists.
            # TODO: Consider enhancing Update-GitConfig.ps1 to check directory existence before logging,
            # or ensure log directory exists before attempting writes.
            # In production, the scheduled task always points to a valid path, so this is low priority.
            { & $script:scriptPath -RepoPath $nonExistentPath 2>&1 } | Should -Throw
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

            # Should be on main
            $currentBranch | Should -Be "main"

            # merged-feature pruned (remote gone); local-only branch preserved
            $branches | Should -Not -Contain "merged-feature"
            $branches | Should -Contain "local-feature"

            # Read log content
            $logContent = Get-Content $script:logFile -Raw

            # Verify all steps were logged
            $logContent | Should -Match "Starting git repository synchronization"
            $logContent | Should -Match "Switching to main branch"
            $logContent | Should -Match "Pulling latest changes from main"
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

        It "Should regenerate ~/.gitconfig when the template changed" {
            Push-RemoteChange -File ".gitconfig.template" -Content "[core]`n`teditor = vim`n" -Message "Change template"

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "regenerating ~/.gitconfig"
            (Join-Path $script:fakeHome ".gitconfig") | Should -Exist
        }

        It "Should not regenerate when no template change occurred" {
            Push-RemoteChange -File "README.md" -Content "# updated readme" -Message "Docs only"

            & $script:scriptPath -RepoPath $script:testRepo 2>&1 | Out-Null

            $logContent = Get-Content $script:logFile -Raw
            $logContent | Should -Match "skipping regeneration"
            (Join-Path $script:fakeHome ".gitconfig") | Should -Not -Exist
        }
    }
}
