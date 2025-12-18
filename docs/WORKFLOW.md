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

**1. Default mode** - Delete branches with deleted remotes (merged branches)

```bash
git cleanup
```

Deletes local branches whose remote tracking branches have been deleted. This is safe because:

- Remote branch was already deleted (likely merged)
- Local branch is no longer being tracked
- Deletion won't lose work already in the repository

**2. Force mode** - Also delete local-only branches

```bash
git cleanup --force
# or
git cleanup -f
```

Additionally deletes branches that never had a remote (local-only branches). Use with caution when:

- You're sure the branch is no longer needed
- Work has been merged or saved elsewhere
- You want aggressive cleanup of abandoned branches

**When to use**:

- **After merging PRs**: Remote branches get deleted, local cleanup keeps things tidy
- **End of sprint**: Clean up temporary feature/bugfix branches
- **Repository maintenance**: Regular cleanup prevents branch clutter
- **Before pushing changes**: Ensure local state matches intent

**Example workflow**:

```bash
# Merge PR, remote branch gets deleted
# Local tracking branch still exists

# Clean up merged branches
git cleanup

# Output shows what was deleted
Deleting branches with deleted remotes:
✓ Deleted: feature/user-auth (was tracking origin/feature/user-auth)
✓ Deleted: bugfix/login (was tracking origin/bugfix/login)

# If you want aggressive cleanup too
git cleanup --force

# Output shows additional deletions
Also deleting local-only branches:
✓ Deleted: experimental (never had remote)
✓ Deleted: old-feature (never had remote)
```

**Safety features**:

- Won't delete your current branch
- Shows what will be deleted before proceeding
- Requires confirmation in interactive mode
- Skips branches with unpushed commits (unless forced)

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

### Update-GitConfig.ps1 (formerly pull-daily.ps1)

**Purpose**: Automatically synchronize repository changes at user login

**What it does**:

