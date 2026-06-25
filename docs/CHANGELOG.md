# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`pyproject.toml` dependency manifest** — the helper's Python deps are now declared in one
  place: `rich` (required) under `[project.dependencies]` and `textual` (optional) under the
  `[project.optional-dependencies].tui` extra. Declaration only — the repo is scripts, not a
  pip-installable package. A dependency-free `scripts/shared/deps.py` reads it (tomllib with a
  regex fallback for Python < 3.11) ([#154](https://github.com/J-MaFf/gitconfig/pull/154), closes [#153](https://github.com/J-MaFf/gitconfig/issues/153))
- **Cross-repo guard for `git skill`** — the `git skill <cmd>` aliases dispatch into
  `~/.claude/skills/scripts/*`, which live in the separate [claude-skills](https://github.com/J-MaFf/claude-skills)
  repo. When that repo isn't installed at `~/.claude/skills`, every subcommand (`list`/`sync`/`status`/
  `publish`) now stops with one clear, actionable message (what's missing, where it comes from, and the
  `git clone … && setup` to fix it) instead of a generic "directory not found" or "wrapper script not
  found". `git skill help` and unknown-subcommand handling still work without the repo. Covered by new
  pytest cases in `tests/shared/test_gitconfig_helper.py`
  ([#155](https://github.com/J-MaFf/gitconfig/issues/155))
- **`git` preflight in the installers** — `scripts/{mac,linux} version/install.sh` and
  `scripts/windows version/install.ps1` now verify `git` is on `PATH` up front and exit with an
  "install git" message, rather than failing partway through (the whole tool configures git)
  ([#155](https://github.com/J-MaFf/gitconfig/issues/155))

### Changed

- **Consolidated the duplicated Python-dependency install logic** behind one routine per platform
  family that reads the manifest: `install_python_deps` in `scripts/shared/functions.sh` (bash, for
  the mac/linux installers + the login auto-update) and `Install-PythonDeps` in the new
  `scripts/windows version/Functions.ps1` (PowerShell, for `install.ps1` + `Update-GitConfig.ps1`).
  Replaced five near-identical pip blocks with calls. Behaviour is unchanged — idempotent,
  `py`→`python3`→`python` resolution, `--break-system-packages` fallback, optional-dep failure stays
  a warning. Pester tests retargeted to the new structure
  ([#154](https://github.com/J-MaFf/gitconfig/pull/154))

### Fixed

- `scripts/windows version/Initialize-LocalConfig.ps1` — fixed a spurious `[WARN] Git may
  have issues reading the configuration` printed by `install.ps1`. The verification step
  used `git config --local --list`, which reads the *repository* `.git/config` (unrelated to
  the generated `~/.gitconfig.local`) and errors with exit 128 when the current directory
  isn't a git repo — and `install.ps1` runs from the home directory. It now validates the
  generated file directly with `git config --file $localConfigPath --list` (scope- and
  CWD-independent), matching `Initialize-GitConfig.ps1` and `scripts/shared/functions.sh`.
  Added Pester coverage asserting the `[OK]` result (and no WARN) when run outside a repo
  ([#148](https://github.com/J-MaFf/gitconfig/issues/148))

- `.gitignore` — ignore Pester's generated `coverage.xml` code-coverage report (emitted at
  the repo root when `config/pester.config.ps1` runs with `CodeCoverage.Enabled = $true`),
  plus `testResults.xml` defensively (Pester's default test-result filename, not currently
  emitted since `TestResult` output is disabled). Keeps generated test artifacts out of
  `git status` ([#146](https://github.com/J-MaFf/gitconfig/issues/146))

### Changed

- `.gitconfig.template` / `gitconfig_helper.py` — adopted the `git <noun> <subcommand>`
  style for the skill aliases. The dashed `git skill-sync`, `git skill-sync-status`, and
  `git skill-publish` aliases are now the `git skill sync`, `git skill status`, and
  `git skill publish` subcommands, joining the existing `git skill list`. `git skill` with
  no argument (or `git skill help`) prints the available subcommands, and an unknown
  subcommand errors (exit 1). The `skill` Python dispatcher handles `list` itself and
  delegates `sync`/`status`/`publish` to the per-OS wrapper scripts in
  `~/.claude/skills/scripts` (PowerShell on Windows, bash elsewhere), which stay in the
  claude-skills repo so tweaks sync without touching this alias. `ALIAS_METADATA` now
  carries a single `skill` entry describing all four subcommands, so the `git alias`
  browser lists one discoverable "skill" row instead of three dashed ones
  ([#144](https://github.com/J-MaFf/gitconfig/issues/144))

### Removed

- `.gitconfig.template` — the dashed `git skill-sync`, `git skill-sync-status`, and
  `git skill-publish` aliases (replaced by the `git skill <subcommand>` forms above). This
  is a breaking change: invocations or keybindings using the old hyphenated names must
  switch to the space-separated subcommands ([#144](https://github.com/J-MaFf/gitconfig/issues/144))

### Added

- `.gitconfig.template` — new `git skill list` alias that lists installed skills
  (immediate subdirectories of `~/.claude/skills` containing a `SKILL.md`) as a `rich`
  table showing each skill's name, a one-line description parsed from its `SKILL.md`
  frontmatter, and the date it was last updated (last commit touching the skill, falling
  back to the file mtime). Implemented as a `skill` subcommand dispatcher in
  `gitconfig_helper.py` (so future `git skill <subcommand>` forms can be added) and
  registered in `ALIAS_METADATA` under "Claude Skills" so it appears in the `git alias`
  browser ([#140](https://github.com/J-MaFf/gitconfig/issues/140))

### Fixed

- `tests/gitconfig_helper.Tests.ps1` — the `cleanup Function` tests no longer run the
  destructive `git cleanup` / `cleanup --force` / `cleanup -f` against the current working
  directory. Run from a clone, that directory is the real repo, and `--force` deletes
  local-only branches and moves `HEAD` to `main` — it silently deleted a freshly created
  `feat/` branch during #141. The three tests now build a throwaway repo (with a wired bare
  remote, a deleted-remote "gone" branch, and a local-only branch) in a temp dir, run inside
  it, and restore the original location afterward — mirroring the `switch_to_main` /
  `update_all_main` isolation. They also now assert the expected branches are deleted/kept
  ([#142](https://github.com/J-MaFf/gitconfig/issues/142))

- `scripts/mac version/initialize-local-config.sh` — always write `[gpg "ssh"]
  allowedSignersFile` when commit signing is enabled, not only when 1Password's
  `op-ssh-sign` is detected. The template ships a literal `signingkey` with
  `commit.gpgsign = true`, so on a macOS box without 1Password the script wrote no
  `allowedSignersFile` and `git log --show-signature` reported "No signature" for
  perfectly valid signatures. It now mirrors the Linux script: when `op-ssh-sign` is
  absent but a `user.signingkey` is configured (literal key or a file-based key), it
  writes the `allowedSignersFile` block and registers the identity via
  `update_allowed_signers`. With no key and no 1Password it still skips, as before
  ([#116](https://github.com/J-MaFf/gitconfig/issues/116))

- `scripts/shared/update-gitconfig.sh` — fixed every log line being written **twice**.
  `log_message` piped through `tee -a "$LOG_FILE"` while the entire main block was already
  redirected with `>> "$LOG_FILE" 2>&1`, so each line landed in the log once via `tee` and
  again via the block redirect. The script runs headless under launchd/cron (no terminal),
  so `log_message` now uses a plain `echo` and the block redirect is the single source of
  truth ([#114](https://github.com/J-MaFf/gitconfig/issues/114))

- `.gitconfig.template` — normalized indentation to tabs throughout. The `[push]` and
  `[alias]` sections used four-space indentation while every other section used tabs; git
  accepts both but the inconsistency is fragile for any future formatter/validator. All
  value/comment lines are now tab-indented ([#113](https://github.com/J-MaFf/gitconfig/issues/113))

- `.gitconfig.template` — moved the `[include] path = ~/.gitconfig.local` directive to the
  **bottom** of the template. Git applies includes inline and the last declaration of a key
  wins, so with the include at the top the template's hardcoded literal `signingkey` silently
  overrode whatever the local config set (e.g. the file-based key on Linux). The include now
  runs last, so `~/.gitconfig.local` overrides take effect
  ([#112](https://github.com/J-MaFf/gitconfig/issues/112))

### Added

- Cross-platform test coverage for the shared scripts. Until now every test was Pester
  (Windows-only), leaving `scripts/shared/functions.sh` and `gitconfig_helper.py` untested
  on the primary dev platforms. Added `tests/shared/functions.bats` (bats-core) covering
  `backup_file`, `create_symlink`, `update_allowed_signers`, `generate_gitconfig`, and the
  git-alias widget enable/disable, plus `tests/shared/test_gitconfig_helper.py` (pytest)
  covering `_slugify`, `LABEL_PREFIX` selection, `_have`, `_default_branch`, and
  `get_git_aliases` parsing. See `tests/shared/README.md` to run them
  ([#115](https://github.com/J-MaFf/gitconfig/issues/115))
- `git skill-sync-status` alias — dispatches by OS to the claude-skills
  `skill-sync-status.{sh,ps1}` helper: shows this machine's last background sync (from
  `~/.claude/skills-sync.log`) plus any unpublished local changes. Sibling to `skill-sync`
  and `skill-publish` ([#127](https://github.com/J-MaFf/gitconfig/issues/127))
- `git alias` browser — when the interactive browser can't launch it no longer falls back
  to the static table **silently**: it prints a one-line reason to stderr (only when stderr
  is a TTY, so pipes/CI stay clean) — e.g. `textual` not installed, stdout not a TTY, or a
  UI error. It also now draws the browser on `/dev/tty` (mirroring the Ctrl-G widget's
  `2>/dev/tty`), so the UI renders even when the alias's stderr isn't the terminal. `--plain`
  and the Ctrl-G path stay silent ([#110](https://github.com/J-MaFf/gitconfig/issues/110))
- `git alias` browser — selecting an alias when launched by **typing `git alias`** now
  copies `git <alias>` to the clipboard (`pbcopy` / `clip` / `wl-copy` / `xclip` / `xsel`,
  with a printed fallback), so the command is one paste away. A typed `git alias` runs as
  a subprocess and can't insert at the prompt; the `Ctrl-G` keybinding still does direct
  insertion ([#108](https://github.com/J-MaFf/gitconfig/issues/108))
- `git alias` browser — **row navigation and prompt insertion**. Move through the
  results with up/down; press Enter (or click a row) to pick an alias. A `Ctrl-G` shell
  keybinding (bash `bind -x`, zsh ZLE widget, PowerShell PSReadLine) opens the browser
  and inserts the chosen `git <alias>` onto your command line, fzf-style: the browser
  emits the selection via `git alias --out <file>` and the keybinding inserts it (a
  git-alias subprocess can't type at the prompt itself). Install scripts source the
  matching widget (`scripts/shell/git-alias-widget.{bash,zsh,ps1}`) from your shell rc /
  `$PROFILE` (idempotent, guarded block); cleanup scripts remove it
  ([#106](https://github.com/J-MaFf/gitconfig/issues/106))
- Interactive `git alias` browser — running `git alias` in a terminal now opens a
  categorized, searchable table (built with `textual`): one tab per category with
  arrow-key/clickable navigation and a search box that filters by alias name **or**
  description. Falls back to a static grouped table when piped, in CI, when `textual`
  is absent, or with `git alias --plain`. `textual` is an optional dependency added to
  the install scripts (best-effort; the helper works without it)
  ([#102](https://github.com/J-MaFf/gitconfig/issues/102))
- New git aliases ([#102](https://github.com/J-MaFf/gitconfig/issues/102)):
  - **Inspect:** `s` (short status), `lg` (graph log), `last` (last commit + diffstat),
    `recent` (branches by last commit), `find` (`log -S`)
  - **Commit:** `amend`, `reword`, `undo` (soft reset), `unstage`, `wip`
  - **Branch & Sync:** `nb` (`switch -c`), `pushf` (`push --force-with-lease`),
    `sync` (`pull --rebase --autostash`)
  - **GitHub:** `pr` (open the branch's PR), `prs` (PR status)
- `git start <issue#>` — reads a GitHub issue's title and labels via `gh` and creates a
  conventionally named branch (`fix/`, `feat/`, or `docs/` + slugified title) from the
  up-to-date default branch ([#102](https://github.com/J-MaFf/gitconfig/issues/102))
- Setup now generates `~/.ssh/allowed_signers` and points `gpg.ssh.allowedSignersFile`
  at it (in `~/.gitconfig.local`) so git can verify SSH commit signatures locally —
  `git log --show-signature` and `git verify-commit` no longer report "No signature" on
  signed commits. Works across Windows (1Password), macOS (1Password), and Linux
  (file-based key); the entry is idempotent and preserves other identities. Shared bash
  logic lives in `scripts/shared/functions.sh` (`update_allowed_signers`); added a Pester
  guard (`tests/Initialize-LocalConfig.Tests.ps1`)
  ([#97](https://github.com/J-MaFf/gitconfig/issues/97))
- `git selfupdate` alias — pulls the gitconfig repo and reinstalls `~/.gitconfig` from
  the template on demand, dispatching to the correct platform script
  (PowerShell on Windows, bash on macOS/Linux) ([#78](https://github.com/J-MaFf/gitconfig/issues/78))
- `git skill-sync` alias — on-demand `pull --ff-only` of the claude-skills repo
  (`~/.claude/skills`), mirroring the auto-sync's fast-forward-only safety ([#83](https://github.com/J-MaFf/gitconfig/issues/83))
- `git skill-publish` alias — publish new/edited skills in the claude-skills repo
  (`~/.claude/skills`) from any directory via a PR. Delegates to that repo's
  `publish-skill` script (branch → signed commit → PR → squash auto-merge), since its
  `main` is now branch-protected and can't be pushed to directly. Dispatches by OS
  like `selfupdate` ([#82](https://github.com/J-MaFf/gitconfig/issues/82))

### Changed

- `git selfupdate` is now **convergent and resilient** so it reliably keeps `~/.gitconfig`
  in sync. It regenerates whenever the installed config differs from the rendered template
  (idempotent, checked every run) instead of only when a pull happened to change the template
  — so it self-heals from a no-op pull, an already-current clone, or a hand-edited/deleted
  config. The repo update is now best-effort: a dirty working tree, offline state, or
  diverged history no longer aborts the run (it still converges `~/.gitconfig`), the pull is
  `--ff-only`, and a failed `fetch --prune` is non-fatal. `generate_gitconfig` /
  `Initialize-GitConfig.ps1` gained an idempotent skip (no rewrite/`.bak` churn when already
  current) ([#129](https://github.com/J-MaFf/gitconfig/issues/129))
- `git skill-sync` now dispatches by OS to the claude-skills `skill-sync.{sh,ps1}` wrapper
  (status → `pull --ff-only` → status) instead of running the bare `pull --ff-only`, so a
  skill edited on one machine but not yet published is surfaced before and after the sync.
  Pointing the alias at an auto-syncing script means future changes need no further gitconfig
  update ([#123](https://github.com/J-MaFf/gitconfig/issues/123))
- The auto-update job (`git selfupdate` and the login-triggered run) now also
  ensures the optional `textual` dependency is installed — best-effort and only
  when missing — so existing machines pick up the interactive `git alias` browser
  on their next update without a manual `pip install`
  ([#102](https://github.com/J-MaFf/gitconfig/issues/102))
- The static `git alias` table is now grouped by category (Inspect, Commit, Branch &
  Sync, GitHub, Maintenance, Claude Skills) with a dedicated Category column, and
  curated descriptions for every built-in alias. The claude-skills aliases
  (`skill-sync`, `skill-publish`) get their own "Claude Skills" category
  ([#102](https://github.com/J-MaFf/gitconfig/issues/102))
- The auto-update job (`git selfupdate` and the login-triggered run) now **prunes
  merged branches** instead of recreating them. It fetches with `--prune` to drop
  stale remote-tracking refs and deletes local branches whose upstream remote was
  deleted (`: gone]`), mirroring the `git cleanup` alias. The previous behavior
  recreated a local tracking branch for every remote on every run, so merged
  branches accumulated and deleted branches were resurrected. Creating tracking
  branches for all remotes is still available on demand via `git branches`
  ([#93](https://github.com/J-MaFf/gitconfig/issues/93))

### Fixed

- `Initialize-GitConfig.Tests.ps1` ("Generated config should contain absolute paths") no
  longer fails: its regex expected a literal `python <abs-path>/gitconfig_helper.py`, but the
  helper aliases were refactored to a `for p in py python3 python; do … exec "$p" <path>`
  loop, so the path is invoked via the `$p` variable. Updated the assertion to match an
  absolute path to `gitconfig_helper.py` (Unix or Windows)
  ([#130](https://github.com/J-MaFf/gitconfig/issues/130))
- `Integration.Tests.ps1` no longer fails on the `branches` alias: the assertion expected
  `2>/dev/null; done` but the alias ends with `2>/dev/null || true; done` (the `|| true`
  was added so a failed per-branch create doesn't abort the loop). Updated the regex to match
  ([#125](https://github.com/J-MaFf/gitconfig/issues/125))
- Pester tests in the "Step 2b: Regenerate ~/.gitconfig on Template Change" context
  no longer fail with `The term 'Push-RemoteChange' is not recognized`. The
  `Push-RemoteChange` helper was defined directly in the `Context` body, which is not
  visible inside `It` blocks under Pester v5; it's now declared in a `BeforeAll` so the
  two affected tests run. No production code changed
  ([#95](https://github.com/J-MaFf/gitconfig/issues/95))
- `git alias`, `git cleanup`, and `git main` no longer print a spurious
  "Python was not found" line on Windows. The aliases resolved Python with
  `command -v python3`, which matches the Microsoft Store app-execution-alias stub;
  the stub ran first, emitted the message, and exited before the real `python` fallback.
  The aliases now resolve `py -> python3 -> python` and verify each interpreter actually
  runs (`-c ''`) before using it, skipping the stub. Apply on an installed machine with
  `git selfupdate`. Added a Pester guard (`tests/GitconfigTemplate.Tests.ps1`)
  ([#91](https://github.com/J-MaFf/gitconfig/issues/91))
- `git cleanup` (and `git main`) no longer crash with `UnicodeEncodeError` on the
  legacy Windows console. `gitconfig_helper.py` printed a `✓` checkmark and `──`
  box-drawing characters via `rich`, which fall back to the cp1252 renderer and cannot
  encode those glyphs. Replaced them with ASCII equivalents (`[OK]`, `--`) matching the
  `[OK]`/`[WARN]` convention, and added a Pester guard asserting the helper is ASCII-only
  ([#87](https://github.com/J-MaFf/gitconfig/issues/87))
- `install.ps1` no longer fails to parse under Windows PowerShell 5.1. The script
  contained em dash characters (`—`) and lacked a UTF-8 BOM, so the legacy ANSI-codepage
  reader mangled them into smart-quotes that broke string literals. Em dashes are now
  ASCII hyphens and the file carries a BOM. Added a Pester guard test
  (`tests/Encoding.Tests.ps1`) asserting every `scripts/windows version/*.ps1` is
  ASCII-only and parses cleanly ([#85](https://github.com/J-MaFf/gitconfig/issues/85))
- Login auto-update now reinstalls `~/.gitconfig` when `.gitconfig.template` changed
  during the pull, instead of only pulling. Template changes (new aliases, signing/push
  tweaks) take effect automatically with no manual re-run. The existing `~/.gitconfig`
  is backed up to `~/.gitconfig.bak` first; `~/.gitconfig.local` is never touched
  ([#78](https://github.com/J-MaFf/gitconfig/issues/78))

## [0.1.0-pre] - 2025-12-15

### Added

- **Git Configuration (`gitconfig`)**
  - SSH-based commit signing with OpenSSH key format (ed25519)
  - Custom git aliases for common workflows
  - Auto-setup remote tracking for pushed branches
  - VS Code as default editor with `--wait` flag
  - Safe directory configurations for network and local repositories

- **Git Helper (`gitconfig_helper.py`)**
  - `print_aliases()` - Display all configured aliases in formatted table
  - `cleanup_branches()` - Delete local branches with deleted remotes or unused local branches
  - Support for `--force` flag to include local-only branch deletion
  - Formatted console output using Rich library

- **Setup Automation (PowerShell Scripts)**
  - `install.ps1` - Unified setup wrapper orchestrating complete configuration
  - `Initialize-Symlinks.ps1` - Create symbolic links from home directory to repo files
  - `Initialize-LocalConfig.ps1` - Generate machine-specific `.gitconfig.local`
  - `Register-LoginTask.ps1` - Create Windows scheduled task for auto-sync
  - `Update-GitConfig.ps1` - Automated daily git pull via Task Scheduler
  - `Cleanup-GitConfig.ps1` - Clean uninstall and reset utility

- **Configuration Files**
  - `.gitignore` - Excludes `.gitconfig.local` and log files
  - `.github/copilot-instructions.md` - Development guidelines with semantic versioning reference
  - Tests in `tests/` directory for PowerShell scripts and Python helpers

- **Features**
  - Portable configuration across different machines and user accounts
  - Environment variable support (no hardcoded paths)
  - Automatic backup of existing files to `.bak` before overwriting
  - Admin privilege handling with automatic elevation
  - Machine-specific configuration via `.gitconfig.local`
  - Support for network repositories as safe directories
  - Daily automatic synchronization via Windows Task Scheduler
  - Comprehensive help text with `-Help` parameter on scripts

### Git Aliases

- `git alias` - List all aliases in a formatted table
- `git branches` - Download all remote branches and create local tracking branches
- `git cleanup` - Delete branches with deleted remotes (merged branches)
- `git cleanup --force` - Also delete local-only branches never pushed to remote
- `git localconfig` - Manage machine-specific git configuration

### Documentation

- Comprehensive README with installation and usage instructions
- Troubleshooting guide for common issues
- Configuration details for SSH signing and safe directories
- Development guidelines following Semantic Versioning (semver.org)
- This CHANGELOG documenting all changes

---

## [Unreleased]

### New Features

- **Enhanced `git main` Alias**
  - Automatic cleanup of branches with deleted remotes during `git main`
  - Integrated `cleanup_branches()` function into switch_to_main workflow
  - Merged branches are removed without requiring separate `git cleanup` call
  - Local-only branches are preserved (use `git cleanup --force` if needed)

- **Template-Based Configuration**
  - `.gitconfig.template` - Version-controlled template with placeholders
  - `Initialize-GitConfig.ps1` - Script to generate `.gitconfig` from template
  - Placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}` replaced during generation
  - Automatic path conversion to forward slashes for git compatibility

- **Additional Tests**
  - `Initialize-GitConfig.Tests.ps1` - Comprehensive tests for config generation
  - Tests verify placeholder replacement, path conversion, INI format validity

### Improvements

- **`git main` Workflow Order**
  - Main branch is pulled/updated before cleanup runs
  - Cleanup has accurate information about deleted branches
  - Ensures current branch (with deleted remote) is safely switched before cleanup
  - Logical sequence: switch to main → pull latest → cleanup stale branches

- **Portability**: No hardcoded paths in version control
- **Maintainability**: Changes to template automatically propagate on regeneration
- **Documentation**: Updated README, copilot-instructions.md to reflect new architecture
- **Testing**: Updated `Setup-GitConfig.Tests.ps1` to verify generation instead of symlinking

### Breaking Changes

- **BREAKING**: `.gitconfig` is now generated from `.gitconfig.template` instead of being version controlled
  - Existing setup will require running `install.ps1` again to regenerate
  - Benefits: No hardcoded paths, complete portability across machines
- Updated `install.ps1` to generate config instead of creating symlink
- `.gitconfig` is no longer a symlink - it's a generated file in home directory
- Only `.gitignore_global` and `gitconfig_helper.py` are symlinked now

### Planned

- Additional git aliases for common workflows
- Support for GPG signing in addition to SSH
- Extended logging and diagnostics
- Configuration validation and health checks
