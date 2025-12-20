# Copilot Instructions for gitconfig Repository

## Repository Overview

This repository contains Git configuration files and helper scripts for managing Git aliases and branch maintenance. It uses a **template-based generation** approach for maximum portability across machines.

## Project Structure

```
gitconfig/
├── README.md                           # Main project documentation
├── .gitconfig.template                 # Template for generating .gitconfig (version controlled)
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
│   ├── Initialize-GitConfig.ps1       # Generate .gitconfig from template
│   ├── Initialize-Symlinks.ps1        # Create symbolic links
│   ├── Initialize-LocalConfig.ps1     # Generate machine-specific config
│   ├── Register-LoginTask.ps1         # Create scheduled task
│   ├── Update-GitConfig.ps1           # Automated synchronization at login
│   └── Cleanup-GitConfig.ps1          # Uninstall and reset utility
│
└── tests/
    ├── run-tests.ps1                  # Test runner script
    ├── Setup-GitConfig.Tests.ps1      # Setup script tests
    ├── Initialize-GitConfig.Tests.ps1 # Config generation tests
    ├── Cleanup-GitConfig.Tests.ps1    # Cleanup script tests
    ├── gitconfig_helper.Tests.ps1     # Python helper tests
    └── Integration.Tests.ps1          # Integration tests
```

### Core Files

- **`.gitconfig.template`** - Template for generating machine-specific Git configuration

  - Contains placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}`
  - Version controlled for consistency across machines
  - Custom git aliases for common workflows
  - Includes `~/.gitconfig.local` for machine-specific paths
  - References `~/.gitignore_global` for project-wide ignore patterns

- **`~/.gitconfig`** - Generated Git configuration (NOT version controlled)

  - Generated from `.gitconfig.template` by `Initialize-GitConfig.ps1`
  - Placeholders replaced with machine-specific absolute paths
  - Each machine generates its own version during setup

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
  - Generates `~/.gitconfig` from `.gitconfig.template` with machine-specific paths
  - Creates symbolic links for `.gitignore_global` and `gitconfig_helper.py`
  - Generates machine-specific `.gitconfig.local` with SSH signing and safe directories
  - Creates Windows scheduled task for auto-sync at login
  - Backs up existing files to `Existing.<filename>.bak` before overwriting
  - Automatically elevates to admin when needed
  - Supports `-Force` flag to skip prompts, `-NoTask` to skip task creation, `-Help` for usage
  - Single command setup: `.\Setup-GitConfig.ps1 -Force`

- **`Initialize-GitConfig.ps1`** - Generate .gitconfig from template

  - Generates `~/.gitconfig` from `.gitconfig.template`
  - Replaces placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}`
  - Converts paths to forward slashes for git config compatibility
  - Creates backup if existing .gitconfig found
  - Verifies generated config is valid INI format
  - Supports `-Force` flag to overwrite without prompting
  - Supports `-Help` parameter for documentation

- **`Initialize-Symlinks.ps1`** - Create symbolic links from home directory to repo files

  - Creates symlinks for `.gitignore_global` and `gitconfig_helper.py`
  - No longer creates `.gitconfig` symlink (now generated from template)
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

### Branch Protection Rules

**CRITICAL: The `main` branch is protected and does NOT accept direct commits.**

- **All changes to `main` must go through pull requests**
- **Never commit directly to `main` branch**
- **Always create a feature/bugfix branch for any changes**
- **Workflow:**
  1. Create a new branch: `git checkout -b feature/your-feature-name`
  2. Make your changes and commit
  3. Push the branch: `git push origin feature/your-feature-name`
  4. Open a pull request on GitHub
  5. PR gets merged to `main` (only valid merge method allowed)
  6. Delete the feature branch after merge: `git cleanup`

This ensures all changes are reviewed and tracked through pull requests.

### Portability Requirements

**All scripts and configurations must be portable across different computers and user accounts.**

- **Never hardcode usernames or absolute paths** (e.g., `C:\Users\jmaffiola`)
- **Use template placeholders** for dynamic values in `.gitconfig.template`:
  - `{{REPO_PATH}}` - Repository absolute path (replaced during generation)
  - `{{HOME_DIR}}` - User's home directory (replaced during generation)
