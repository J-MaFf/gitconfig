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
    - `cleanup_branches()` - Delete local branches with no remote tracking
  - Called via git aliases in `.gitconfig`

- **`Initialize-Symlinks.ps1`** - PowerShell script to set up symlinks
  - Creates symbolic links from home directory to repo files
  - Supports `-Force` flag to overwrite without prompting
  - Requires admin privileges for symlink creation
  - Called during initial setup only

- **`pull-daily.ps1`** - Automated daily git pull script
  - Runs via Windows Task Scheduler (default: 8:00 AM daily)
  - Logs all operations to `pull-daily.log`
  - Keeps the repository synchronized with remote changes

- **`.gitignore`** - Excludes local logs and temporary files
  - `pull-daily.log` - Daily pull task output

- **`README.md`** - Project documentation

## Development Guidelines

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
3. Use the pattern: `!python ${USERPROFILE}/Documents/Scripts/python_functions/gitconfig_helper.py function_name`

### Git Aliases Reference
Current custom aliases:
- `git alias` - List all aliases
- `git branches` - Download and track all remote branches
- `git cleanup` - Remove obsolete local branches

## Workflow

1. **Initial Setup**
   - Clone the repository
   - Run `Initialize-Symlinks.ps1` to create symlinks
   - Verify with `git alias` command

2. **Daily Updates**
   - `pull-daily.ps1` runs automatically at 8:00 AM
   - Changes are automatically pulled from remote

3. **Making Changes**
   - Edit files in the repository
   - Commit with descriptive messages
   - Push to GitHub
   - Changes automatically reflect in symlinked files

## Environment Notes
- User: Joey Maffiola (7maffiolajoey@gmail.com)
- Repository: https://github.com/J-MaFf/gitconfig
- Local Path: C:\Users\jmaffiola\Documents\Scripts\gitconfig

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
