# Dotfiles

Personal Git configuration and utilities for cross-machine synchronization.

**Current Version:** `v0.1.0-pre` | [Changelog](CHANGELOG.md)

## Installation

### macOS

**Requirements:** macOS 12+, [Homebrew](https://brew.sh), Python 3

```bash
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
bash scripts/mac\ version/install.sh --force
```

*(Optional)* Enable SSH commit signing with 1Password:

```bash
brew install 1password-cli
bash scripts/mac\ version/install.sh --force
```

### Windows (PowerShell)

**Requirements:** PowerShell 5.1+, Administrator privileges, Python 3

```powershell
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
& ".\scripts\windows version\install.ps1" -Force
```

### Linux

**Requirements:** bash 4.0+, cron, Python 3

```bash
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
bash scripts/linux\ version/install.sh --force
```

The setup script handles generating `~/.gitconfig` from the template, creating symlinks, installing the `rich` Python dependency, and registering an auto-update job (launchd on macOS, Task Scheduler on Windows, cron on Linux).

The auto-update job is **pull + install**: at each login it pulls the latest commits and, if `.gitconfig.template` changed in that pull, regenerates `~/.gitconfig` so template changes take effect without a manual re-run. Your existing `~/.gitconfig` is backed up to `~/.gitconfig.bak` first, and `~/.gitconfig.local` is never modified. Run the same pull-and-install on demand any time with `git selfupdate`.

## Uninstall

Each platform has a cleanup script that removes symlinks, local config, and the auto-update job.

### macOS

```bash
bash scripts/mac\ version/cleanup-gitconfig.sh
```

Removes: `~/.gitconfig`, `~/.gitignore_global` symlink, `~/gitconfig_helper.py` symlink, `~/.gitconfig.local`, and the launchd login agent.

### Windows (PowerShell)

```powershell
& ".\scripts\windows version\Cleanup-GitConfig.ps1"
```

Removes: `~/.gitconfig`, symlinks, `~/.gitconfig.local`, and the `Update-GitConfig` scheduled task.

### Linux

```bash
bash scripts/linux\ version/cleanup-gitconfig.sh
```

Removes: `~/.gitconfig`, `~/.gitignore_global` symlink, `~/gitconfig_helper.py` symlink, `~/.gitconfig.local`, and the cron job.

## Usage

### Git Aliases

```bash
git alias          # Show all aliases
git branches       # Track all remote branches
git cleanup        # Clean up merged local branches
git main           # Switch to main with fetch, pull, and branch cleanup
git main --all     # Run the above for every git repo in immediate subdirectories (alias: -a)
git selfupdate     # Pull this repo and reinstall ~/.gitconfig from the template
git skill-sync           # Sync the claude-skills repo (~/.claude/skills) with pull --ff-only
git skill-publish        # Publish new/edited skills via a PR (prompts for a message, auto-merges)
```

### Setup Script Options (Windows)

```powershell
& ".\scripts\windows version\install.ps1" -Force           # Full setup
& ".\scripts\windows version\install.ps1" -Force -NoTask   # Skip scheduled task
& ".\scripts\windows version\Initialize-GitConfig.ps1" -Force      # Regenerate .gitconfig from template
& ".\scripts\windows version\Initialize-Symlinks.ps1" -Force       # Recreate symlinks
& ".\scripts\windows version\Initialize-LocalConfig.ps1" -Force    # Regenerate local config
```

## Contents

- **`.gitconfig.template`** - Template for generating machine-specific Git configuration
- **`.gitignore_global`** - Global gitignore patterns for IDEs, OS files, and build artifacts
- **`gitconfig_helper.py`** - Python utility for managing git aliases, branch cleanup, and main branch operations
- **`scripts/`** - Platform-specific setup and automation scripts

## Troubleshooting

**Symlink creation fails (Windows):** Run PowerShell as Administrator.

**Python dependency issues:**

```powershell
python -m pip install --upgrade pip
python -m pip install rich
```

**Aliases not working:** Verify the symlink exists and `.gitconfig` includes the helper path.

## License

Personal configuration repository.
