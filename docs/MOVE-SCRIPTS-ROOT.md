# Moving the Scripts root out of Documents

The Scripts root is the folder that holds every clone, this repo's included. It
used to be `~/Documents/Scripts`; it is now `~/dev/repos` on every OS
(`$HOME\dev\repos` on Windows), so all development material lives under `~/dev`
and the folder holding every git clone is `~/dev/repos` (lowercase, since Linux
paths are case-sensitive). This runbook moves an existing machine over with the
migration tool ([#304](https://github.com/J-MaFf/gitconfig/issues/304),
[#311](https://github.com/J-MaFf/gitconfig/issues/311)), whose default target
is `~/dev/repos`:

- Windows: `scripts/windows version/Move-ScriptsRoot.ps1` (PowerShell 7 or
  Windows PowerShell 5.1)
- macOS and Linux: `scripts/unix/move-scripts-root.sh` (bash, including the
  stock macOS `/bin/bash` 3.2)

Both do the same thing in the same order. They print the whole plan and ask
once before changing anything, move the folder with **one rename** (never a
copy), then re-point everything on the machine that used the old path. They
leave **no link, junction or alias at the old path**. Every file they change is
first copied to `~/.scripts-move-<yyyyMMdd-HHmmss>/backup/`, and they end with
a report in that folder, `report.txt`.

The rename needs the target's parent folder to exist, and `~/dev` usually
doesn't yet. After you confirm the plan, the tool creates the missing folders
above the target just before the rename (the plan lists each one as
`create <folder>`). A dry run creates nothing. If the rename fails, the tool
removes the folders it just created (only while they are still empty), so a
failed run leaves the machine as it was. The same-volume check looks at the
nearest folder above the target that already exists.

## Why

Google Drive for desktop backs up `~/Documents` on Windows, and every repo's
`.git` folder with it. When a sync conflicts, Drive saves copies such as
`.git/refs/heads/main (1)`. That is not a valid ref name, so every `git fetch`
and `git pull` in the repo then fails:

```text
fatal: bad object refs/heads/main (1) ... did not send all necessary objects
```

Drive for desktop can't exclude one subfolder of a folder it backs up, so the
repos have to live outside `~/Documents`. The same layout is used on every
machine, Windows, macOS and Linux alike, so paths stay the same everywhere.

A link from the old path to the new one would bring the repos straight back
into the backup, so the tool updates every reference instead.

What the tool repairs after the move:

| What | Where |
| --- | --- |
| Linked git worktrees | `git worktree repair` for every repo (up to 3 levels down) that has worktrees, inside the root or beside it |
| This repo's generated files | `~/.gitconfig`, the `~/.gitignore_global` and `~/gitconfig_helper.py` links, the auto-sync job (the "GitConfig Pull at Login" task; the cron line, systemd timer or launchd agent) and the Ctrl-G block in your PowerShell profile or shell rc file, all re-run from the moved clone |
| Symlinks and junctions | `~`, `~/.claude`, `~/.local/bin`, `~/bin` (one level) and `~/.config` (two levels); each keeps its kind |
| Paths in config files | PowerShell profiles, `~/.gitconfig.local`, `~/.config/gitconfig/safe-directories`, shell rc files, `~/.claude/settings.json`, `~/.claude/scheduled-tasks/*/SKILL.md`, `~/.vscode/workspaces/*.code-workspace`, `.mcp.json` files under `~/.vscode/agent-plugins/`. Every spelling of the old root is rewritten in the same form: backslashes, forward slashes, JSON's `\\`, `$HOME`/`~`/`$env:USERPROFILE`/`%USERPROFILE%`, and relative paths in workspace files. Encoding, BOM and line endings are kept byte for byte |
| Scheduled jobs | Windows: your own scheduled tasks, user environment variables (PATH included) and `.lnk` shortcuts on the Desktop and in the Start Menu. macOS/Linux: the user crontab, systemd user units (active ones restarted) and launchd agents (reloaded) |
| Claude Code project folders | The folders under `~/.claude/projects/` named after a path in the old root are renamed, so session history and memory follow the move |

What it only reports, without changing: Python venvs (they embed their path
and must be recreated), system-scope jobs (SYSTEM or other accounts' tasks,
`/etc/systemd/system`, `/Library/LaunchDaemons`, root's crontab), machine-scope
environment variables, and app state that mentions the old root
(`~/.claude.json`, the Claude desktop app's settings, VS Code's global storage).
It never edits files inside a repo: a dotfile that is a link into a repo has
its link re-pointed, and the file itself is listed in the report. Other repos'
hard-coded paths are for you to fix in those repos.

## Before you start

1. **Pull every repo**, so nothing is half-synced when the paths change:

   ```sh
   git main --all
   ```

   Commit or stash any work in progress first. `git main --all` reports a repo
   it couldn't fast-forward; deal with it before you move.

2. **Close everything that works under the old root**: editors and IDEs
   (VS Code, with its terminals), Claude Code (the CLI and the desktop app),
   file explorer windows, and every terminal whose current folder is inside
   `~/Documents/Scripts`. On Windows an open file or a shell's current folder
   anywhere under the root makes the rename fail; nothing is changed then, but
   you have to close it and start again.

3. **Pause Google Drive** (on Windows, the Drive icon in the taskbar; on macOS,
   in the menu bar; then Settings > Pause syncing), so it doesn't sync the
   folder while it moves. The tool checks for a running Drive and asks you to
   confirm it is paused.

4. **Start from your home folder**, in a new terminal: `cd ~`.

## Windows

Open PowerShell **as administrator, with your own account** (right-click
PowerShell or Windows Terminal > Run as administrator). Re-creating symbolic
links needs it (unless Developer Mode is on), and so does replacing the login
task an elevated install registered. Elevating with another account's password
would make the tool see that account's home folder: don't.

First a dry run. It prints the plan and changes nothing:

```powershell
Set-Location $HOME
& "$HOME\Documents\Scripts\gitconfig\scripts\windows version\Move-ScriptsRoot.ps1" -DryRun
```

Read the plan. Each section lists what will change: the move itself (with any
folder it creates above the target, such as `~/dev`), repos and
worktrees, this repo's generators, files with their match counts, links,
scheduled tasks, environment variables, shortcuts, Claude project folders, and
what is only reported. Then the real run:

```powershell
& "$HOME\Documents\Scripts\gitconfig\scripts\windows version\Move-ScriptsRoot.ps1"
```

It asks once (`y` to go ahead); `-Yes` answers for you. It exits 0 when
everything is done, 1 when a preflight check stopped it (nothing changed) or a
repair failed, and 2 when you said no. When it finishes it prints the report.
Sign out and back in afterwards, so Explorer and the login task pick up the
new environment and paths.

## macOS / Linux

In a new terminal, from your home folder. First the dry run, which prints the
plan and changes nothing:

```sh
cd ~
bash ~/Documents/Scripts/gitconfig/scripts/unix/move-scripts-root.sh --dry-run
```

Read the plan, then the real run:

```sh
bash ~/Documents/Scripts/gitconfig/scripts/unix/move-scripts-root.sh
```

It asks once (`y` to go ahead); `--yes` answers for you. Exit codes are the
same as on Windows: 0 done, 1 stopped or a repair failed, 2 declined (or no
input to read, as in a script without `--yes`). On macOS, quit any app that has
the folder open; Drive's process is checked like on Windows. Open a new
terminal afterwards so your shell rc changes take effect.

## After the move

- **Read the report** (`~/.scripts-move-<timestamp>/report.txt`, also printed
  at the end). Section (a) lists every change, (b) failures, (c) references to
  the old root still left in the places the tool repairs, and (d) what it only
  reports. (b) and (c) are failures; the exit code is 1 while there are any.
- **Recreate the venvs** listed under (d). A venv embeds its own absolute path,
  so after a move its scripts point at the old location:

  ```sh
  cd ~/dev/repos/<repo>
  rm -rf .venv
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt   # or whatever the repo installs from
  ```

  On Windows use `py -m venv .venv` and `.venv\Scripts\pip`.
- **Re-approve Claude Code's folder permissions.** Claude Code remembers which
  folders you trusted by path, so the first time you open a project under
  `~/dev/repos` it asks again. The project folders under `~/.claude/projects/`
  were renamed, so your history and memory are still there.
- **Fix what the report lists under (d)** that you rely on: a system-scope task
  or job (edit it as administrator or with `sudo`), a machine-scope `PATH`
  entry, or a path in the Claude desktop app's or VS Code's settings (change it
  in the app). Hard-coded paths in other repos are fixed in those repos.
- **What Google Drive does with its copy of the old folder.** Drive does not
  follow the move. It sees the folder disappear from Documents and treats it as
  removed from the backup: depending on your Drive settings it moves the
  backed-up copy (under Computers on drive.google.com) to Drive's trash, where
  it is kept for 30 days, or asks you first. It never puts the folder back on
  your disk. Once you have checked the move, you can delete the old copy from
  Drive. Don't download it back into Documents. Resume Drive syncing when the
  tool is done.

## Rollback

To move back, run the tool again with `--from`/`--to` (`-From`/`-To`)
swapped. `--allow-synced-target` (`-AllowSyncedTarget`) is needed because the
destination is inside Documents again. It repairs everything the same way, in
the other direction. The `~/dev` folder it created stays; remove it if it is
empty and you don't use it.

Windows:

```powershell
Set-Location $HOME
& "$HOME\dev\repos\gitconfig\scripts\windows version\Move-ScriptsRoot.ps1" -From "$HOME\dev\repos" -To "$HOME\Documents\Scripts" -AllowSyncedTarget
```

macOS / Linux:

```sh
cd ~
bash ~/dev/repos/gitconfig/scripts/unix/move-scripts-root.sh --from ~/dev/repos --to ~/Documents/Scripts --allow-synced-target
```

Or restore by hand from the backup folder:
`~/.scripts-move-<timestamp>/backup/` holds the original of every file the run
changed, under its path relative to your home folder, so copy them back to
`~/<same path>`. `backup/links-and-tasks.txt` records what is not a file: each
link's old target, each scheduled task's old command line, each environment
variable's old value, the old crontab lines and the old names of the Claude
project folders; `backup/crontab.txt` is the whole crontab as it was. Then
rename the folder back.

## Troubleshooting

**The rename failed because files are open.** The tool stops with
`Could not rename ...` and exit 1, and nothing has changed. Something still has
a file or folder open under the old root:

- a terminal whose current folder is inside it (the tool moves its own
  process to your home folder first, but not other windows or a parent shell);
- an editor, Claude Code, a git GUI, a file explorer window, a running dev
  server or watcher;
- on Windows, find the process with Resource Monitor (CPU tab > Associated
  Handles, search for `Documents\Scripts`) or Sysinternals `handle.exe`;
- on macOS or Linux, `lsof +D ~/Documents/Scripts` lists them.

Close them and run the same command again.

**Resuming after a partial run.** If the move happened but a repair failed (or
the run was interrupted), run the same command again. With the old folder gone
and the new one in place, the tool prints `already moved; resuming repairs`,
skips the move and runs every repair step, so it finishes the job; a run
after a complete one says there is nothing to do and exits 0. It only works
while the old folder is still absent: if something recreated
`~/Documents/Scripts` in the meantime (an editor reopening a workspace, say),
the preflight stops because both folders exist. Move anything in the new old
folder into place by hand, delete it, and run again.

**A Claude project folder was left alone.** When a folder with the new name
already exists (Claude Code was opened in the new location before the
repairs), the tool doesn't merge the two; the report lists it under (c). Move
what you need from the old folder into the new one and delete the old one.

**A symbolic link could not be re-created (Windows).** Run from an elevated
PowerShell, or turn on Developer Mode (Settings > System > For developers),
then run again: the link is re-pointed on the resumed run.
