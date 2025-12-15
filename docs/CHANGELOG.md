# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-pre] - 2025-12-15

### Added

- **Git Configuration (`gitconfig`)**
  - SSH-based commit signing with OpenSSH key format (ed25519)
  - Custom git aliases for common workflows
  - Auto-setup remote tracking for pushed branches
  - VS Code as default editor with `--wait` flag
  - Safe directory configurations for network and local repositories

- **Git Helper (`gitconfig_helper.py`)**
  - `print_aliases()` - Display all configured aliases in formatted table
  - `cleanup_branches()` - Delete local branches with deleted remotes or unused local branches
  - Support for `--force` flag to include local-only branch deletion
  - Formatted console output using Rich library

- **Setup Automation (PowerShell Scripts)**
  - `Setup-GitConfig.ps1` - Unified setup wrapper orchestrating complete configuration
  - `Initialize-Symlinks.ps1` - Create symbolic links from home directory to repo files
  - `Initialize-LocalConfig.ps1` - Generate machine-specific `.gitconfig.local`
  - `Register-LoginTask.ps1` - Create Windows scheduled task for auto-sync
  - `Update-GitConfig.ps1` - Automated daily git pull via Task Scheduler
  - `Cleanup-GitConfig.ps1` - Clean uninstall and reset utility

- **Configuration Files**
  - `.gitignore` - Excludes `.gitconfig.local` and log files
  - `.github/copilot-instructions.md` - Development guidelines with semantic versioning reference
  - Tests in `tests/` directory for PowerShell scripts and Python helpers

- **Features**
  - Portable configuration across different machines and user accounts
  - Environment variable support (no hardcoded paths)
  - Automatic backup of existing files to `.bak` before overwriting
  - Admin privilege handling with automatic elevation
  - Machine-specific configuration via `.gitconfig.local`
  - Support for network repositories as safe directories
  - Daily automatic synchronization via Windows Task Scheduler
  - Comprehensive help text with `-Help` parameter on scripts

### Git Aliases

- `git alias` - List all aliases in a formatted table
- `git branches` - Download all remote branches and create local tracking branches
- `git cleanup` - Delete branches with deleted remotes (merged branches)
- `git cleanup --force` - Also delete local-only branches never pushed to remote
- `git localconfig` - Manage machine-specific git configuration

### Documentation

- Comprehensive README with installation and usage instructions
- Troubleshooting guide for common issues
- Configuration details for SSH signing and safe directories
- Development guidelines following Semantic Versioning (semver.org)
- This CHANGELOG documenting all changes

---

## Unreleased

### Planned

- Additional git aliases for common workflows
- Support for GPG signing in addition to SSH
- Extended logging and diagnostics
- Configuration validation and health checks
