# Copilot Instructions for gitconfig Repository

## Repository Overview

This repository contains Git configuration files and helper scripts for managing Git aliases and branch maintenance. It's designed to be symlinked from the home directory for easy access and version control.

## Project Structure

```
gitconfig/
├── README.md                           # Main project documentation
├── .gitconfig                          # Main Git configuration (version controlled)
├── .gitignore                          # Git ignore patterns
├── gitconfig_helper.py                 # Python utility for Git operations
├── knowledge-graph.jsonl               # Memory MCP server knowledge graph
│
├── .github/
│   └── copilot-instructions.md        # Development guidelines and instructions
│
├── .vscode/
│   ├── mcp.json                       # VS Code MCP server configuration
│   └── settings.json                  # VS Code workspace settings
│
├── config/
│   └── pester.config.ps1              # Pester test configuration
│
├── docs/
│   ├── CHANGELOG.md                   # Version history and changes
│   └── BRANCH_PROTECTION.md           # Branch protection rules documentation
│
├── scripts/
│   ├── Setup-GitConfig.ps1            # Unified setup wrapper script
│   ├── Initialize-Symlinks.ps1        # Create symbolic links
│   ├── Initialize-LocalConfig.ps1     # Generate machine-specific config
│   ├── Register-LoginTask.ps1         # Create scheduled task
│   ├── Update-GitConfig.ps1           # Automated synchronization at login
│   └── Cleanup-GitConfig.ps1          # Uninstall and reset utility
│
└── tests/
    ├── run-tests.ps1                  # Test runner script
    ├── Setup-GitConfig.Tests.ps1      # Setup script tests
    ├── Cleanup-GitConfig.Tests.ps1    # Cleanup script tests
    ├── gitconfig_helper.Tests.ps1     # Python helper tests
    └── Integration.Tests.ps1          # Integration tests
```

### Core Files

- **`.gitconfig`** - Main Git configuration file with custom aliases and settings

  - SSH signing key configuration (op-ssh-sign)
  - Custom git aliases for common workflows
  - Safe directory configurations for network repositories
  - Includes `~/.gitconfig.local` for machine-specific paths
  - References `~/.gitignore_global` for project-wide ignore patterns

- **`.gitignore_global`** - Global gitignore patterns for all repositories

  - IDE configurations (VS Code, JetBrains, Vim, Sublime, Emacs, Atom)
  - OS-specific files (macOS, Windows, Linux)
  - Language artifacts (Python, Node.js, Go, Java, Ruby, C/C++)
  - Build outputs and temporary files
  - Local configuration and credentials
  - Symlinked to `~/.gitignore_global` for all Git repositories

- **`gitconfig_helper.py`** - Python utility script for Git operations

  - Requires: `rich` library for formatted console output
  - Functions:
    - `print_aliases()` - Display all git aliases in a formatted table
    - `cleanup_branches(force=False)` - Delete branches based on remote tracking status
      - Default: Deletes only branches with deleted remotes (merged branches)
      - With `--force`: Also deletes local-only branches (never had a remote)
  - Called via git aliases in `.gitconfig`

- **`knowledge-graph.jsonl`** - Memory MCP server knowledge graph

  - JSONL format (one JSON object per line)
  - Documents project entities, observations, and relationships
  - Tracked in Git for backup and synchronization across machines

- **`pull-daily.log`** - Log file for automated daily synchronization
  - Records all operations from `Update-GitConfig.ps1` scheduled task
  - Useful for troubleshooting auto-sync issues

### Scripts (scripts/ folder)

- **`Setup-GitConfig.ps1`** - Unified setup wrapper script

  - Orchestrates complete portable git configuration setup
  - Creates symbolic links from home directory to repo files
  - Generates machine-specific `.gitconfig.local` with SSH signing and safe directories
  - Creates Windows scheduled task for auto-sync at login
  - Backs up existing files to `Existing.<filename>.bak` before overwriting
  - Automatically elevates to admin when needed
  - Supports `-Force` flag to skip prompts, `-NoTask` to skip task creation, `-Help` for usage
  - Single command setup: `.\Setup-GitConfig.ps1 -Force`

- **`Initialize-Symlinks.ps1`** - Create symbolic links from home directory to repo files

  - Creates symlinks for `.gitconfig` and `gitconfig_helper.py`
  - Requires administrator privileges for symlink creation on Windows
  - Supports `-Force` flag to overwrite existing files without prompting
  - Supports `-Help` parameter for documentation

- **`Initialize-LocalConfig.ps1`** - Generate machine-specific configuration

  - Creates `~/.gitconfig.local` with SSH signing and safe directories
  - Generates configuration specific to each machine
  - Uses environment variables for portability

- **`Register-LoginTask.ps1`** - Create Windows scheduled task for auto-sync

  - Creates scheduled task to run `Update-GitConfig.ps1` at user login
  - Supports `-Force` flag to overwrite existing task

