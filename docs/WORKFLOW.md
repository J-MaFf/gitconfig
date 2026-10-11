# Git Workflow Documentation

Complete guide to using the gitconfig aliases, scripts, and workflows for efficient Git operations.

## Table of Contents

- [Git Aliases Usage Guide](#git-aliases-usage-guide)
- [Branch Management Workflow](#branch-management-workflow)
- [Automated Tasks](#automated-tasks)
- [Daily Development Flow](#daily-development-flow)
- [Troubleshooting](#troubleshooting)

---

## Git Aliases Usage Guide

This repository provides custom Git aliases designed to streamline common operations and improve workflow efficiency.

### Overview of All Aliases

Display all configured aliases with descriptions:

```bash
git alias
```

This displays a formatted table showing each alias and its corresponding command.

### Available Aliases

#### `git alias`

**Purpose**: List all configured Git aliases in a formatted table

**Usage**:

```bash
git alias
```

**Output**: Displays all custom aliases with their full command definitions

**Example**:

```
Alias          Command
─────────────────────────────────────────────────────
branches       git fetch && git for-each-ref ...
cleanup        [cleanup script]
alias          [alias list script]
```

---

#### `git branches`

**Purpose**: Download all remote branches and create local tracking branches

**What it does**:

1. Fetches latest changes from remote repository
2. Lists all remote branches
3. Creates local tracking branches for each remote branch
4. Skips special refs like `origin/HEAD`

**Usage**:

```bash
git branches
```

**When to use**:

- After cloning a repository to get all branches locally
- When a team member creates a new remote branch
- To synchronize your local branch tracking with remote state
- When joining a project with multiple feature branches

**Example workflow**:

```bash
# Clone a repository
git clone https://github.com/username/project.git
cd project

# Get all remote branches locally
git branches

# Now you can work on any branch
git checkout feature/user-auth
git checkout bugfix/login-issue
```

**What happens**:

```
Fetching from origin...
Creating local tracking branches...
✓ Created tracking branch: feature/auth
✓ Created tracking branch: feature/api
✓ Created tracking branch: bugfix/dashboard
✓ Updated tracking branch: main
```

---

#### `git cleanup`

**Purpose**: Delete merged or stale branches to maintain repository cleanliness

**Modes**:

**1. Default mode** - Delete branches whose remote branch is gone

```bash
git cleanup
```

Switches to the default branch (read from `origin/HEAD`), runs `git fetch --prune`,
fast-forwards the default branch, then deletes each local branch whose upstream
is marked `[gone]` (its remote branch was deleted, usually by merging the PR).
Branch state comes from `git for-each-ref`, so a commit message that happens to
contain ": gone]" can't get a live branch deleted, and a branch tracking another
remote (say a fork's `upstream`) is left alone.

Each deletion tries `git branch -d` first, which only succeeds when the branch is
merged into the default branch. A squash-merged PR branch never is, so a branch
whose remote is gone falls back to `git branch -D`. The summary table marks which
branches needed `-D` and shows every deleted branch's tip commit.

**2. Force mode** - Also delete merged local-only branches

```bash
git cleanup --force
# or
git cleanup -f
```

Also deletes branches that never had a remote (local-only branches), but only
with `git branch -d`: a local-only branch holding commits that aren't in the
default branch is kept and listed with its tip, so delete it yourself with
`git branch -D <name>` once you're sure.

**When to use**:

- **After merging PRs**: Remote branches get deleted, local cleanup keeps things tidy
- **End of sprint**: Clean up temporary feature/bugfix branches
- **Repository maintenance**: Regular cleanup prevents branch clutter

**Example**:

```text
$ git cleanup
Switching from 'feat/new-thing' to 'main'...
Running git cleanup...
Fast-forwarding main...
                         Deleted Branches
| Branch Name       | Tip     | How                                    |
| fix/login         | 3f9c2a1 | merged (-d)                            |
| feat/user-auth    | 8b07d4e | remote gone, not merged into main (-D) |
[OK] Successfully deleted 2 branch(es) (restore one with: git branch <name> <tip>)
```

**Safety features**:

- Never deletes the current branch or the default branch
- Only branches whose remote is gone are ever deleted with `-D`
- Branches checked out in another worktree are skipped and listed
- Every deleted branch's tip is printed, so `git branch <name> <tip>` restores it
- Exits non-zero if the fetch or any deletion fails, so scripts can tell

The login-time updaters (`update-gitconfig.sh`, `Update-GitConfig.ps1`) prune the
gitconfig repo itself the same way and write each deleted tip to
`docs/update-gitconfig.log`.

---

### Git Aliases Advanced Usage

#### Combining Aliases in Workflows

**Typical workflow sequence**:

```bash
# 1. Get all branches
git branches

# 2. Switch to feature branch
git checkout feature/new-feature

# 3. Make changes and commit
git add .
git commit -m "Implement feature"
git push

# 4. After PR merge, clean up
git checkout main
git pull
git cleanup
```

#### Alias Composition

Create personal workflows combining aliases:

```bash
# Update all branches and clean up
alias git-sync="git branches && git cleanup"
git-sync

# Quick branch management
git branches && git checkout main && git pull && git cleanup
```

---

## Branch Management Workflow

Best practices for managing branches effectively.

### Branch Naming Conventions (Recommended)

While not enforced, these conventions improve organization:

**Feature branches**:

```
feature/user-authentication
feature/api-endpoints
feature/dashboard-redesign
```

**Bugfix branches**:

```
bugfix/login-error
bugfix/memory-leak
fix/typo-in-docs
```

**Hotfix branches** (urgent production fixes):

```
hotfix/security-patch
hotfix/critical-bug
```

**Release branches**:

```
release/v1.0.0
release/v2.1.0
```

### Creating and Tracking Branches

**Create a feature branch**:

```bash
# Create from main
git checkout -b feature/my-feature

# Or from another branch
git checkout -b feature/my-feature existing-branch
```

**Push and track**:

```bash
# Push and set upstream
git push -u origin feature/my-feature

# Now 'git pull' knows where to pull from
git pull
```

**Get all remote branches locally**:

```bash
# Option 1: Use our alias
git branches

# Option 2: Manual approach
git fetch --all
```

### Merging Branches

**Standard merge process**:

```bash
# Switch to target branch (usually main)
git checkout main

# Ensure you have latest
git pull

# Merge feature branch
git merge feature/my-feature

# Resolve any conflicts if needed
# Then commit and push
git push
```

**After PR merge on GitHub**:

```bash
# Remote branch gets deleted on GitHub
# Update local state
git fetch --prune

# Clean up local tracking branches
git cleanup
```

### Branch Maintenance with `git cleanup`

**Regular cleanup schedule**:

```bash
# After each PR merge
git cleanup

# Weekly maintenance
git cleanup

# Monthly aggressive cleanup (remove local-only branches)
git cleanup --force

# Before major operations
git branches      # Sync all remote branches
git cleanup       # Remove stale tracking branches
```

**Cleanup workflow example**:

```bash
# Check branches before cleanup
git branch

# Clean up merged branches
git cleanup

# Verify results
git branch
```

---

## Automated Tasks

Automatic repository synchronization and maintenance.

### Update-GitConfig.ps1

**Purpose**: Automatically synchronize repository changes at user login

**What it does** (`scripts\windows version\Update-GitConfig.ps1`):

1. Runs at Windows user login, one minute after logon (via the `GitConfig Pull at Login` scheduled task, which passes the repo path with `-RepoPath`)
2. On main with a clean working tree, fast-forwards it with `git pull --ff-only`; on any other branch, leaves that branch checked out and fast-forwards main in place with `git fetch origin main:main`
3. Regenerates `~/.gitconfig` from the template when it has drifted
4. Installs any missing Python dependencies declared in `pyproject.toml`
5. Runs `git fetch --prune` and deletes local branches whose upstream is gone (doesn't touch local-only branches)
6. Logs all operations

**Log location**:

```
C:\Users\{username}\Documents\Scripts\gitconfig\docs\update-gitconfig.log
```

**Log format**:

```
2025-12-18 09:15:32 - Starting git repository synchronization...
2025-12-18 09:15:33 - Fetching and fast-forwarding...
2025-12-18 09:15:35 - SUCCESS: repo up to date
2025-12-18 09:15:36 - Converging ~/.gitconfig to template...
2025-12-18 09:15:38 - Pruning merged branches...
2025-12-18 09:15:39 - Repository synchronization process completed
```

**Manual sync option**:

```powershell
# Run manually anytime
& "$env:USERPROFILE\Documents\Scripts\gitconfig\scripts\windows version\Update-GitConfig.ps1"

# Or from a non-PowerShell shell
pwsh -File "C:\Users\{username}\Documents\Scripts\gitconfig\scripts\windows version\Update-GitConfig.ps1"
```

### Scheduled Task Management

**View scheduled task**:

```powershell
Get-ScheduledTask -TaskName "GitConfig Pull at Login" | Select-Object *
```

**Manual task trigger**:

```powershell
Start-ScheduledTask -TaskName "GitConfig Pull at Login"
```

**View task history**:

```powershell
Get-ScheduledTaskInfo -TaskName "GitConfig Pull at Login"
```

**Check if auto-sync is running**:

```powershell
# Look for recent log entries
Get-Content "$env:USERPROFILE\Documents\Scripts\gitconfig\docs\update-gitconfig.log" -Tail 20
```

### Customizing Auto-Sync

**Disable scheduled task** (if needed):

```powershell
Disable-ScheduledTask -TaskName "GitConfig Pull at Login"
```

**Re-enable scheduled task**:

```powershell
Enable-ScheduledTask -TaskName "GitConfig Pull at Login"
```

**Change auto-sync frequency**:
Edit the scheduled task via Task Scheduler:

1. Open Task Scheduler
2. Select `Task Scheduler Library` (the task is registered at the root)
3. Find the "GitConfig Pull at Login" task
4. Right-click → Properties
5. Modify triggers as needed

---

## Daily Development Flow

Typical workflow from feature creation to merge.

### Morning: Start of Day

```powershell
# 1. Automated sync already ran (or run manually)
& "$env:USERPROFILE\Documents\Scripts\gitconfig\scripts\windows version\Update-GitConfig.ps1"

# 2. Check latest branches
git branches

# 3. See what changed
git log --oneline -n 10 main
```

### During Development

```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Make changes
# ... edit files ...
git add .
git commit -m "Implement core functionality"

# 3. Push regularly
git push -u origin feature/my-feature

# 4. Continue development
git add .
git commit -m "Add unit tests"
git push

# 5. Before end of day, check status
git status
git log --oneline -n 5
```

### Collaboration

```bash
# 1. Team member pushes new commits to shared branch
# 2. You get them automatically (scheduled task)
# Or manually:
git pull

# 3. Merge with team member's changes
git merge

# 4. Resolve conflicts if needed
# ... resolve conflicts ...
git add .
git commit -m "Merge team member changes"
git push
```

### Finishing a Feature

```bash
# 1. Finalize commits
git add .
git commit -m "Final feature implementation"

# 2. Push all commits
git push

# 3. Create Pull Request on GitHub (via web UI)
# ... create PR, request review ...

# 4. Address code review comments
git add .
git commit -m "Address code review feedback"
git push

# 5. PR gets merged on GitHub
# 6. Remote branch gets deleted

# 7. Update local state
git fetch --prune

# 8. Clean up local branches
git cleanup

# 9. Switch back to main
git checkout main
git pull
```

### End of Day

```bash
# 1. Verify work is pushed
git push

# 2. Check branch status
git branch -v

# 3. Clean up if needed
git cleanup

# 4. Optional: preview next day
git log --oneline -n 20 origin/main
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue: "I can't see all the remote branches"

**Symptoms**: When you run `git branch`, you don't see branches you know exist on the server.

**Solution**:

```bash
# Use our alias
git branches

# Or manually:
git fetch --all
git branch -a
```

---

#### Issue: "My cleanup deleted a branch I needed!"

**Symptoms**: You ran `git cleanup` and a branch you needed was deleted.

**Prevention**:

```bash
# Branches marked [gone] are the ones cleanup deletes
git branch -vv

git cleanup          # Deletes branches whose remote is gone
git cleanup --force  # Also deletes local-only branches already merged into main
```

**Recovery**: `git cleanup` prints each deleted branch's tip commit (the `Tip`
column), and the login-time updaters log it to `docs/update-gitconfig.log`
("was <sha>"). Recreate the branch from it:

```bash
git branch feature/recovered-branch <tip>
```

If the output is gone, find the commit in the reflog of a branch that had it
checked out, e.g. `git reflog` (HEAD's history).

---

#### Issue: "Template changes aren't taking effect" or "Symlinks aren't working"

**Symptoms**: A change to `.gitconfig.template` isn't showing up in `~/.gitconfig`, or `~/.gitignore_global` / `~/gitconfig_helper.py` is missing.

`~/.gitconfig` is **not** a symlink. It is a regular file generated from
`.gitconfig.template` and rewritten whenever the template changes, so put your own
settings in `~/.gitconfig.local` (`git localconfig`), never in `~/.gitconfig`. Only
`~/.gitignore_global` and `~/gitconfig_helper.py` are symlinks into the repo.

**Pick up template changes**:

```bash
git selfupdate   # pull this repo and regenerate ~/.gitconfig from the template
```

**Verify the symlinks**:

```powershell
cmd /c dir "$env:USERPROFILE\.gitignore_global" /AL
cmd /c dir "$env:USERPROFILE\gitconfig_helper.py" /AL

# Each should list the file as <SYMLINK> pointing into the repo
```

**Recreate them** (symlinks need admin rights: run `Initialize-Symlinks.ps1` from an
elevated PowerShell, or `install.ps1`, which elevates itself):

```powershell
cd "$HOME\Documents\Scripts\gitconfig"
& ".\scripts\windows version\Initialize-Symlinks.ps1" -Force   # symlinks only
& ".\scripts\windows version\install.ps1" -Force                # or the full setup
```

---

#### Issue: "git alias shows no aliases"

**Symptoms**: Running `git alias` shows an empty list or error.

**Solution**:

```powershell
# Verify ~/.gitconfig was generated (prints the alias definition)
git config --global --get alias.alias

# The aliases run gitconfig_helper.py from the repo, not from PATH; check it is there
Test-Path "$HOME\Documents\Scripts\gitconfig\gitconfig_helper.py"

# Regenerate ~/.gitconfig from the template
git selfupdate
```

---

#### Issue: "Scheduled task didn't run"

**Symptoms**: Repository isn't being synced automatically, log hasn't been updated.

**Check task status**:

```powershell
Get-ScheduledTask -TaskName "GitConfig Pull at Login" | Select-Object State
Get-ScheduledTaskInfo -TaskName "GitConfig Pull at Login" | Select-Object LastTaskResult

# State should be Ready (not Disabled); LastTaskResult 0 means the last run succeeded
```

**View task history**:

```powershell
Get-ScheduledTaskInfo -TaskName "GitConfig Pull at Login" | Select-Object LastRunTime, LastTaskResult
```

**Manually trigger task**:

```powershell
Start-ScheduledTask -TaskName "GitConfig Pull at Login"

# Check log immediately
Get-Content "~\Documents\Scripts\gitconfig\docs\update-gitconfig.log" -Tail 10
```

**Re-register task if needed** (for example after moving the repo), from an elevated
PowerShell, as `install.ps1` does:

```powershell
cd "$HOME\Documents\Scripts\gitconfig"
& ".\scripts\windows version\Register-LoginTask.ps1" -Force
```

This only replaces the scheduled task. Don't use `Cleanup-GitConfig.ps1` for this: it
uninstalls everything, including moving your `~/.gitconfig.local` aside.

The task runs at every login, whether or not the network is up yet: rendering
`~/.gitconfig` from the local template needs no network, and a pull that fails while
offline is logged as a warning. Re-running `install.ps1` replaces a task registered by
an older version that still waits for a network.

The macOS (launchd) and Linux (cron) jobs run the same sync; `git selfupdate` runs it
by hand on any OS (on macOS/Linux, run from a terminal, it also prints its progress and
exits 1 if the pull failed). The launchd job
logs to `docs/update-gitconfig.log` in the repo; the cron job logs to
`${XDG_STATE_HOME:-~/.local/state}/gitconfig/gitconfig-update.log` (it used the shared
`/tmp/gitconfig-update.log` before, which another user could block). To re-register
the job, re-run `bash scripts/unix/install.sh` and answer `y` when it asks to replace
the job. Answering `y` to regenerating `.gitconfig.local` too is safe: the settings you
added are kept. `--force` says yes to both. Install and cleanup only touch this clone's
cron line, so after moving a clone, remove the old path's line with `crontab -e`.

Only one sync runs at a time per user: the updater takes a lock directory,
`${XDG_STATE_HOME:-~/.local/state}/gitconfig/update.lock`, and exits 0 without doing
anything while another run holds it (`git selfupdate` says it skipped). The installer
holds it while it registers the job and installs the Python dependencies, so the sync
launchd starts at once (`RunAtLoad`) doesn't run the same pip install alongside it. A
lock whose owner has exited, or one older than an hour, is taken over. On macOS the
installer and cleanup use `launchctl bootstrap gui/<uid>` and
`launchctl bootout gui/<uid>/com.gitconfig.update`, not the deprecated `load`/`unload`.

---

#### Issue: "Python error when running git alias"

**Symptoms**: Running `git alias` or other Python-based aliases shows Python error.

**Solution**:

```powershell
# Verify Python is installed (the aliases try py, then python3, then python)
py --version

# Check gitconfig_helper.py compiles
py -m py_compile "$HOME\Documents\Scripts\gitconfig\gitconfig_helper.py"

# Reinstall rich (setup and git selfupdate install it, but you can force it)
py -m pip install --upgrade rich

# Re-run setup
& ".\scripts\windows version\install.ps1" -Force
```

---

#### Issue: "Permission denied" errors

**Symptoms**: Can't create symlinks or scheduled tasks, get admin errors.

**Solution**:

The setup scripts automatically request admin elevation. If you still get permission errors:

```powershell
# Run PowerShell as Administrator
# Then run setup again
& ".\scripts\windows version\install.ps1" -Force
```

---

#### Issue: "Where does .gitconfig.local live?"

`~/.gitconfig.local` lives in your home directory, not in this repository, so pulls
never touch it, and the repo's `.gitignore` lists `.gitconfig.local` in case a copy
ends up in the working tree. On Windows, `install.ps1` creates it once and then keeps
it, even with `-Force`. On macOS/Linux, `install.sh` asks before overwriting it, and
`install.sh --force` regenerates it, keeping the settings you added in a "Your
settings" section at the end. To regenerate it on purpose, run
`Initialize-LocalConfig.ps1 -Force` or `bash scripts/unix/initialize-local-config.sh --force`.
Every regeneration backs up the old file first. Edit it with `git localconfig`.

---

### Verifying the Setup

**Complete setup verification**:

```powershell
# 1. Check symlinks (~/.gitconfig is a generated file, not a symlink)
cmd /c dir "$env:USERPROFILE\.gitignore_global" /AL
cmd /c dir "$env:USERPROFILE\gitconfig_helper.py" /AL

# 2. Test git config
git config --list | Select-String "include|alias"

# 3. Test aliases
git alias

# 4. Test branch operations (read-only)
git branch -vv

# 5. Check scheduled task
Get-ScheduledTask -TaskName "GitConfig Pull at Login" | Select-Object State

# 6. View logs
Get-Content "$HOME\Documents\Scripts\gitconfig\docs\update-gitconfig.log" -Tail 5
```

**If everything shows green** ✅ - Your setup is working correctly!

**If something fails** ❌ - Run the setup script:

```powershell
& ".\scripts\windows version\install.ps1" -Force
```

---

## Quick Reference

### Most Common Commands

```bash
# Get all remote branches
git branches

# Clean up merged branches
git cleanup

# List all aliases
git alias

# Check automated sync
Get-Content "~\Documents\Scripts\gitconfig\docs\update-gitconfig.log" -Tail 10

# Manual sync
& ".\scripts\windows version\Update-GitConfig.ps1"
```

### When to Use Each Alias

| Situation | Command |
|-----------|---------|
| After cloning a repo | `git branches` |
| After merging PR | `git cleanup` |
| See available aliases | `git alias` |
| Daily work | Standard git commands |
| End of day cleanup | `git cleanup` |
| Check what changed | `git log` or `git status` |

---

## Additional Resources

- [Git Basics](https://git-scm.com/book/en/v2/Git-Basics-Getting-a-Git-Repository)
- [Branching and Merging](https://git-scm.com/book/en/v2/Git-Branching-Basic-Branching-and-Merging)
- [Remote Repositories](https://git-scm.com/book/en/v2/Git-Basics-Working-with-Remotes)
- [Repository Documentation](../README.md)
- [Setup Instructions](../README.md#setup)

---

**Last Updated**: October 11, 2026
**Repository**: <https://github.com/J-MaFf/gitconfig>
