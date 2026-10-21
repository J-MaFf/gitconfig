# Spec: Move the Scripts root out of `~/Documents`

## Goal
Ship a cross-platform tool in this repo that moves the folder holding every
clone (the "Scripts root", today `~/Documents/Scripts`) to `~/Scripts`. It then
re-points everything on the machine that depends on the old path, so all
repos, git aliases, scheduled jobs and links work from the new location with
no reference to the old one left behind. A runbook explains how to run it on
each machine.

## Context
- **Why.** On Windows, Google Drive for desktop backs up `~/Documents`,
  including every repo's `.git` folder. On a sync conflict it saves copies
  such as `.git/refs/heads/main (1)`. That is an invalid refname, and every
  `git fetch`/`pull` then fails with
  `fatal: bad object refs/heads/main (1) ... did not send all necessary objects`.
  Drive for desktop cannot exclude a subfolder of a backed-up folder, so the
  repos have to live outside `~/Documents`. The same layout is wanted on every
  machine (Windows, macOS, Linux) so paths stay uniform.
- **Decided with the owner (2026-10-21):**
  - The new root is `~/Scripts` on every OS.
  - The deliverable is a migration tool (PowerShell and bash) plus a runbook.
  - **No shim:** no junction, symlink or alias may be left at the old path.
    On a machine where Drive backs up Documents, a link would bring the repos
    back into sync.
  - Every reference is updated instead.
- **How this repo already finds its paths.** These are generators the tool
  re-runs, not files it edits:
  - `scripts/windows version/Initialize-GitConfig.ps1` renders
    `.gitconfig.template` into `~/.gitconfig`. It substitutes `{{REPO_PATH}}`
    (the `h` helper alias, `selfupdate`, and the header comment) with the
    clone's own location (two folders above the script). On unix the same job
    is done by `scripts/shared/initialize-gitconfig.sh` / `generate_gitconfig`
    in `scripts/shared/functions.sh`.
  - `scripts/windows version/Initialize-Symlinks.ps1` and `create_symlink`
    (`functions.sh`) link `~/.gitignore_global` and `~/gitconfig_helper.py`
    into the clone.
  - `scripts/windows version/Register-LoginTask.ps1` registers
    "GitConfig Pull at Login" with `-RepoPath <clone>`. It already replaces a
    task whose arguments differ (the "moved repo" case).
  - `scheduler_install` in `scripts/shared/platform.sh` writes the clone path
    into the cron line, the systemd user unit `ExecStart` or the launchd plist.
    Old cron lines are matched by the old path, so a moved clone's old line is
    **not** removed automatically.
  - `install.ps1` step 6b (`Set-MarkedBlock`) and `enable_git_alias_widget`
    (`functions.sh`) write the profile/rc line that loads
    `scripts/shell/git-alias-widget.*`. They rewrite the line when run again.
  - `Initialize-LocalConfig.ps1` / `initialize-local-config.sh` write
    `[safe] directory` entries into `~/.gitconfig.local`. When regenerating
    they keep earlier entries word for word, so old-root entries survive a
    regenerate.
  - `_scripts_root()` in `gitconfig_helper.py` reads `gitconfig.scriptsRoot`
    or derives the root from the resolved location of `gitconfig_helper.py`.
    It follows a move once `~/gitconfig_helper.py` is re-pointed.
- **Dependencies seen on the owner's Windows machine** outside this repo.
  These are the categories the tool must handle generically; the examples are
  illustrative only:
  - A junction `~/.claude/skills` → `<root>/agent-skills`, plus other home
    links into the root.
  - Scheduled tasks whose action or working directory is under the root.
  - A user `PATH` entry under the root.
  - `.lnk` shortcuts (Desktop, Start Menu, Startup) targeting the root.
  - `.code-workspace` files holding relative paths such as
    `../../Documents/Scripts/<repo>`.
  - MCP config `.mcp.json` files and Claude Code scheduled-task `SKILL.md`
    files with absolute root paths.
  - Claude Code per-project folders under `~/.claude/projects/`, named by
    encoding the project path (every non-alphanumeric character becomes `-`).
    Verified: `C:\Users\u\Documents\Scripts\gitconfig\.claude\worktrees\x` is
    stored as `C--Users-u-Documents-Scripts-gitconfig--claude-worktrees-x`.
  - Linked git worktrees, which store absolute paths on both sides
    (`worktree.useRelativePaths` is unset).
  - Python venvs, which embed absolute paths.
