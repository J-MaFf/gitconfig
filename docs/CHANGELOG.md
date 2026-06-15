# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `git selfupdate` alias — pulls the gitconfig repo and reinstalls `~/.gitconfig` from
  the template on demand, dispatching to the correct platform script
  (PowerShell on Windows, bash on macOS/Linux) ([#78](https://github.com/J-MaFf/gitconfig/issues/78))
- `git skill-sync` alias — on-demand `pull --ff-only` of the claude-skills repo
  (`~/.claude/skills`), mirroring the auto-sync's fast-forward-only safety ([#83](https://github.com/J-MaFf/gitconfig/issues/83))
- `git skill-publish` alias — publish new/edited skills in the claude-skills repo
  (`~/.claude/skills`) from any directory via a PR. Delegates to that repo's
  `publish-skill` script (branch → signed commit → PR → squash auto-merge), since its
  `main` is now branch-protected and can't be pushed to directly. Dispatches by OS
  like `selfupdate` ([#82](https://github.com/J-MaFf/gitconfig/issues/82))

### Changed

- The auto-update job (`git selfupdate` and the login-triggered run) now **prunes
  merged branches** instead of recreating them. It fetches with `--prune` to drop
  stale remote-tracking refs and deletes local branches whose upstream remote was
  deleted (`: gone]`), mirroring the `git cleanup` alias. The previous behavior
  recreated a local tracking branch for every remote on every run, so merged
  branches accumulated and deleted branches were resurrected. Creating tracking
  branches for all remotes is still available on demand via `git branches`
  ([#93](https://github.com/J-MaFf/gitconfig/issues/93))

### Fixed

- `git alias`, `git cleanup`, and `git main` no longer print a spurious
  "Python was not found" line on Windows. The aliases resolved Python with
  `command -v python3`, which matches the Microsoft Store app-execution-alias stub;
  the stub ran first, emitted the message, and exited before the real `python` fallback.
  The aliases now resolve `py -> python3 -> python` and verify each interpreter actually
  runs (`-c ''`) before using it, skipping the stub. Apply on an installed machine with
  `git selfupdate`. Added a Pester guard (`tests/GitconfigTemplate.Tests.ps1`)
  ([#91](https://github.com/J-MaFf/gitconfig/issues/91))
- `git cleanup` (and `git main`) no longer crash with `UnicodeEncodeError` on the
  legacy Windows console. `gitconfig_helper.py` printed a `✓` checkmark and `──`
  box-drawing characters via `rich`, which fall back to the cp1252 renderer and cannot
  encode those glyphs. Replaced them with ASCII equivalents (`[OK]`, `--`) matching the
  `[OK]`/`[WARN]` convention, and added a Pester guard asserting the helper is ASCII-only
  ([#87](https://github.com/J-MaFf/gitconfig/issues/87))
- `install.ps1` no longer fails to parse under Windows PowerShell 5.1. The script
  contained em dash characters (`—`) and lacked a UTF-8 BOM, so the legacy ANSI-codepage
  reader mangled them into smart-quotes that broke string literals. Em dashes are now
  ASCII hyphens and the file carries a BOM. Added a Pester guard test
  (`tests/Encoding.Tests.ps1`) asserting every `scripts/windows version/*.ps1` is
  ASCII-only and parses cleanly ([#85](https://github.com/J-MaFf/gitconfig/issues/85))
- Login auto-update now reinstalls `~/.gitconfig` when `.gitconfig.template` changed
  during the pull, instead of only pulling. Template changes (new aliases, signing/push
  tweaks) take effect automatically with no manual re-run. The existing `~/.gitconfig`
  is backed up to `~/.gitconfig.bak` first; `~/.gitconfig.local` is never touched
  ([#78](https://github.com/J-MaFf/gitconfig/issues/78))

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
  - `install.ps1` - Unified setup wrapper orchestrating complete configuration
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

## [Unreleased]

### New Features

- **Enhanced `git main` Alias**
  - Automatic cleanup of branches with deleted remotes during `git main`
  - Integrated `cleanup_branches()` function into switch_to_main workflow
  - Merged branches are removed without requiring separate `git cleanup` call
  - Local-only branches are preserved (use `git cleanup --force` if needed)

- **Template-Based Configuration**
  - `.gitconfig.template` - Version-controlled template with placeholders
  - `Initialize-GitConfig.ps1` - Script to generate `.gitconfig` from template
  - Placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}` replaced during generation
  - Automatic path conversion to forward slashes for git compatibility

- **Additional Tests**
  - `Initialize-GitConfig.Tests.ps1` - Comprehensive tests for config generation
  - Tests verify placeholder replacement, path conversion, INI format validity

### Improvements

- **`git main` Workflow Order**
  - Main branch is pulled/updated before cleanup runs
  - Cleanup has accurate information about deleted branches
  - Ensures current branch (with deleted remote) is safely switched before cleanup
  - Logical sequence: switch to main → pull latest → cleanup stale branches

- **Portability**: No hardcoded paths in version control
- **Maintainability**: Changes to template automatically propagate on regeneration
- **Documentation**: Updated README, copilot-instructions.md to reflect new architecture
- **Testing**: Updated `Setup-GitConfig.Tests.ps1` to verify generation instead of symlinking

### Breaking Changes

- **BREAKING**: `.gitconfig` is now generated from `.gitconfig.template` instead of being version controlled
  - Existing setup will require running `install.ps1` again to regenerate
  - Benefits: No hardcoded paths, complete portability across machines
- Updated `install.ps1` to generate config instead of creating symlink
- `.gitconfig` is no longer a symlink - it's a generated file in home directory
- Only `.gitignore_global` and `gitconfig_helper.py` are symlinked now

### Planned

- Additional git aliases for common workflows
- Support for GPG signing in addition to SSH
- Extended logging and diagnostics
- Configuration validation and health checks
