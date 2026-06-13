# Dotfiles

Personal Git configuration and utilities for cross-machine synchronization.

**Current Version:** `v0.1.0-pre` | [Changelog](CHANGELOG.md)

## Installation

### macOS

**Requirements:** macOS 12+, [Homebrew](https://brew.sh), Python 3

```bash
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
bash scripts/mac\ version/setup-gitconfig.sh --force
pip3 install rich
```

*(Optional)* Enable SSH commit signing with 1Password:

```bash
brew install 1password-cli
bash scripts/mac\ version/setup-gitconfig.sh --force
```

### Windows (PowerShell)

**Requirements:** PowerShell 5.1+, Administrator privileges

```powershell
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
.\scripts\install.ps1 -Force
python -m pip install rich
```

### Linux

**Requirements:** bash 4.0+, cron, Python 3

```bash
git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
cd ~/Documents/Scripts/gitconfig
bash scripts/linux\ version/setup-gitconfig.sh --force
pip install rich
```

The setup script handles generating `~/.gitconfig` from the template, creating symlinks, and registering an auto-update job (launchd on macOS, Task Scheduler on Windows, cron on Linux).

## Usage

### Git Aliases

```bash
git alias          # Show all aliases
git branches       # Track all remote branches
git cleanup        # Clean up merged local branches
git main           # Switch to main with fetch, pull, and branch cleanup
```

### Setup Script Options (Windows)

```powershell
.\scripts\install.ps1 -Force           # Full setup
.\scripts\install.ps1 -Force -NoTask   # Skip scheduled task
.\scripts\Initialize-GitConfig.ps1 -Force      # Regenerate .gitconfig from template
.\scripts\Initialize-Symlinks.ps1 -Force       # Recreate symlinks
.\scripts\Initialize-LocalConfig.ps1 -Force    # Regenerate local config
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
