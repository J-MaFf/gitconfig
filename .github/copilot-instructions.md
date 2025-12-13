# Copilot Instructions for gitconfig Repository

## Repository Overview

This repository contains Git configuration files and helper scripts for managing Git aliases and branch maintenance. It's designed to be symlinked from the home directory for easy access and version control.

## Project Structure

### Core Files

- **`.gitconfig`** - Main Git configuration file with custom aliases and settings

  - SSH signing key configuration (op-ssh-sign)
  - Custom git aliases for common workflows
  - Safe directory configurations for network repositories

- **`gitconfig_helper.py`** - Python utility script for Git operations

  - Requires: `rich` library for formatted console output
  - Functions:
    - `print_aliases()` - Display all git aliases in a formatted table
    - `cleanup_branches(force=False)` - Delete branches based on remote tracking status
      - Default: Deletes only branches with deleted remotes (merged branches)
      - With `--force`: Also deletes local-only branches (never had a remote)
  - Called via git aliases in `.gitconfig`

- **`Setup-GitConfig.ps1`** - Unified setup wrapper script

  - Orchestrates complete portable git configuration setup
  - Creates symbolic links from home directory to repo files
  - Generates machine-specific `.gitconfig.local` with SSH signing and safe directories
  - Creates Windows scheduled task for auto-sync at login
  - Backs up existing files to `Existing.<filename>.bak` before overwriting
  - Automatically elevates to admin when needed
  - Supports `-Force` flag to skip prompts, `-NoTask` to skip task creation, `-Help` for usage
  - Single command setup: `.\Setup-GitConfig.ps1 -Force`

- **`Cleanup-GitConfig.ps1`** - Cleanup and reset utility

  - Removes all gitconfig-related setup for testing/uninstalling
  - Backs up symlinks and config to `Existing.<filename>.bak`
  - Unregisters scheduled task
  - Self-verifies successful cleanup
  - Automatically elevates to admin when needed
  - Supports `-Force` flag to skip prompts, `-Help` for usage

- **`Update-GitConfig.ps1`** - Automated git pull script

  - Runs 'git pull' in the repository
  - Scheduled to run via Windows Task Scheduler at user login
  - Logs all operations to `pull-daily.log`
  - Keeps the repository synchronized with remote changes

- **`.gitconfig`** - Main git configuration (version controlled)

  - User information, aliases, and common settings
  - Includes `~/.gitconfig.local` for machine-specific paths
  - Portable across machines via git include pattern

- **`.gitconfig.local`** - Machine-specific configuration (NOT version controlled)

  - Safe directories configured per machine
  - Created by `Initialize-LocalConfig.ps1`
  - Excluded in `.gitignore`

- **`.gitignore`** - Excludes local and temporary files

  - `.gitconfig.local` - Machine-specific configuration
  - `pull-daily.log` - Daily pull task output

- **`README.md`** - Project documentation

## Development Guidelines

### Portability Requirements

**All scripts and configurations must be portable across different computers and user accounts.**

- **Never hardcode usernames or absolute paths** (e.g., `C:\Users\jmaffiola`)
- **Use environment variables** instead:
  - `$env:USERPROFILE` - User's home directory (e.g., `C:\Users\username`)
  - `$env:HOMEDRIVE` - Drive letter (e.g., `C:`)
- **Use relative paths** when possible within the repository
- **Test scripts on multiple user accounts** before committing
- **Document any machine-specific setup** required

### When Modifying Files

#### `.gitconfig` Changes

- Use proper INI syntax
- Keep aliases short and meaningful
- Document complex shell commands with comments
- Test aliases with: `git alias`

#### `gitconfig_helper.py` Changes

- Maintain Python 3.6+ compatibility
- Keep dependencies minimal (only `rich` currently)
- Auto-install missing dependencies gracefully
- Use Rich library for formatted console output
- Add error handling for git command failures

#### PowerShell Scripts

- Target PowerShell 5.1+ (Windows PowerShell) and 7+
- Use proper error handling and exit codes
- Add logging functionality
- Include help text with `-Help` parameter
- Test with and without admin privileges

### Python Aliases

When adding new Python-based git aliases:

1. Add the function to `gitconfig_helper.py`
2. Add a corresponding git alias in `.gitconfig`
3. Use the pattern: `!python ${USERPROFILE}/Documents/Scripts/gitconfig/gitconfig_helper.py function_name $@`
   - Note: Use `$@` to pass command-line arguments/flags to the Python script

### Git Aliases Reference

Current custom aliases:

- `git alias` - List all aliases in a formatted table
- `git branches` - Download all remote branches and create local tracking branches
- `git cleanup` - Delete branches with deleted remotes (merged branches)
  - `git cleanup --force` (or `-f`) - Also delete local-only branches that never had a remote

## Workflow

1. **Initial Setup**

   - Clone the repository
   - Run `Setup-GitConfig.ps1 -Force` to complete all setup steps
   - Verify with `git alias` command

2. **Testing/Resetting**

   - Run `Cleanup-GitConfig.ps1 -Force` to remove all setup
   - Files are backed up to `Existing.<filename>.bak` for recovery
   - Can re-run `Setup-GitConfig.ps1 -Force` to test fresh setup

3. **Daily Updates**

   - `Update-GitConfig.ps1` runs automatically at user login
   - Changes are automatically pulled from remote

4. **Making Changes**
   - Edit files in the repository
   - Commit with descriptive messages
   - Push to GitHub
   - Changes automatically reflect in symlinked files

## Environment Notes

- User: Joey Maffiola (7maffiolajoey@gmail.com)
- Repository: https://github.com/J-MaFf/gitconfig
- Local Path: `$env:USERPROFILE\Documents\Scripts\gitconfig` (portable across all machines)

## Testing Recommendations

- Test git aliases after modifications: `git alias`
- Test cleanup functionality in a test branch
- Verify symlinks point to correct files
- Check `pull-daily.log` for scheduled task execution

## Known Limitations

- Windows-only (PowerShell scripts)
- Requires administrator privileges for symlink creation
- Python scripts depend on `rich` library
- Safe directory configs may need updates for new network paths