- **`Update-GitConfig.ps1`** - Automated synchronization at user login

  - Switches to main branch
  - Pulls latest changes from remote
  - Syncs remote tracking branches (safe, doesn't modify user's work branches)
  - Logs all operations to `docs/update-gitconfig.log`
  - Runs silently via Windows Task Scheduler

- **`Cleanup-GitConfig.ps1`** - Uninstall and reset utility
  - Removes all gitconfig-related setup for testing/uninstalling
  - Backs up symlinks and config to `Existing.<filename>.bak`
  - Unregisters scheduled task
  - Self-verifies successful cleanup
  - Automatically elevates to admin when needed

### Documentation (docs/ folder)

- **`CHANGELOG.md`** - Version history and changes

  - Documents all versions starting with v0.1.0-pre
  - Follows semantic versioning and Keep a Changelog format

- **`BRANCH_PROTECTION.md`** - Branch protection rules documentation
  - Documents GitHub branch protection rules for main branch
  - Includes setup instructions via GitHub web UI and PowerShell CLI
  - References GitHub API documentation

### Configuration (config/ folder)

- **`pester.config.ps1`** - Pester test configuration
  - Configuration file for PowerShell Pester tests
  - Located in config/ folder for better organization

### Tests (tests/ folder)

- **`run-tests.ps1`** - Test runner script

  - Orchestrates all test execution
  - Runs all PowerShell test files

- **`Setup-GitConfig.Tests.ps1`** - Tests for Setup-GitConfig.ps1
- **`Cleanup-GitConfig.Tests.ps1`** - Tests for Cleanup-GitConfig.ps1
- **`gitconfig_helper.Tests.ps1`** - Tests for gitconfig_helper.py helper functions
- **`Integration.Tests.ps1`** - End-to-end integration tests

### GitHub Configuration (.github/ folder)

- **`copilot-instructions.md`** - Development guidelines and instructions

  - Semantic versioning reference (semver.org)
  - Portability requirements and best practices
  - Contribution guidelines

- **`WORKFLOW.md`** - Comprehensive workflow documentation
  - Git aliases usage guide with examples
  - Branch management best practices
  - Automated task documentation
  - Daily development flow walkthrough
  - Extensive troubleshooting section
  - Quick reference and common scenarios

### VS Code Configuration (.vscode/ folder)

- **`mcp.json`** - VS Code MCP server configuration

  - Memory MCP server configured at workspace level
  - Uses `@modelcontextprotocol/server-memory` for knowledge graph

- **`settings.json`** - VS Code workspace settings

  - Project-specific editor configuration

- **`README.md`** - Project documentation

## Development Guidelines

### Semantic Versioning

This project follows [Semantic Versioning (semver.org)](https://semver.org/) for all releases and tags.

**Key Principles:**

- **Format:** `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`
  - `MAJOR` - Breaking changes
  - `MINOR` - New features (backward compatible)
  - `PATCH` - Bug fixes (backward compatible)
  - `PRERELEASE` - Alpha, beta, RC versions (prefix with 0 for pre-release versions)
  - `BUILD` - Build metadata (optional)

**Pre-release Guidelines:**

- Pre-release versions for initial development start with `0.x.y` (e.g., `v0.1.0-alpha`, `v0.1.0-beta`)
- Use `-pre`, `-alpha`, `-beta`, or `-rc.N` suffixes for pre-release tags
- Example progression: `v0.1.0-alpha` → `v0.1.0-beta` → `v0.1.0-rc.1` → `v0.1.0`
- Do NOT use pre-release tags for stable releases

**Release Process:**

1. Use `git tag -a vX.Y.Z -m "Release description"` to create annotated tags
2. Push tags with `git push origin vX.Y.Z`
3. Update CHANGELOG with version-specific changes
4. Major releases require documentation updates

**Reference:** https://semver.org/

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
- **IMPORTANT: Git config does NOT support backslashes in file paths** - Always use forward slashes (/) in paths, even on Windows. Git will reject INI lines with backslash-separated paths as invalid syntax.

#### `.gitconfig.local` Generation

- Machine-specific SSH signing configuration (1Password op-ssh-sign)
- Must use forward slashes in all paths (Git config requirement)
- Includes gpg.format=ssh, gpg.ssh.program, user.signingKey, and commit.gpgsign
- Pattern: `$homeDir -replace '\\', '/'` to convert Windows paths to forward slashes
- Example: `C:/Users/username/AppData/Local/Microsoft/WindowsApps/op-ssh-sign.exe`

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
- **IMPORTANT: Fix script generation issues by modifying the script template, never by manually editing generated files** - If a generated file (like .gitconfig.local) has incorrect content, the script that generates it must be fixed so it produces the correct output

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
  - Uses `git fetch` to sync remote refs
  - Creates local tracking branches for each remote branch
  - Error suppression (|| true) to handle existing branches gracefully
  - Returns exit code 0 for successful completion
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
