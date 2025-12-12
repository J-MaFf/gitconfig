# Dotfiles

Personal Git configuration and utilities for cross-machine synchronization.

## Contents

- **`.gitconfig`** - Git configuration with custom aliases and SSH signing setup
- **`.gitconfig_helper.py`** - Python utility for managing git aliases and branch cleanup
- **`Initialize-Symlinks.ps1`** - PowerShell script for setting up symlinks on Windows

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
   git clone https://github.com/J-MaFf/dotfiles.git ~/.dotfiles
   ```

2. Run the setup script with administrator privileges:

   ```powershell
   cd ~/.dotfiles
   .\setup-symlinks.ps1
   ```

3. Install the Python dependency:

   ```powershell
   python -m pip install rich
   ```

### Manual Setup

If you prefer to set up symlinks manually:

```powershell
$repo = "$env:USERPROFILE\.dotfiles"
$home = $env:USERPROFILE

New-Item -ItemType SymbolicLink -Path "$home\.gitconfig" -Target "$repo\.gitconfig" -Force
New-Item -ItemType SymbolicLink -Path "$home\.gitconfig_helper.py" -Target "$repo\.gitconfig_helper.py" -Force
```

## Usage

### Setup Script Options

```powershell
# Interactive mode (prompts before overwriting)
.\Initialize-Symlinks.ps1

# Force mode (overwrites without prompting)
.\Initialize-Symlinks.ps1 -Force

# Display help
.\Initialize-Symlinks.ps1 -Help
```

### Using Git Aliases

After installation, use the configured aliases:

```bash
git alias          # Show all aliases
git branches       # Track all remote branches
git cleanup        # Clean up local branches
```

## Machine-Agnostic Setup

The configuration uses environment variables to work across machines:

- `${USERPROFILE}` - Home directory path (Windows)
- Paths are relative to the home directory

This means you can clone the repository to different machines and symlink without modification.

## Configuration Details

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

## License

Personal configuration repository.
