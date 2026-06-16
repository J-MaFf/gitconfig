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

The auto-update job is **pull + install + prune**: at each login it pulls the latest commits and, if `.gitconfig.template` changed in that pull, regenerates `~/.gitconfig` so template changes take effect without a manual re-run. It also prunes merged branches in the gitconfig repo — dropping stale remote-tracking refs (`fetch --prune`) and deleting local branches whose remote has been deleted — so old feature branches don't pile up. It also ensures the optional `textual` dependency (which powers the interactive `git alias` browser) is installed — best-effort and only when missing, so existing machines pick it up on their next update without a manual `pip install`. Your existing `~/.gitconfig` is backed up to `~/.gitconfig.bak` first, and `~/.gitconfig.local` is never modified. Run the same pull-install-prune on demand any time with `git selfupdate`.

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

`git alias` opens an **interactive, categorized browser**: clickable/arrow-key tabs
per category, a search box that filters by alias name **or** description, and a result
table you move through with **up/down**. Press **Enter** (or click a row) to pick an
alias. It needs a terminal and the optional `textual` package; when piped, in scripts,
or without `textual` it falls back to a static grouped table. Force the static table
with `git alias --plain`.

```bash
git alias          # Browse all aliases (interactive in a terminal)
git alias --plain  # Static grouped table (good for piping: git alias --plain | grep pr)
```

In the browser: type to search, up/down to move, Enter/click to select, Ctrl+Left/Right
to switch category, Esc to clear the search (or quit), Ctrl+C to quit.

**Insert an alias at your prompt — `Ctrl-G`**

The installer adds a `Ctrl-G` keybinding to your shell (bash/zsh) and PowerShell profile.
Press `Ctrl-G` at the prompt to open the browser; the alias you pick is typed onto your
command line, ready to run or edit. A program launched by `git alias` can't type at your
prompt itself, so this keybinding does the insertion — like fzf's `Ctrl-T`. Enable it
manually by sourcing the matching widget:

```bash
# bash (~/.bashrc) or zsh (~/.zshrc)
source /path/to/gitconfig/scripts/shell/git-alias-widget.bash   # or .zsh
```

```powershell
# PowerShell ($PROFILE)
. "C:\path\to\gitconfig\scripts\shell\git-alias-widget.ps1"
```

**Inspect**

```bash
git s              # Short, branch-aware status (status -sb)
git lg             # Pretty, decorated commit graph across all branches
git last           # Show the most recent commit with its diffstat
git recent         # Local branches ordered by most recent commit
git find <string>  # Commits that added or removed <string> (log -S)
```

**Commit**

```bash
git amend          # Fold staged changes into the last commit, keep its message
git reword         # Edit the last commit's message
git undo           # Undo the last commit but keep its changes staged
git unstage <path> # Unstage files while keeping working-tree changes
git wip            # Park all current work as a WIP commit (skips hooks)
```

**Branch & Sync**

```bash
git nb <name>      # Create and switch to a new branch (switch -c)
git pushf          # Force-push the current branch safely (--force-with-lease)
git sync           # Update the current branch with rebase + autostash
git start <issue#> # Make a conventionally named branch from a GitHub issue's title
git branches       # Track all remote branches
git cleanup        # Clean up merged local branches
git main           # Switch to main with fetch, pull, and branch cleanup
git main --all     # Run the above for every git repo in immediate subdirectories (alias: -a)
```

**GitHub**

```bash
git pr             # Open the current branch's pull request in the browser
git prs            # Show the status of your pull requests
```

**Maintenance**

```bash
git localconfig          # Edit machine-specific git config (~/.gitconfig.local)
git selfupdate           # Pull this repo and reinstall ~/.gitconfig from the template
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
python -m pip install rich textual
```

`rich` is required; `textual` is optional and only powers the interactive
`git alias` browser. Without it, `git alias` shows the static grouped table.

**`git alias` shows a static table instead of the interactive browser:** install
`textual` (`pip install textual`) and run `git alias` directly in a terminal —
the interactive UI is skipped when output is piped/redirected or when stdout is
not a TTY.

**Aliases not working:** Verify the symlink exists and `.gitconfig` includes the helper path.

**`git log --show-signature` says "No signature" on a signed commit:** Install writes a
`~/.ssh/allowed_signers` entry for your signing key and points
`gpg.ssh.allowedSignersFile` at it (in `~/.gitconfig.local`) so git can verify SSH
signatures locally. If you signed before this was set up, re-run install (or
`git selfupdate`) to regenerate it. GitHub verifies signatures independently, so commits
show as Verified there regardless.

## License

Personal configuration repository.