- **Other repos are out of scope here.** Hard-coded old-root paths in other
  repos, and the order in which the owner's machines are migrated, are covered
  by a separate private companion spec. This spec covers only the tool, its
  tests, and this repo's own docs.
- This repo is **public**. Nothing in it may name the owner's machines,
  hostnames, private repo contents or credential locations.

## Deliverable
1. `scripts/windows version/Move-ScriptsRoot.ps1`, the Windows tool
   (PowerShell 7 and Windows PowerShell 5.1).
2. `scripts/unix/move-scripts-root.sh`, the macOS and Linux tool (bash,
   compatible with macOS system bash 3.2). It sources `scripts/shared/*.sh`
   like the other unix entry points.
3. `tests/Move-ScriptsRoot.Tests.ps1` (Pester) and
   `tests/shared/move-scripts-root.bats` (bats).
4. `docs/MOVE-SCRIPTS-ROOT.md`, the runbook.
5. Edits to `README.md`, `docs/WORKFLOW.md` and the `gitconfig_helper.py`
   `_scripts_root` docstring so the documented default install path is
   `~/Scripts/gitconfig`, plus a `docs/CHANGELOG.md` `[Unreleased]` entry.

## Requirements

### Interface
- R1. The Windows tool accepts `-From` (default `$HOME\Documents\Scripts`),
  `-To` (default `$HOME\Scripts`), `-DryRun`, `-Yes`, and `-AllowSyncedTarget`.
  The unix tool accepts the same options as `--from`, `--to`, `--dry-run`,
  `--yes` and `--allow-synced-target`, with defaults `$HOME/Documents/Scripts`
  and `$HOME/Scripts`. `-h`/`--help` prints usage and exits 0.
  [verify: run each tool with `--help`/`-?`; read the param block / option parser]
- R2. Exit codes follow repo convention: 0 means success or nothing to do;
  1 means a failure (a preflight abort, or at least one repair step failing);
  2 means a required confirmation was declined or got no input (stdin is not
  a terminal and `-Yes`/`--yes` was not given).
  [verify: tests assert `$status` / `$LASTEXITCODE` for each case]

### Preflight (runs before any change; any abort leaves the machine untouched)
- R3. The tool aborts with exit 1 and a message naming the cause when:
  - (a) `From` and `To` resolve to the same path, or one is inside the other;
  - (b) neither `From` nor `To` exists;
  - (c) both exist and `To` is not an empty directory;
  - (d) `From` and `To`'s parent are on different volumes or filesystems
    (drive letter on Windows; device id via `stat` on unix).
  [verify: one test per sub-case asserts exit 1, the message, and that `From` is unchanged]
- R4. Unless `-AllowSyncedTarget` is given, the tool aborts with exit 1 when
  `To` is at or under any of these: `~/Documents`, `~/Desktop`, `~/Pictures`,
  `$env:OneDrive`, `$env:OneDriveCommercial` (when set), `~/Library/CloudStorage`,
  `~/Google Drive`, `~/Dropbox`.
  [verify: test with `To=~/Documents/Scripts2` asserts exit 1; with the flag it proceeds]
- R5. When a Google Drive for desktop process is running (Windows process
  `GoogleDriveFS`; macOS process `Google Drive`), the tool asks the user to
  pause Drive syncing and confirm. Declining, or having no input without
  `-Yes`, exits 2 with nothing changed.
  [verify: test mocks the process check; asserts exit 2 and `From` untouched]
- R6. Before changing anything, the tool prints the full plan:
  - the move;
  - each repo and worktree to repair;
  - each file to rewrite, with its match count;
  - each link to re-point;
  - each scheduled task or job to update;
  - each Claude project folder to rename;
  - each item it will only report (R18).
  Unless `-Yes` is given, it then asks for one confirmation, and declining
  exits 2.
  [verify: test captures output; asserts each category header appears with its items]
- R7. `-DryRun` prints the R6 plan and exits 0 without creating, moving,
  rewriting or deleting anything, including backups and the report.
  [verify: test snapshots the sandbox HOME tree (paths, sizes, mtimes) before and after; they are identical]

### Move
- R8. The move is a single same-volume directory rename of `From` to `To`.
  If the rename fails (for example a handle is open under `From`), the tool
  exits 1 with nothing changed. The message tells the user to close programs
  and terminals using files under `From`.
  [verify: read code (one rename call; no copy-then-delete); test simulates the rename failing]
