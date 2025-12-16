# Dotfiles

Personal Git configuration and utilities for cross-machine synchronization.

**Current Version:** `v0.1.0-pre` | [Changelog](CHANGELOG.md)

## Contents

- **`.gitconfig`** - Git configuration with custom aliases and SSH signing setup
- **`.gitignore_global`** - Global gitignore patterns for IDEs, OS files, and development tools
- **`.gitconfig_helper.py`** - Python utility for managing git aliases and branch cleanup
- **`scripts/`** - PowerShell automation scripts
  - **`Initialize-Symlinks.ps1`** - Setup script for creating symlinks on Windows
  - **`pull-daily.ps1`** - Automated daily git pull script
- **`docs/`** - Documentation and knowledge graph
  - **`knowledge-graph.jsonl`** - Entity and relation data for project documentation

## Features

### Git Aliases

- **`git alias`** - List all configured git aliases in a formatted table
- **`git branches`** - Download all remote branches and create local tracking branches
- **`git cleanup`** - Delete local branches that no longer have remote tracking

### Git Configuration

- SSH-based commit signing with OpenSSH key format
- Auto-setup remote tracking for pushed branches
- Custom editor (VS Code with `--wait` flag)
- Safe directories configured for shared network locations

## Requirements

- **Python 3.7+** (for gitconfig_helper.py)
- **rich** library: Install with `python -m pip install rich`
- **PowerShell 5.1+** (for setup script)
- **Administrator privileges** (recommended for creating symlinks on Windows)

## Installation

### Quick Setup (Windows PowerShell)

1. Clone this repository:

   ```powershell
   git clone https://github.com/J-MaFf/gitconfig.git ~/Documents/Scripts/gitconfig
   ```

2. Run the setup script from the scripts directory with administrator privileges:

   ```powershell
   cd ~/Documents/Scripts/gitconfig
   .\scripts\Initialize-Symlinks.ps1
   ```

3. Initialize machine-specific configuration:

   ```powershell
   .\scripts\Initialize-LocalConfig.ps1
   ```

   This creates `~/.gitconfig.local` with safe directories and paths specific to your machine.

4. Install the Python dependency:

   ```powershell
   python -m pip install rich
   ```

### Manual Setup

If you prefer to set up symlinks manually:

```powershell
$repo = "$env:USERPROFILE\Documents\Scripts\gitconfig"
$home = $env:USERPROFILE

New-Item -ItemType SymbolicLink -Path "$home\.gitconfig" -Target "$repo\.gitconfig" -Force
New-Item -ItemType SymbolicLink -Path "$home\.gitignore_global" -Target "$repo\.gitignore_global" -Force
New-Item -ItemType SymbolicLink -Path "$home\.gitconfig_helper.py" -Target "$repo\gitconfig_helper.py" -Force
```

## Usage

### Setup Script Options

```powershell
# Initialize symlinks (requires admin privileges)
.\scripts\Initialize-Symlinks.ps1

# Initialize local machine-specific configuration
.\scripts\Initialize-LocalConfig.ps1

# Display help for any script
.\scripts\Initialize-Symlinks.ps1 -Help
.\scripts\Initialize-LocalConfig.ps1 -Help
```

### Using Git Aliases

After installation, use the configured aliases:

```bash
git alias          # Show all aliases
git branches       # Track all remote branches
git cleanup        # Clean up local branches
```

## Machine-Agnostic Setup

The configuration uses a two-file approach for cross-machine portability:

### Shared Configuration (`.gitconfig`)

- User information, aliases, and common settings
- Tracked in Git for consistency across machines

### Machine-Specific Configuration (`.gitconfig.local`)

- Safe directories and local paths
- Created by `Initialize-LocalConfig.ps1`
- NOT tracked in Git (excluded in `.gitignore`)
- Each machine has its own version

This allows you to clone the repository to different machines and have each one automatically configure itself for local paths without modification.

## Configuration Details

### Git Include Pattern

The `.gitconfig` includes `~/.gitconfig.local` for machine-specific settings:

```gitconfig
[include]
    path = ~/.gitconfig.local
```

This is a Git best practice for handling environment-specific configurations.

### Global Gitignore

The `.gitignore_global` file is symlinked to `~/.gitignore_global` and automatically configured in `.gitconfig.local`. It contains patterns for:

- **IDE and Editor Files** - VS Code, JetBrains, Sublime, Vim, Emacs, Atom
- **OS-Specific Files** - macOS (.DS_Store), Windows (Thumbs.db), Linux (.directory)
- **Language-Specific Artifacts**:
  - Python: `__pycache__`, `*.pyc`, `.venv`, `venv/`
  - Node.js: `node_modules/`, `npm-debug.log`
  - Go, Java, Ruby, C/C++, and more
- **Build Outputs** - `build/`, `dist/`, `target/`, compiled objects
- **Local Configuration Files** - `.env`, `.secrets`, credentials, private keys
- **Temporary Files** - `.tmp`, `.cache`, `.bak`, swap files

These patterns prevent common development artifacts from being accidentally committed to repositories.

### SSH Signing

The `.gitconfig` is configured for SSH-based commit signing using:

- OpenSSH key format (ed25519)
- 1Password SSH agent (`op-ssh-sign.exe`)
- Auto-signing on all commits

Update the `signingkey` and `gpg.ssh.program` values if using a different key or agent.

### Safe Directories

Network locations and local directories are configured as safe git directories to avoid permission issues:

- `\\10.210.3.10\dept\IT\PC Setup\winget-app-setup`
- `C:\Users\<username>\Documents\Scripts\winget-app-setup`
- `C:\Users\<username>\Documents\Scripts\winget-install`
- `\\10.210.3.10\dept\IT\Programs\Office\OfficeConfigs`
- `\\KFWS9BDC01\DEPT\IT\Programs\Office\OfficeConfigs`

Modify these paths as needed for your environment.

## Troubleshooting

### Symlink Creation Fails

- **Windows 10/11**: Run PowerShell as Administrator
- **Older Windows**: You may need to enable developer mode or use `mklink` command

### Python Dependencies Not Installing

```powershell
python -m pip install --upgrade pip
python -m pip install rich
```

### Git Aliases Not Working

Verify the symlink is created:

```powershell
ls $PROFILE  # Should show .gitconfig symlink
```

Test the alias:

```bash
git alias
```

## Updates and Syncing

To pull the latest configuration changes:

```powershell
cd ~/.dotfiles
git pull
```

Changes are immediately reflected in `~/.gitconfig` and `~/.gitconfig_helper.py` through symlinks.

## Versioning

This project follows [Semantic Versioning (semver.org)](https://semver.org/).

- **Format:** `vMAJOR.MINOR.PATCH[-PRERELEASE]`
- **Current Status:** Pre-release (`v0.1.0-pre`)
- **See [CHANGELOG.md](CHANGELOG.md) for detailed version history and changes**

### Version Progression

The project is in initial development (0.x.y pre-release phase). Versions will progress as:

- `v0.1.0-alpha` → `v0.1.0-beta` → `v0.1.0-rc.1` → `v0.1.0` (stable)

Once stable `v1.0.0` is released, semantic versioning will strictly follow:

- **MAJOR** - Breaking changes
- **MINOR** - New backward-compatible features
- **PATCH** - Bug fixes

## License

Personal configuration repository.
