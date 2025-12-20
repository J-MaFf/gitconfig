# Dotfiles

Personal Git configuration and utilities for cross-machine synchronization.

**Current Version:** `v0.1.0-pre` | [Changelog](CHANGELOG.md)

## Contents

- **`.gitconfig.template`** - Template for generating machine-specific Git configuration
- **`.gitignore_global`** - Global gitignore patterns for IDEs, OS files, and development tools
- **`gitconfig_helper.py`** - Python utility for managing git aliases, branch cleanup, and main branch operations
- **`scripts/`** - PowerShell automation scripts
  - **`Setup-GitConfig.ps1`** - Unified setup wrapper script (creates symlinks, generates config, sets up scheduled task)
  - **`Initialize-GitConfig.ps1`** - Generates `.gitconfig` from template with machine-specific paths
  - **`Initialize-LocalConfig.ps1`** - Generates `.gitconfig.local` with SSH signing and safe directories
  - **`Initialize-Symlinks.ps1`** - Creates symbolic links for `.gitignore_global` and helper scripts
  - **`Update-GitConfig.ps1`** - Automated daily git pull script (runs at login)
  - **`Cleanup-GitConfig.ps1`** - Uninstall and reset utility
- **`docs/`** - Documentation and knowledge graph
  - **`knowledge-graph.jsonl`** - Entity and relation data for project documentation

## Features

### Git Aliases

- **`git alias`** - List all configured git aliases in a formatted table
- **`git branches`** - Download all remote branches and create local tracking branches
- **`git cleanup`** - Delete local branches that no longer have remote tracking
- **`git main`** - Switch to main branch with full error handling
  - Fetches updates from remote (with pruning)
  - Checks for uncommitted changes (prevents data loss)
  - Switches to main branch
  - Pulls latest changes (main is now fully updated)
  - Cleans up branches with deleted remotes (automatic merged branch cleanup)
  - Detects and reports merge conflicts

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

2. Run the unified setup script with administrator privileges:

   ```powershell
   cd ~/Documents/Scripts/gitconfig
   .\scripts\Setup-GitConfig.ps1 -Force
   ```

   This single command will:
   - Generate `~/.gitconfig` from the template with machine-specific paths
   - Create symlinks for `.gitignore_global` and `gitconfig_helper.py`
   - Generate `~/.gitconfig.local` with SSH signing configuration
   - Set up a scheduled task for automatic updates at login

3. Install the Python dependency:

   ```powershell
   python -m pip install rich
   ```

### Manual Setup

If you prefer to run setup steps individually:

```powershell
$repo = "$env:USERPROFILE\Documents\Scripts\gitconfig"

# Generate .gitconfig from template
.\scripts\Initialize-GitConfig.ps1 -Force

# Create symlinks
.\scripts\Initialize-Symlinks.ps1 -Force

# Generate machine-specific configuration
.\scripts\Initialize-LocalConfig.ps1 -Force
```

## Usage

### Setup Script Options

```powershell
# Unified setup (recommended) - runs all setup steps
.\scripts\Setup-GitConfig.ps1 -Force

# Without scheduled task creation
.\scripts\Setup-GitConfig.ps1 -Force -NoTask

# Generate .gitconfig from template
.\scripts\Initialize-GitConfig.ps1 -Force

# Initialize symlinks (requires admin privileges)
.\scripts\Initialize-Symlinks.ps1 -Force

# Initialize local machine-specific configuration
.\scripts\Initialize-LocalConfig.ps1 -Force

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
git main           # Switch to main with automatic updates
```

## Machine-Agnostic Setup

The configuration uses a **template-based generation** approach for maximum portability:

### Template Configuration (`.gitconfig.template`)

- Contains placeholders: `{{REPO_PATH}}` and `{{HOME_DIR}}`
- Version controlled for consistency across machines
- User information, aliases, and common settings

### Generated Configuration (`~/.gitconfig`)

- Generated from template by `Initialize-GitConfig.ps1`
- Placeholders replaced with machine-specific absolute paths
- NOT tracked in Git (excluded in `.gitignore`)
- Each machine generates its own version

### Machine-Specific Configuration (`~/.gitconfig.local`)

- SSH signing configuration and safe directories
- Created by `Initialize-LocalConfig.ps1`
- NOT tracked in Git (excluded in `.gitignore`)
- Each machine has its own version

This template-based approach ensures:

- ✅ No hardcoded paths in version control
- ✅ Complete portability across different machines and users
- ✅ Easy customization by editing the template
- ✅ Consistent configuration through version-controlled template

## Configuration Details

### Git Configuration Generation

The generated `~/.gitconfig` includes `~/.gitconfig.local` for machine-specific settings:

```gitconfig
[include]
    path = ~/.gitconfig.local
```

The template uses placeholders that are replaced during generation:

- `{{REPO_PATH}}` → Absolute path to the gitconfig repository
- `{{HOME_DIR}}` → User's home directory path

To regenerate after template changes:

```powershell
.\scripts\Initialize-GitConfig.ps1 -Force
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
