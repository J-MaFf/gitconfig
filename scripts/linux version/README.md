# !/bin/bash

# README for Linux GitConfig Setup Scripts

# This directory contains Bash versions of the gitconfig setup scripts for Linux/Unix systems

## Overview

This directory provides a complete Linux/Unix version of the gitconfig setup system. All scripts are designed to work on:

- **Linux** (Ubuntu, Debian, Fedora, CentOS, Arch, etc.)
- **macOS**
- **Other Unix-like systems** (FreeBSD, etc.)

## Files

### Main Scripts

- **setup-gitconfig.sh** - Main setup wrapper orchestrates complete installation
  - Cleans previous installation
  - Generates .gitconfig from template
  - Creates symlinks
  - Generates .gitconfig.local
  - Configures global gitignore
  - Sets up cron job (optional)
  - Verifies complete setup

- **cleanup-gitconfig.sh** - Removes all gitconfig-related files and cron jobs
  - Backs up all removed files
  - Useful for testing fresh setup

### Helper Scripts

- **initialize-gitconfig.sh** - Generates .gitconfig from template
  - Handles placeholder substitution
  - Creates backups of existing config
  - Verifies git can read the generated config

- **initialize-local-config.sh** - Creates machine-specific .gitconfig.local
  - Sets up safe directories
  - Configures gitignore path
  - Linux-friendly paths (no Windows-specific settings)

- **update-gitconfig.sh** - Runs git pull on the repository
  - Logs all operations with timestamps
  - Can be run manually or via cron
  - Synchronizes remote tracking branches
  - Maintains safe error handling

## Usage

### Quick Start

Make all scripts executable:

```bash
chmod +x *.sh
```

Run the main setup script:

```bash
./setup-gitconfig.sh
```

### Options

**setup-gitconfig.sh**

```bash
./setup-gitconfig.sh                # Interactive mode
./setup-gitconfig.sh --force        # Overwrite without prompting
./setup-gitconfig.sh --no-cron      # Skip cron job setup
./setup-gitconfig.sh --help         # Show help
```

**cleanup-gitconfig.sh**

```bash
./cleanup-gitconfig.sh              # Interactive cleanup
./cleanup-gitconfig.sh --force      # Clean without prompting
./cleanup-gitconfig.sh --help       # Show help
```

**initialize-gitconfig.sh**

```bash
./initialize-gitconfig.sh           # Interactive mode
./initialize-gitconfig.sh --force   # Overwrite without prompting
./initialize-gitconfig.sh --help    # Show help
```

**initialize-local-config.sh**

```bash
./initialize-local-config.sh        # Interactive mode
./initialize-local-config.sh --force # Overwrite without prompting
./initialize-local-config.sh --help  # Show help
```

**update-gitconfig.sh**

```bash
./update-gitconfig.sh                            # Update from default location
./update-gitconfig.sh /path/to/gitconfig        # Update from specific location
```

## Setup Process

### Step-by-Step

1. **Execution** - Make scripts executable

   ```bash
   chmod +x setup-gitconfig.sh cleanup-gitconfig.sh
   ```

2. **Run Setup** - Execute main setup script

   ```bash
   ./setup-gitconfig.sh
   ```

3. **Verify** - Check that symlinks and config are in place

   ```bash
   git config --list | head -20
   ```

4. **Optional: Manual Cron Setup** - If the automatic cron setup didn't work

   ```bash
   crontab -e
   # Add: 0 9 * * * /path/to/update-gitconfig.sh >> /tmp/gitconfig-update.log 2>&1
   ```

### Reverse Setup

To undo the installation:

```bash
./cleanup-gitconfig.sh --force
```

All files are backed up to `~/*.bak` before removal.

## What Gets Installed

### Symlinks Created

- `~/.gitignore_global` → `<repo>/.gitignore_global`
- `~/gitconfig_helper.py` → `<repo>/gitconfig_helper.py`

### Files Generated

- `~/.gitconfig` - Main git configuration (from template)
- `~/.gitconfig.local` - Machine-specific local configuration

### Git Configuration

- Global gitignore configured via `core.excludesfile`
- Safe directories configured for trusted repos

### Automation (Optional)

- Cron job set for daily updates at 9 AM
- Can be customized or disabled with `--no-cron`

## Differences from Windows Version

| Feature | Windows | Linux |
|---------|---------|-------|
| Admin Required | Yes | No |
| Symlinks | Windows symlinks | Unix symlinks |
| Scheduled Tasks | Windows Task Scheduler | cron |
| Paths | `C:\Users\...` | `/home/...` |
| Line Endings | CRLF | LF |
| SSH Signing | op-ssh-sign.exe | Native SSH key |
| Safe Directories | Network UNC paths | Unix mount paths |

## Troubleshooting

### Symlink Creation Failed

- Ensure you're not in a read-only filesystem
- Try with `--force` flag
- Check file permissions

### Cron Job Not Working

- Verify cron daemon is running: `systemctl status cron`
- Check cron log: `grep CRON /var/log/syslog` (Debian/Ubuntu)
- Manually test: `bash update-gitconfig.sh`

### Git Config Not Found

- Verify symlinks: `ls -la ~/.gitconfig*`
- Check permissions: `git config --list`
- Regenerate: `./initialize-gitconfig.sh --force`

### Log File Issues

- Ensure log directory exists: `mkdir -p ~/.gitconfig-logs`
- Check write permissions

## Advanced Usage

### Custom Cron Schedule

Edit the cron entry in `setup-gitconfig.sh` before running:

```bash
# Change this line:
CRON_ENTRY="0 9 * * * bash \"$CRON_SCRIPT\" >> /tmp/gitconfig-update.log 2>&1"
```

Common cron schedules:

- `0 8 * * *` - Daily at 8 AM
- `0 */6 * * *` - Every 6 hours
- `0 0 * * 0` - Weekly on Sunday at midnight
- `0 9 * * 1-5` - Weekdays at 9 AM

### Custom Local Config

Edit `~/.gitconfig.local` to add safe directories:

```ini
[safe]
    directory = /path/to/trusted/repo1
    directory = /path/to/trusted/repo2
```

### Testing

To test the setup without making permanent changes:

```bash
# Setup in test mode
./setup-gitconfig.sh --force

# Verify
git config --list

# Clean up
./cleanup-gitconfig.sh --force
```

## Notes

- All scripts use bash 4.0+ features (associative arrays for consistency)
- Scripts preserve existing files by backing them up with `.bak` extension
- No root/sudo required unless dealing with system-wide git config
- Cron job logs to `/tmp/gitconfig-update.log`
- Windows-specific paths and settings are excluded

## Support

For issues:

1. Run setup with `--help` for available options
2. Check the logs in `/tmp/gitconfig-update.log`
3. Test manually: `bash update-gitconfig.sh`
4. Review symlink status: `ls -la ~/.gitconfig*`
