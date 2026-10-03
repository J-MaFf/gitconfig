# !/bin/bash

# README for Linux GitConfig Setup Scripts

# This directory contains Bash versions of the gitconfig setup scripts for Linux/Unix systems

## Overview

Since [#229](https://github.com/J-MaFf/gitconfig/issues/229), macOS and Linux share one implementation in `scripts/unix/` (`install.sh`, `cleanup-gitconfig.sh`, `initialize-local-config.sh`), which detects the OS; the per-OS pieces (cron vs launchd, credential helper, op-ssh-sign paths) live in `scripts/shared/platform.sh`. The scripts in this directory are thin wrappers kept so existing commands keep working: they run the `scripts/unix/` (or `scripts/shared/`) script for Linux and refuse to run on macOS. The commands below work from either directory.

The scripts are designed to work on:

- **Linux** (Ubuntu, Debian, Fedora, CentOS, Arch, etc.)
- **macOS**
- **Other Unix-like systems** (FreeBSD, etc.)

## Files

### Main Scripts

- **install.sh** - Main setup wrapper orchestrates complete installation
  - With `--reinstall` only: tears down the previous installation first
  - Generates .gitconfig from template
  - Creates symlinks (links that already point into the repo are left alone)
  - Generates .gitconfig.local (which also sets the global gitignore)
  - Sets up cron job (optional)
  - Verifies complete setup

- **cleanup-gitconfig.sh** - Removes all gitconfig-related files and cron jobs
  - Backs up removed files (timestamped `*.bak.YYYYMMDD-HHMMSS`); symlinks
    into the repo are just removed
  - Useful for testing fresh setup

### Helper Scripts

- **initialize-gitconfig.sh** - Generates .gitconfig from template
  - Handles placeholder substitution
  - Creates a timestamped backup of the existing config, and warns (key names
    only) about settings the template would drop
  - Verifies git can read the generated config

- **initialize-local-config.sh** - Creates machine-specific .gitconfig.local
  - Sets up safe directories
  - Configures gitignore path
  - Configures SSH commit signing, in this order (the same as macOS): an
    on-disk key (`~/.ssh/claude_desktop`, then `~/.ssh/id_ed25519_signing`,
    each with its `.pub`, plus the optional `~/.ssh/git-sign-no-agent`
    wrapper); else 1Password's `/opt/1Password/op-ssh-sign`; else, when git
    already has a `user.signingkey`, just `allowedSignersFile` so signatures
    verify
  - Configures an HTTPS credential helper: the GitHub CLI (`gh auth git-credential`)
    when installed — so unattended HTTPS git (cron pulls, `bd dolt push`)
    authenticates without prompting — falling back to the desktop keyring
    (libsecret) where available (needs an unlocked keyring, so interactive
    sessions rather than headless ones)
  - Linux-friendly paths (no Windows-specific settings)
  - Refuses to run on macOS (use the mac version) — a mislabeled
    .gitconfig.local is how osxkeychain ended up on a Linux server (#179)

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
./install.sh
```

### Options

**install.sh**

```bash
./install.sh                # Interactive mode
./install.sh --force        # Overwrite without prompting
./install.sh --no-cron      # Skip cron job setup (same as --no-scheduler)
./install.sh --help         # Show help
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
./update-gitconfig.sh                            # Update the repo this script lives in
./update-gitconfig.sh /path/to/gitconfig        # Update from specific location
```

## Setup Process

### Step-by-Step

1. **Execution** - Make scripts executable

   ```bash
   chmod +x install.sh cleanup-gitconfig.sh
   ```

2. **Run Setup** - Execute main setup script

   ```bash
   ./install.sh
   ```

3. **Verify** - Check that symlinks and config are in place

   ```bash
   git config --list | head -20
   ```

4. **Optional: Manual Cron Setup** - If the automatic cron setup didn't work

   ```bash
   crontab -e
   # Add: 0 9 * * * bash "/path/to/gitconfig/scripts/shared/update-gitconfig.sh" "/path/to/gitconfig" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate
   ```

### Reverse Setup

To undo the installation:

```bash
./cleanup-gitconfig.sh --force
```

Files are backed up to `~/<file>.bak.YYYYMMDD-HHMMSS` before removal (symlinks that point into the repo are just removed). To tear down and set up again in one go, run `./install.sh --reinstall`.

## What Gets Installed

### Symlinks Created

- `~/.gitignore_global` → `<repo>/.gitignore_global`
- `~/gitconfig_helper.py` → `<repo>/gitconfig_helper.py`

### Files Generated

- `~/.gitconfig` - Main git configuration (from template)
- `~/.gitconfig.local` - Machine-specific local configuration

### Git Configuration

- Global gitignore configured via `core.excludesfile` in `~/.gitconfig.local`
- Put your own settings in `~/.gitconfig.local`; `~/.gitconfig` is regenerated from the template
- Safe directories configured for trusted repos

### Automation (Optional)

- Cron job set for daily updates at 9 AM, tagged `# gitconfig-autoupdate`
  so cleanup (and a re-install) can find and replace exactly that line;
  untagged lines from older installs that run `update-gitconfig.sh` are
  replaced or removed too
- Can be customized or disabled with `--no-cron`

## Differences from Windows Version

| Feature | Windows | Linux |
|---------|---------|-------|
| Admin Required | Yes | No |
| Symlinks | Windows symlinks | Unix symlinks |
| Scheduled Tasks | Windows Task Scheduler | cron |
| Paths | `C:\Users\...` | `/home/...` |
| Line Endings | CRLF | LF |
| SSH Signing | op-ssh-sign.exe | On-disk SSH key, or op-ssh-sign |
| Safe Directories | Network UNC paths | Unix mount paths |

## Troubleshooting

### Symlink Creation Failed

- Ensure you're not in a read-only filesystem
- Try with `--force` flag
- Check file permissions

### Cron Job Not Working

- `install.sh` skips the cron step with a `[WARN]` when `crontab` isn't installed (e.g. `sudo apt-get install cron`, then re-run)
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

Edit `cron_entry` in `scripts/shared/platform.sh` before running (keep the
trailing `# gitconfig-autoupdate` marker so cleanup can find the line), or
change the schedule afterwards with `crontab -e`:

```bash
# Change the schedule in this line:
printf '0 9 * * * bash "%s" "%s" >> /tmp/gitconfig-update.log 2>&1 %s\n' \
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
./install.sh --force

# Verify
git config --list

# Clean up
./cleanup-gitconfig.sh --force
```

## Notes

- The setup scripts use no bash 4-only features and run under bash 3.2+; only the optional Ctrl-G alias widget for bash needs bash 4.0+ (`READLINE_LINE`)
- Scripts preserve existing files by backing them up as `<file>.bak.YYYYMMDD-HHMMSS`; the newest 5 per file are kept (`GITCONFIG_BACKUP_KEEP` changes this, `0` keeps all)
- No root/sudo required unless dealing with system-wide git config
- Cron job logs to `/tmp/gitconfig-update.log`
- Windows-specific paths and settings are excluded

## Support

For issues:

1. Run setup with `--help` for available options
2. Check the logs in `/tmp/gitconfig-update.log`
3. Test manually: `bash update-gitconfig.sh`
4. Review symlink status: `ls -la ~/.gitconfig*`