- **Use environment variables** in PowerShell scripts:
  - `$env:USERPROFILE` - User's home directory (e.g., `C:\Users\username`)
  - `$env:HOMEDRIVE` - Drive letter (e.g., `C:`)
- **Use relative paths** when possible within the repository
- **Test scripts on multiple user accounts** before committing
- **Document any machine-specific setup** required

### When Modifying Files

#### `.gitconfig.template` Changes

- Use proper INI syntax with placeholders
- Keep aliases short and meaningful
- Document complex shell commands with comments
- Use `{{REPO_PATH}}` for repository-specific paths
- Use `{{HOME_DIR}}` for home directory paths (if needed)
- **IMPORTANT: Git config does NOT support backslashes in file paths** - Always use forward slashes (/) in paths, even on Windows. Git will reject INI lines with backslash-separated paths as invalid syntax.
- Test generated config with: `.\scripts\Initialize-GitConfig.ps1 -Force && git alias`

#### Config Generation (`Initialize-GitConfig.ps1`)

- Reads `.gitconfig.template`
- Replaces `{{REPO_PATH}}` with repository absolute path
- Replaces `{{HOME_DIR}}` with user's home directory
- Converts all Windows paths to forward slashes for git compatibility
- Pattern: `$repoRoot -replace '\\', '/'`
- Validates generated config with `git config --file <path> --list`

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
2. Add a corresponding git alias in `.gitconfig.template`
3. Use the pattern: `main = !python {{REPO_PATH}}/gitconfig_helper.py function_name`
   - Use `{{REPO_PATH}}` placeholder in template (gets replaced during setup)
   - Pass command-line arguments after the function name if needed

### Using gitconfig_helper.py for New Functions

The `gitconfig_helper.py` file (#file:gitconfig_helper.py) provides a robust foundation for implementing git operations. When creating new git alias functions:

**Function Pattern to Follow:**

```python
def your_function_name():
    """Brief description of what the function does.
    
    Steps:
    1. First step
    2. Second step
    3. etc.
    """
    console = Console()
    
    try:
        # Verify we're in a git repository
        result = subprocess.run(
            ["git", "rev-parse", "--git-dir"], 
            capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            console.print("[red]Error: Not in a git repository[/red]")
            return 1
        
        # Your implementation here with Rich console output
        console.print("[cyan]Status message[/cyan]")
        console.print("[green]✓ Success message[/green]")
        return 0
        
    except subprocess.CalledProcessError as e:
        console.print(f"[red]Error: {e}[/red]")
        return 1
```

**Key Requirements:**

- Use `subprocess.run()` for git commands with `capture_output=True, text=True, check=False`
- Return `0` for success, `1+` for specific failure types
- Use Rich console with color codes: `[red]`, `[green]`, `[cyan]`, `[yellow]`, `[dim]`
- Check for git repository at start: `git rev-parse --git-dir`
- Provide clear error messages for each failure point
- Support passing arguments via `sys.argv[2:]`
- Update the `__main__` section to handle the new command

**Adding to .gitconfig.template:**

```ini
[alias]
    your_alias = !python {{REPO_PATH}}/gitconfig_helper.py your_function_name
```

**Examples in Repository:**

- `switch_to_main()` - Full error handling with merge conflict detection
- `cleanup_branches(force=False)` - Complex branch operations with Rich tables
- `print_aliases()` - Table formatting and display

**Testing New Functions:**

Add comprehensive test cases to `tests/gitconfig_helper.Tests.ps1`:
- Verify git repo detection
- Test error scenarios (uncommitted changes, failed operations)
- Verify exit codes (0 = success, 1 = failure)
- Check Rich console output formatting
- Use temporary test repositories for integration testing

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
- `git main` - Switch to main branch with full error handling
  - Fetches updates from remote (with pruning)
  - Checks for uncommitted changes (prevents data loss)
  - Switches to main branch
  - Pulls latest changes
  - Detects and reports merge conflicts
  - Clear error messages guide user through resolution

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