- R9. The tool completes successfully when launched from its own location
  inside `From`, with the shell's working directory also inside `From`. Before
  renaming, it changes its own working directory to `$HOME`.
  [verify: test runs the tool by its in-sandbox path with cwd under `From`; asserts exit 0 and `To` exists]
- R10. **Resume.** When `From` is missing and `To` exists, the tool skips the
  move, prints `already moved; resuming repairs`, and runs every repair step
  (R11–R17). A second run after a fully successful run makes no changes and
  exits 0.
  [verify: test runs the tool twice; the second run's output reports nothing to do and the sandbox snapshot is unchanged]

### Repairs (run after the move; each step runs even if an earlier one failed; failures are collected)
- R11. **Worktrees.** For every git repo under `To` (a directory up to 3 levels
  deep containing a `.git` directory, skipping `node_modules` and `.venv`)
  that has linked worktrees, the tool runs
  `git -C <repo> worktree repair <each worktree's path with From replaced by To>`.
  It also repairs any linked worktree under `To` whose main repo is under `To`.
  [verify: test builds a repo with one worktree inside and one sibling worktree under `From`; after the run, `git -C <wt> status` succeeds for both and `git worktree list --porcelain` has no `From` path and no `prunable`]
- R12. **This repo's generators** are re-run from the clone's new location:
  - Windows: `Initialize-GitConfig.ps1 -Force`, `Initialize-Symlinks.ps1`,
    `Register-LoginTask.ps1 -RepoPath <new clone>`, and the step-6b profile
    marked-block update (both editions).
  - Unix: `generate_gitconfig`, `create_symlink` for the two home links,
    `scheduler_install`, and `enable_git_alias_widget`. Afterwards, no crontab
    line still contains `From`.
  They are skipped, and reported, when the gitconfig clone is not under `To`.
  [verify: after the run, `~/.gitconfig`, both home links, the login task / scheduler entry, and the profile/rc line contain `To` and not `From`]
- R13. **Links.** Every symlink or junction in this scan set whose target is at
  or under `From` is recreated with the same name and type, pointing at the
  matching path under `To`:
  - `$HOME` (depth 1);
  - `$HOME/.claude` (depth 1);
  - `$HOME/.config` (depth 2);
  - `$HOME/.local/bin` (depth 1);
  - `$HOME/bin` (depth 1).
  On Windows a junction stays a junction and a symbolic link stays a symbolic
  link.
  [verify: test creates one junction and one symlink (Windows) / symlinks (unix) into `From`; after the run each has the same LinkType and its target is under `To`]
- R14. **Text rewrites.** In this exact file set, every occurrence of the old
  root as a path prefix is replaced with the new root:
  - PowerShell profiles: `profile.ps1`, `Microsoft.PowerShell_profile.ps1` and
    `Microsoft.VSCode_profile.ps1` in both `Documents\PowerShell` and
    `Documents\WindowsPowerShell`;
  - `~/.gitconfig.local`;
  - `~/.config/gitconfig/safe-directories`;
  - `~/.bashrc`, `~/.bash_profile`, `~/.profile`, `~/.zshrc`, `~/.zprofile`,
    `~/.config/fish/config.fish`;
  - `~/.claude/settings.json`;
  - `~/.claude/scheduled-tasks/*/SKILL.md`;
  - `~/.vscode/workspaces/*.code-workspace`;
  - `~/.vscode/agent-plugins/**/.mcp.json`.

  Matching rules:
  - A match counts only at a path boundary: the old root followed by `/`,
    `\`, a quote, whitespace, or end of line. `.../ScriptsOld` is not a match.
  - Each match is replaced in the same form it was written: native
    backslashes, forward slashes, JSON-escaped `\\`, `$HOME`/`~`/
    `$env:USERPROFILE`/`%USERPROFILE%`-relative forms, and relative paths in
    `.code-workspace` files that resolve, from the file's own folder, to a
    path under the old root.
  - Matching is case-insensitive on Windows and macOS, and case-sensitive on
    Linux.
  - Files are kept in their encoding and line endings.
  [verify: test fixture files contain each form plus a `ScriptsOld` decoy; after the run every form points under `To`, the decoy is unchanged, and byte-level line endings and BOM are preserved]
- R15. **Windows scheduled tasks.** Every task the current user can modify,
  whose action `Execute`, `Arguments` or `WorkingDirectory` contains the old
  root, is updated to the new root, keeping every other property (triggers,
  principal, settings). A task the tool may not modify goes to the R18 report.
  [verify: Pester mocks `Get-ScheduledTask`/`Set-ScheduledTask`; asserts the updated action strings and that triggers are passed through unchanged]
- R16. **Windows environment and shortcuts.**
  - Every `PATH` entry and every other user-scope environment variable value
    containing the old root is rewritten (user scope only, never machine
    scope).
  - Every `.lnk` file under the user's Desktop and Start Menu `Programs`
    (recursive, including `Startup`) whose `TargetPath`, `Arguments`,
    `WorkingDirectory` or `IconLocation` contains the old root is rewritten.
  [verify: Pester asserts through a mocked env-var layer that the real runner's environment is untouched; it creates a `.lnk` in a sandbox Desktop and reads it back with `WScript.Shell`]
- R17. **Unix scheduled jobs and Claude project folders.**
  - User crontab lines containing the old root are rewritten in one
    `crontab` install.
  - Files in `~/.config/systemd/user/` containing it are rewritten, then
    `systemctl --user daemon-reload` runs, and only units that were active
    before the move are restarted.
  - Plists in `~/Library/LaunchAgents/` containing it are rewritten and
    reloaded (bootout + bootstrap).
  - On every OS, each folder in `~/.claude/projects/` whose name equals the
    encoded old root, or starts with it followed by `-`, is renamed by
    swapping that prefix for the encoded new root. If the destination already
    exists, that folder is left alone and goes into the R18 report.
  [verify: bats uses the repo's existing `crontab`/`systemctl`/`launchctl` sandboxes; a test with project folders `<enc(From)>`, `<enc(From)>-repo` and `<enc(From)>Old` renames the first two only]

### Report and verification
- R18. After the repairs, the tool rescans every location from R11–R17 for the
  old root. It then writes a report and prints it, listing:
  - (a) every change made;
  - (b) every failure;
  - (c) remaining references in the R13–R17 locations, each counted as a
    failure;
  - (d) items it only reports, without counting them as failures:
    - venvs (folders under `To` containing `pyvenv.cfg`), which need
      recreating;
    - system-scope jobs (`/etc/systemd/system`, `/Library/LaunchDaemons`,
      root crontab, tasks the user can't modify);
    - app state files that mention the old root: `~/.claude.json`,
      `%APPDATA%\Claude\*.json`, VS Code `globalStorage`.

  The report is written to `~/.scripts-move-<yyyyMMdd-HHmmss>/report.txt`.
  [verify: test asserts report sections and that a planted venv and a planted `~/.claude.json` reference appear under (d) and do not change the exit code]
- R19. Before modifying any file, the tool copies it to
  `~/.scripts-move-<timestamp>/backup/` under its path relative to `$HOME`.
  It records each modified link's and task's previous target or arguments in
  `backup/links-and-tasks.txt`.
  [verify: after a run, every rewritten fixture has a byte-identical original in the backup folder]
- R20. The tool never modifies:
  - file contents inside any repo under `To`, other than git worktree
    metadata;
  - machine-scope environment variables;
  - the app state files listed in R18(d).
  [verify: test hashes a tracked file in a sandbox repo and a sandbox `~/.claude.json` before and after; both hashes are unchanged]

### Docs and tests
- R21. `docs/MOVE-SCRIPTS-ROOT.md` contains these sections, in order:
  1. Why;
  2. Before you start: pull every repo with `git main --all`, close editors,
     Claude and terminals under the old root, pause Google Drive;
  3. Windows;
  4. macOS / Linux, with the exact dry-run command and then the real command;
  5. After the move: recreate venvs; re-approve Claude folder permissions;
     what Google Drive does with its copy of the old folder;
  6. Rollback: run again with `--from`/`--to` swapped and
     `--allow-synced-target`, or restore from the backup folder;
  7. Troubleshooting: rename failed because of open handles; resume after a
     partial run.
  It names no machines or hostnames.
  [verify: read the file; check the headings and their order; grep for hostnames finds none]
- R22. `README.md`, `docs/WORKFLOW.md` and the `_scripts_root` docstring show
  `~/Scripts/gitconfig` (or `$HOME\Scripts\gitconfig`) as the install path.
  `grep -rn "Documents.Scripts"` over `README.md`, `docs/WORKFLOW.md`,
  `gitconfig_helper.py` and `scripts/` finds no matches, except tests and the
  tool's own default `From` value and help text.
  [verify: run the grep]
- R23. The Pester and bats suites cover every requirement tagged with a test
  above. They run in CI (`.github/workflows/test.yml`, unchanged) and pass on
  every job: Pester under pwsh 7 and Windows PowerShell 5.1, bats on ubuntu
  and macos, and PSScriptAnalyzer clean. No test touches the runner's real
  `HOME`, user environment, scheduled tasks, crontab or launchd.
  [verify: CI run on the PR is green; read test setup for sandboxing]

## Out of scope
- Editing hard-coded old-root paths inside other repos, and migrating the
  owner's specific machines (both belong to the private companion spec).
- Recreating Python venvs or reinstalling node modules (reported only).
- Editing app state files (`~/.claude.json`, Claude desktop config, VS Code
  state) or system-scope jobs (reported only).
- Configuring or detecting Google Drive's backup settings, beyond the R5
  running-process check.
- Cross-volume moves (copy-and-delete).
- Leaving any compatibility link at the old path.
- Removing `.bak` copies or stale entries unrelated to the old root.
- A new `gitconfig.scriptsRoot` setting: the derived root already follows the
  move.

## Constraints
- Platforms: Windows PowerShell 5.1 and PowerShell 7 (avoid empty-string
  native arguments, which 5.1 drops); bash 3.2+ on macOS and Linux (no
  associative arrays and no `${var,,}`).
- Reuse the existing helpers rather than duplicating them: `Set-MarkedBlock`,
  `ConvertTo-GitSafeDirectory`, `create_symlink`, `scheduler_install`,
  `_cron_remove_entries`, `backup_copy`, `ask_yes_no`.
- Follow repo conventions from `CLAUDE.md`: exit codes 1 and 2; tests assert
  `$status`; tests never run install, cleanup or update scripts against the
  real home.
- Do not name the owner's machines, private repos' contents, or credential
  locations anywhere in this repo (it is public).
- One PR for this spec, with `Fixes #<issue>`, signed commits, and the
  CHANGELOG updated in the same PR.

## Acceptance rubric
- C1 (R1): PASS iff both tools accept the listed options with the listed
  defaults and `--help`/`-?` exits 0 with usage text.
- C2 (R2): PASS iff tests demonstrate exit 0, 1 and 2 in the stated
  situations.
- C3 (R3): PASS iff each of the four preflight cases exits 1 with `From`
  unchanged, shown by a test per case.
- C4 (R4): PASS iff a `To` under `~/Documents` is refused without the flag and
  accepted with it.
- C5 (R5): PASS iff a running (mocked) Drive process with a declined or absent
  confirmation exits 2 with nothing changed.
- C6 (R6): PASS iff the printed plan lists every category from R6, with
  items, before any change.
- C7 (R7): PASS iff the before and after snapshots of a `-DryRun` are
  identical.
- C8 (R8): PASS iff the move is one rename call and a failed rename exits 1
  leaving `From` intact.
- C9 (R9): PASS iff a run started from inside `From` with cwd inside `From`
  succeeds.
- C10 (R10): PASS iff a second run is a no-op with exit 0, and a run after a
  manual move completes the repairs.
- C11 (R11): PASS iff both test worktrees work after the move and
  `worktree list` shows no old path or `prunable`.
- C12 (R12): PASS iff `~/.gitconfig`, the home links, the login task or
  scheduler entry, and the profile/rc line reference only `To`.
- C13 (R13): PASS iff each test link keeps its type and points under `To`.
- C14 (R14): PASS iff every fixture path form is rewritten, the decoy is
  untouched, and encoding and line endings are byte-preserved.
- C15 (R15): PASS iff mocked tasks get rewritten actions with triggers passed
  through.
- C16 (R16): PASS iff user env vars and `.lnk` fields are rewritten, and the
  test proves the real environment was untouched.
- C17 (R17): PASS iff crontab, systemd user and launchd fixtures are rewritten
  and reloaded as specified, and only the two matching project folders are
  renamed.
- C18 (R18): PASS iff the report has sections (a)–(d) and report-only items
  don't affect the exit code.
- C19 (R19): PASS iff every modified file has a byte-identical backup and
  link/task originals are recorded.
- C20 (R20): PASS iff the tracked-file and `~/.claude.json` hashes are
  unchanged after a run.
- C21 (R21): PASS iff the runbook has the seven sections in order and names
  no machines.
- C22 (R22): PASS iff the grep finds no stray `Documents/Scripts` outside the
  allowed places.
- C23 (R23): PASS iff CI is green on every job and test setup sandboxes all
  real-system touchpoints.
- C-final: PASS iff a maintainer of this repo, reading the tool and the
  runbook, would run it on a real machine without substantive changes.

## Open questions
None.