1. Runs at Windows user login (via Scheduled Task)
2. Switches to main branch
3. Runs `git pull` to fetch latest changes
4. Syncs remote tracking branches (doesn't modify your work branches)
5. Logs all operations

**Log location**:

```
C:\Users\{username}\Documents\Scripts\gitconfig\docs\pull-daily.log
```

**Log format**:

```
[2025-12-18 09:15:32] Update-GitConfig started
[2025-12-18 09:15:33] Switched to branch 'main'
[2025-12-18 09:15:34] Pulling latest changes...
[2025-12-18 09:15:35] Pull completed successfully
[2025-12-18 09:15:36] Syncing remote tracking branches...
```

**Manual sync option**:

```bash
# Run manually anytime
C:\Users\{username}\Documents\Scripts\gitconfig\scripts\Update-GitConfig.ps1

# Or from PowerShell
pwsh -File "C:\Users\{username}\Documents\Scripts\gitconfig\scripts\Update-GitConfig.ps1"
```

### Scheduled Task Management

**View scheduled task**:

```powershell
Get-ScheduledTask -TaskName "Update Git Config" | Select-Object *
```

**Manual task trigger**:

```powershell
Start-ScheduledTask -TaskName "Update Git Config"
```

**View task history**:

```powershell
Get-ScheduledTaskInfo -TaskName "Update Git Config"
```

**Check if auto-sync is running**:

```bash
# Look for recent log entries
Get-Content "C:\Users\7maff\Documents\Scripts\gitconfig\docs\pull-daily.log" -Tail 20
```

### Customizing Auto-Sync

**Disable scheduled task** (if needed):

```powershell
Disable-ScheduledTask -TaskName "Update Git Config"
```

**Re-enable scheduled task**:

```powershell
Enable-ScheduledTask -TaskName "Update Git Config"
```

**Change auto-sync frequency**:
Edit the scheduled task via Task Scheduler:

1. Open Task Scheduler
2. Navigate to `Library\Microsoft\Windows\PowerShell\ScheduledJobs`
3. Find "Update Git Config" task
4. Right-click → Properties
5. Modify triggers as needed

---

## Daily Development Flow

Typical workflow from feature creation to merge.

### Morning: Start of Day

```bash
# 1. Automated sync already ran (or run manually)
C:\Users\{username}\Documents\Scripts\gitconfig\scripts\Update-GitConfig.ps1

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
# Always check what cleanup will delete first
git branch -vv

# Only use --force if you understand the consequences
git cleanup        # Safe - only removes already-merged branches
git cleanup --force  # Aggressive - removes all stale branches
```

**Recovery** (if recently deleted):

```bash
# Check reflog for deleted branch
git reflog

# Restore deleted branch (if still in reflog)
git checkout -b feature/recovered-branch {commit-hash}
```

---

#### Issue: "Symlinks aren't working"

**Symptoms**: Changes to `.gitconfig` aren't taking effect, or `gitconfig_helper.py` can't be found.

**Verify symlinks**:

```powershell
# Check if symlinks exist
cmd /c dir "$env:USERPROFILE\.gitconfig" /L
cmd /c dir "$env:USERPROFILE\gitconfig_helper.py" /L

# Should show "<SYMLINK>" in the output
```

**Recreate symlinks**:

```powershell
# Run setup script
cd ~\Documents\Scripts\gitconfig
.\scripts\Setup-GitConfig.ps1 -Force
```

---

#### Issue: "git alias shows no aliases"

**Symptoms**: Running `git alias` shows an empty list or error.

**Solution**:

```bash
# Verify setup is complete
git config --get-all alias.alias

# Check if gitconfig_helper.py is in path
Get-Command gitconfig_helper.py

# Re-run setup
.\scripts\Setup-GitConfig.ps1 -Force
```

---

#### Issue: "Scheduled task didn't run"

**Symptoms**: Repository isn't being synced automatically, log hasn't been updated.

**Check task status**:

```powershell
Get-ScheduledTask -TaskName "Update Git Config" | Select-Object State, LastTaskResult

# Should show State: Enabled
# LastTaskResult: 0 (success)
```

**View task history**:

```powershell
Get-ScheduledTaskInfo -TaskName "Update Git Config" | Select-Object LastRunTime, LastTaskResult
```

**Manually trigger task**:

```powershell
Start-ScheduledTask -TaskName "Update Git Config"

# Check log immediately
Get-Content "~\Documents\Scripts\gitconfig\docs\pull-daily.log" -Tail 10
```

**Re-register task if needed**:

```powershell
.\scripts\Cleanup-GitConfig.ps1 -Force
.\scripts\Setup-GitConfig.ps1 -Force
```

---

#### Issue: "Python error when running git alias"

**Symptoms**: Running `git alias` or other Python-based aliases shows Python error.

**Solution**:

```bash
# Verify Python is installed
python --version

# Check gitconfig_helper.py syntax
python "~\Documents\Scripts\gitconfig\gitconfig_helper.py"

# Reinstall rich library (auto-installs but you can force it)
pip install --upgrade rich

# Re-run setup
.\scripts\Setup-GitConfig.ps1 -Force
```

---

#### Issue: "Permission denied" errors

**Symptoms**: Can't create symlinks or scheduled tasks, get admin errors.

**Solution**:

The setup scripts automatically request admin elevation. If you still get permission errors:

```powershell
# Run PowerShell as Administrator
# Then run setup again
.\scripts\Setup-GitConfig.ps1 -Force
```

---

#### Issue: "Merge conflicts with .gitconfig.local"

**Symptoms**: Getting merge conflicts when pulling from main.

**Solution**:

```bash
# .gitconfig.local is machine-specific and shouldn't be in version control
# It should be in .gitignore

# Check if it's tracked
git ls-files | grep gitconfig.local

# If tracked, remove it
git rm --cached .gitconfig.local

# Verify .gitignore has it
cat .gitignore | grep gitconfig.local

# If not there, add it
echo ".gitconfig.local" >> .gitignore

# Commit the fix
git add .gitignore
git commit -m "Remove .gitconfig.local from version control"
git push
```

---

### Verifying the Setup

**Complete setup verification**:

```bash
# 1. Check symlinks
cmd /c dir "$env:USERPROFILE\.gitconfig" /L
cmd /c dir "$env:USERPROFILE\gitconfig_helper.py" /L

# 2. Test git config
git config --list | grep -E "include|alias"

# 3. Test aliases
git alias

# 4. Test branch operations
git branches
git cleanup

# 5. Check scheduled task
Get-ScheduledTask -TaskName "Update Git Config" | Select-Object State

# 6. View logs
Get-Content "~\Documents\Scripts\gitconfig\docs\pull-daily.log" -Tail 5
```

**If everything shows green** ✅ - Your setup is working correctly!

**If something fails** ❌ - Run the setup script:

```powershell
.\scripts\Setup-GitConfig.ps1 -Force
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
Get-Content "~\Documents\Scripts\gitconfig\docs\pull-daily.log" -Tail 10

# Manual sync
.\scripts\Update-GitConfig.ps1
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

**Last Updated**: December 18, 2025
**Repository**: <https://github.com/J-MaFf/gitconfig>
