# Project Status

## What This Is

A cross-platform tool that generates a portable `~/.gitconfig` from a version-controlled template (`.gitconfig.template`), layers machine-specific overrides via `~/.gitconfig.local`, and keeps it converged through an auto-update job (a login scheduled task on Windows, a launchd login agent on macOS, a daily cron job on Linux). Helper logic (`gitconfig_helper.py`) backs the custom git aliases. Windows setup is PowerShell + Pester; macOS/Linux are bash.

## Current State — 2026-10-11

Healthy; `main` is clean and no PRs are open. A repo-wide bug review filed [#250](https://github.com/J-MaFf/gitconfig/issues/250)–[#263](https://github.com/J-MaFf/gitconfig/issues/263); all fourteen are fixed and merged (PRs [#264](https://github.com/J-MaFf/gitconfig/pull/264)–[#278](https://github.com/J-MaFf/gitconfig/pull/278) and [#280](https://github.com/J-MaFf/gitconfig/pull/280); see Resolved Issues below and `CHANGELOG.md`). The ones that change how the scripts behave:

- **macOS/Linux exit codes:** `install.sh` exits 1 when a step fails, `cleanup-gitconfig.sh` exits 1 when something is left, and a declined prompt exits 2. A prompt with no input counts as "no" instead of silently aborting the run; `--force` answers yes for unattended runs ([#258](https://github.com/J-MaFf/gitconfig/issues/258)).
- **Unix auto-sync:** the cron job logs to `${XDG_STATE_HOME:-~/.local/state}/gitconfig/gitconfig-update.log` instead of `/tmp`, install and cleanup claim only this clone's cron line, and launchd/cron paths are escaped ([#259](https://github.com/J-MaFf/gitconfig/issues/259)).
- **`~/.gitconfig.local`:** `install.sh --force` keeps the settings you added; a symlinked `~/.gitconfig` or `~/.gitconfig.local` is replaced instead of written through ([#257](https://github.com/J-MaFf/gitconfig/issues/257)). `git localconfig` with no arguments opens the file in your editor ([#263](https://github.com/J-MaFf/gitconfig/issues/263)).
- **Windows:** a failed symlink keeps the existing file and exits 1, cleanup keeps the PowerShell profile's encoding ([#255](https://github.com/J-MaFf/gitconfig/issues/255)); the login task no longer waits for a network and a failed pip install is no longer logged as `[OK]` ([#256](https://github.com/J-MaFf/gitconfig/issues/256)); the Ctrl-G widget inserts the picked alias again ([#254](https://github.com/J-MaFf/gitconfig/issues/254)).
- **Helper:** unknown flags and `-h` run nothing ([#250](https://github.com/J-MaFf/gitconfig/issues/250)), `git pushf` adds `--force-if-includes` ([#251](https://github.com/J-MaFf/gitconfig/issues/251)), `git start` names branches `<type>/<issue>-<slug>` ([#252](https://github.com/J-MaFf/gitconfig/issues/252)), the original pre-install file is kept as `<file>.pre-gitconfig` ([#253](https://github.com/J-MaFf/gitconfig/issues/253)).

- **macOS:** the bash Ctrl-G widget needs bash 4+ and says so under `/bin/bash` 3.2, launchd uses `launchctl bootstrap`/`bootout`, and a per-user lock keeps to one sync at a time ([#234](https://github.com/J-MaFf/gitconfig/issues/234)).

Not yet checked on a real machine: the Ctrl-G widget under pwsh 7 and Windows PowerShell 5.1 ([#269](https://github.com/J-MaFf/gitconfig/pull/269)), `install.ps1` replacing a network-gated login task left by an older version ([#275](https://github.com/J-MaFf/gitconfig/pull/275)), and `launchctl bootstrap`/`bootout` plus the bash 3.2 Ctrl-G note on a real Mac ([#234](https://github.com/J-MaFf/gitconfig/issues/234)).

### Components

| Path | Description |
|------|-------------|
| `.gitconfig.template` | Source template for `~/.gitconfig` (placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}`) |
| `gitconfig_helper.py` | Cross-platform Python 3 helper backing the git aliases |
| `scripts/windows version/` | PowerShell setup (`install.ps1`, `Initialize-*`, `Update-GitConfig.ps1`, `Functions.ps1`) |
| `scripts/unix/`, `scripts/shared/` | macOS/Linux entry points (one implementation, OS-detecting) + bash library and per-OS layer (`platform.sh`); `scripts/mac version/` and `scripts/linux version/` are thin wrappers |
| `tests/` | Pester tests (unit by default; integration tests are `Tag 'Integration'`, opt-in) |
| `.beads/` | Beads task graph (Dolt-backed); syncs via `refs/dolt/data` |

### Resolved Issues (recent)

| Issue | Description | PR |
|-------|-------------|----|
| [#183](https://github.com/J-MaFf/gitconfig/issues/183) | Mac credential block lacked the empty helper reset line (multi-valued accumulation) | [#184](https://github.com/J-MaFf/gitconfig/pull/184) |
| [#160](https://github.com/J-MaFf/gitconfig/issues/160) | Login task "No Python interpreter found" (WindowsApps alias stub) | [#161](https://github.com/J-MaFf/gitconfig/pull/161) |
| [#163](https://github.com/J-MaFf/gitconfig/issues/163) | Non-ASCII em-dashes failing Encoding tests | [#164](https://github.com/J-MaFf/gitconfig/pull/164) |
| [#165](https://github.com/J-MaFf/gitconfig/issues/165) | `install.ps1` overwrote existing `~/.gitconfig.local` | [#166](https://github.com/J-MaFf/gitconfig/pull/166) |
| [#162](https://github.com/J-MaFf/gitconfig/issues/162) | Tests mutated the real machine config | [#167](https://github.com/J-MaFf/gitconfig/pull/167) |
| [#169](https://github.com/J-MaFf/gitconfig/issues/169) | Regen wiped the `/opt/homebrew` safe.directory entry on shared Macs, breaking `brew update` | [#170](https://github.com/J-MaFf/gitconfig/pull/170) |
| [#171](https://github.com/J-MaFf/gitconfig/issues/171) | Regen reverted mac signing to the agent-based key (Touch ID prompt, hangs unattended) | [#173](https://github.com/J-MaFf/gitconfig/pull/173) |
| [#172](https://github.com/J-MaFf/gitconfig/issues/172) | beads DB stuck on schema v32; upstream migration chain broken (missing `wisps` table) | [#175](https://github.com/J-MaFf/gitconfig/pull/175) |
| [#174](https://github.com/J-MaFf/gitconfig/issues/174) | Helper Pester tests hardcoded `python` and their git fixtures could escape onto the host repo | [#177](https://github.com/J-MaFf/gitconfig/pull/177) |
| [#176](https://github.com/J-MaFf/gitconfig/issues/176) | Windows `Initialize-LocalConfig.ps1` verification test failed on macOS (mixed path separators) | [#178](https://github.com/J-MaFf/gitconfig/pull/178) |
| [#179](https://github.com/J-MaFf/gitconfig/issues/179) | Generated gitconfig applied `credential.helper=osxkeychain` on Linux, breaking HTTPS git auth | [#180](https://github.com/J-MaFf/gitconfig/pull/180) |
| [#186](https://github.com/J-MaFf/gitconfig/issues/186) | Windows-generated config lacked `core.longpaths`; template regen wiped the hand-set global, breaking `bd dolt push` ("Filename too long") | [#187](https://github.com/J-MaFf/gitconfig/pull/187) |
| [#188](https://github.com/J-MaFf/gitconfig/issues/188) | `git skill publish` died on Windows: dispatcher used PowerShell 5.1, which refuses `publish-skill.ps1`'s `#Requires -Version 7` | [#189](https://github.com/J-MaFf/gitconfig/pull/189) |
| [#190](https://github.com/J-MaFf/gitconfig/issues/190) | `git skill sync`/`status` output was confusing: stale `[drift]` log replay contradicted live state, copy-noise, duplicate before/after blocks | [#191](https://github.com/J-MaFf/gitconfig/pull/191) |
| [#181](https://github.com/J-MaFf/gitconfig/issues/181) | Wrong-platform `install.sh` displaced `~/.gitconfig.local` — STEP 0 cleanup ran before the platform guard | [#185](https://github.com/J-MaFf/gitconfig/pull/185) |
| [#182](https://github.com/J-MaFf/gitconfig/issues/182) | Dead mid-test `! grep` bats assertions were silently swallowed; converted to `run ! grep` (position-independent) | [#194](https://github.com/J-MaFf/gitconfig/pull/194) |
| [#195](https://github.com/J-MaFf/gitconfig/issues/195) | `file_owner_uid` tried BSD `stat -f %u` first, returning filesystem garbage on Linux (2 cross-OS bats tests failed); GNU `-c` first now. Dup #193 | [#196](https://github.com/J-MaFf/gitconfig/pull/196) |
| [#197](https://github.com/J-MaFf/gitconfig/issues/197) | Login task still logged "No Python interpreter found" after #161: PS 5.1 drops the empty-string `-c ''` probe arg, rejecting every candidate | [#198](https://github.com/J-MaFf/gitconfig/pull/198) |
| [#199](https://github.com/J-MaFf/gitconfig/issues/199) | Store-only Python installs could never resolve: `Resolve-Python` skipped all 0-byte WindowsApps stubs outright | [#203](https://github.com/J-MaFf/gitconfig/pull/203) |
| [#200](https://github.com/J-MaFf/gitconfig/issues/200) | `install.ps1` STEP 7 re-resolved Python with a weaker first-hit chain instead of reusing `Resolve-Python` | [#204](https://github.com/J-MaFf/gitconfig/pull/204) |
| [#201](https://github.com/J-MaFf/gitconfig/issues/201) | Vacuous `PSParser::Tokenize` parse assertion in `Update-GitConfig.Tests.ps1` could never fail | [#205](https://github.com/J-MaFf/gitconfig/pull/205) |
| [#202](https://github.com/J-MaFf/gitconfig/issues/202) | `Integration.Tests.ps1` invoked bare `python`, bypassing the repo's resolution rule | [#206](https://github.com/J-MaFf/gitconfig/pull/206) |
| [#214](https://github.com/J-MaFf/gitconfig/issues/214) | Adopt shared reusable claude.yml workflow from J-MaFf/.github | [#215](https://github.com/J-MaFf/gitconfig/pull/215) |
| [#248](https://github.com/J-MaFf/gitconfig/issues/248) | `git main` failed in worktrees, fetched the current branch's remote instead of the default branch's, and failed in repos with no remote | [#249](https://github.com/J-MaFf/gitconfig/pull/249) |
| [#250](https://github.com/J-MaFf/gitconfig/issues/250) | Helper ignored unknown arguments, so `git cleanup -h` force-deleted gone branches; per-command allow-lists, `-h` prints usage, unknown flags exit 2 | [#266](https://github.com/J-MaFf/gitconfig/pull/266) |
| [#251](https://github.com/J-MaFf/gitconfig/issues/251) | `git pushf` used a bare `--force-with-lease`, which any background fetch disarms, so it could overwrite a teammate's commit; now adds `--force-if-includes` (git 2.30+) | [#264](https://github.com/J-MaFf/gitconfig/pull/264) |
| [#253](https://github.com/J-MaFf/gitconfig/issues/253) | Backup pruning (newest 5) deleted the only backup of the user's pre-install `~/.gitconfig` (Unix + Windows); the first backup is now also pinned as `<file>.pre-gitconfig`, never pruned | [#267](https://github.com/J-MaFf/gitconfig/pull/267) |
| [#252](https://github.com/J-MaFf/gitconfig/issues/252) | `git start` ignored an existing remote branch, let issues with the same title slug share a branch, and silently branched from `HEAD` | [#265](https://github.com/J-MaFf/gitconfig/pull/265) |
| [#254](https://github.com/J-MaFf/gitconfig/issues/254) | PowerShell Ctrl-G widget never inserted anything: PSReadLine redirects a key handler's native stdout, so `git alias --out` saw no TTY and silently did nothing; now launched via `Start-Process -NoNewWindow`, and `--out` fails loudly without a TTY | [#269](https://github.com/J-MaFf/gitconfig/pull/269) |
| [#268](https://github.com/J-MaFf/gitconfig/issues/268) | More than 5 backups of one file in the same second reused a pruned `<stamp>` name, which sorted as oldest and was pruned at once (Unix + Windows); the next name is now one past the highest taken | [#270](https://github.com/J-MaFf/gitconfig/pull/270) |
| [#260](https://github.com/J-MaFf/gitconfig/issues/260) | `git skill diff` missed staged/untracked drift; a skill-audit failure read as drift (or as "nothing to diff"); `git issues --all --local` printed "No open issues" and exited 0 when every repo failed; `git issues --all --web` dropped `--mine`/`--label` | [#271](https://github.com/J-MaFf/gitconfig/pull/271) |
| [#261](https://github.com/J-MaFf/gitconfig/issues/261) | Helper minor bugs: alias-browser ctrl+left/right swallowed by the search box, clipboard copy could hang on a forking `xclip`/`wl-copy`, detached HEAD labelled `HEAD`, a UTF-8 BOM hid a `SKILL.md` description, and `deps.py`'s Python < 3.11 fallback broke on extras/markers | [#272](https://github.com/J-MaFf/gitconfig/pull/272) |
| [#263](https://github.com/J-MaFf/gitconfig/issues/263) | Docs/config inaccuracies: `git localconfig` with no args exited 129 (now `--edit`), root-anchored `.aws/credentials` ignore (now `**/`), undocumented broad `*.pem`/`*.key`, PS 5.1 `~` clone path, `selfupdate`/`allowed_signers` claim, stale WORKFLOW troubleshooting, AGENTS.md session close | [#273](https://github.com/J-MaFf/gitconfig/pull/273) |
| [#256](https://github.com/J-MaFf/gitconfig/issues/256) | Windows updater logged a failed pip install as `[OK]` (the logger's pipeline output leaked into `Invoke-PipInstall`'s return value), the login task was skipped when the network came up late, and `Initialize-GitConfig.ps1` asked to overwrite an up-to-date `~/.gitconfig` | [#275](https://github.com/J-MaFf/gitconfig/pull/275) |
| [#262](https://github.com/J-MaFf/gitconfig/issues/262) | Tests that never ran or always passed: symlink and elevated-relaunch Pester tests skipped on Windows CI, integration alias tests ran after cleanup and always skipped, helper path regex matched a bare `/gitconfig_helper.py`; now a symlink probe, a stubbable `Test-IsAdministrator`, reordered alias tests that fail instead of skipping, and a full-path assertion | [#274](https://github.com/J-MaFf/gitconfig/pull/274) |
| [#255](https://github.com/J-MaFf/gitconfig/issues/255) | Windows: a failed symlink left `~/.gitignore_global` missing, `allowed_signers` entries could be glued onto one line, cleanup re-encoded the PowerShell profile (dropping its BOM and mangling non-ASCII text), and cleanup's verify step counted a dangling link as removed | [#276](https://github.com/J-MaFf/gitconfig/pull/276) |
| [#259](https://github.com/J-MaFf/gitconfig/issues/259) | Unix scheduler: a `&`/`<` in the repo path wrote a launchd plist that can't parse (still reported "verified") and a `%` broke the cron line; the shared `/tmp/gitconfig-update.log` made the job silently skip once another user owned it; cron matching claimed other clones' and commented-out lines. Now XML-escaped plist + `plutil -lint`, sh/`%`-escaped cron paths, a per-user log under `${XDG_STATE_HOME:-~/.local/state}/gitconfig/`, and only this clone's lines are claimed | [#277](https://github.com/J-MaFf/gitconfig/pull/277) |
| [#257](https://github.com/J-MaFf/gitconfig/issues/257) | Unix `install --force` wiped settings added to `~/.gitconfig.local`, wrote through a foreign `~/.gitconfig` symlink, and widget disable truncated the rc file when the end marker was missing; user settings are now kept, foreign links replaced, and only complete widget blocks removed (after a backup) | [#278](https://github.com/J-MaFf/gitconfig/pull/278) |
| [#258](https://github.com/J-MaFf/gitconfig/issues/258) | Unix `install.sh`/cleanup always exited 0, a prompt at end of input aborted the run silently under `set -e`, an unparsable `~/.gitconfig` exited 128, and `git selfupdate` hid a failed pull in the log; failures now set the exit code, no input reads as "no", and `selfupdate` from a terminal prints progress and fails on a failed pull | [#280](https://github.com/J-MaFf/gitconfig/pull/280) |
| [#281](https://github.com/J-MaFf/gitconfig/issues/281) | Docs lagged the #250–#263 fixes: no Unix exit-code docs, stale WORKFLOW scheduler/local-config advice, a STATUS that still listed merged work as pending and "None" open issues, a duplicate coverage row | [#282](https://github.com/J-MaFf/gitconfig/pull/282) |
| [#245](https://github.com/J-MaFf/gitconfig/issues/245) | Integration tests looked up a scheduled task named `Update-GitConfig`, which no script creates, so the create test always skipped and the cleanup test always passed; the name is now read from `Register-LoginTask.ps1` and a missing task after setup fails | [#284](https://github.com/J-MaFf/gitconfig/pull/284) |
| [#239](https://github.com/J-MaFf/gitconfig/issues/239) | Helper printed external text (gh stderr, paths, repo/branch names, alias bodies, exception text) as rich markup: `[/]` crashed it, `[slug]`/`[rejected]` vanished; now escaped, with `_print_ext()` for whole lines | [#285](https://github.com/J-MaFf/gitconfig/pull/285) |
| [#241](https://github.com/J-MaFf/gitconfig/issues/241) | `git main --all` swept the clone's parent folder, which is the home folder for a `~/gitconfig` clone (or its parent via the install symlink); root now from `gitconfig.scriptsRoot`, realpath-derived, and $HOME / its parent / `/` refused without `--force` | [#287](https://github.com/J-MaFf/gitconfig/pull/287) |
| [#240](https://github.com/J-MaFf/gitconfig/issues/240) | Windows `install.ps1` printed `Setup Complete!` and exited 0 after failed steps, the elevated relaunch lost the exit code, `Initialize-Symlinks.ps1` asked about the task even with `-NoTask` and `-Reinstall -NoTask` deleted it, and elevating with another account's password set up the administrator's profile and task; now failures exit 1, `-KeepTask`, and the invoking account is configured | [#288](https://github.com/J-MaFf/gitconfig/pull/288) |
| [#234](https://github.com/J-MaFf/gitconfig/issues/234) | macOS: the bash Ctrl-G widget bound but did nothing under `/bin/bash` 3.2, the scheduler used the deprecated `launchctl load`/`unload`, and the `RunAtLoad` sync ran the same pip install as the installer's STEP 6; now the widget binds only under bash 4+ (with a note), `bootstrap`/`bootout` are used, and a per-user lock keeps to one sync at a time | PRLINK |

### Open Issues

From an earlier review; none are being worked on.

| Issue | Description |
|-------|-------------|
| [#230](https://github.com/J-MaFf/gitconfig/issues/230) | Windows: Ctrl-G only installed for one PowerShell edition; PS 5.1 encoding and log quirks |
| [#231](https://github.com/J-MaFf/gitconfig/issues/231) | Template: dedupe the Python-finder alias loop (quote the repo path) and move machine-specific settings out |
| [#232](https://github.com/J-MaFf/gitconfig/issues/232) | gitconfig_helper.py cleanups: batch skill git log, share audit command, fix stale 'git update' message |
| [#233](https://github.com/J-MaFf/gitconfig/issues/233) | Replace source-text tests with behavioural tests in a sandboxed HOME |
| [#235](https://github.com/J-MaFf/gitconfig/issues/235) | Stop hardcoding machine-specific values in .gitconfig.local generation |
| [#246](https://github.com/J-MaFf/gitconfig/issues/246) | Add a systemd user timer backend to the Unix scheduler |

## Natural Next Steps

- On every other machine with this repo: upgrade `bd` to ≥ 1.1.0, delete the stale `.beads/embeddeddolt/`, and run `bd bootstrap` — the shared graph was re-created fresh ([#172](https://github.com/J-MaFf/gitconfig/issues/172)), so v32-era clones cannot sync until they re-bootstrap.
- On each additional machine, run `bd setup claude` (the SessionStart/PreCompact hooks live in the gitignored `.claude/settings.json`) and `bd bootstrap` to hydrate the Dolt graph.
- Consider a small cleanup of `Integration.Tests.ps1` assertions that check `.gitconfig.local` for `[commit]`/`[user]` keys that actually live in `.gitconfig`.
- Check the Ctrl-G widget by hand on Windows under pwsh 7 and Windows PowerShell 5.1 ([#269](https://github.com/J-MaFf/gitconfig/pull/269)); CI can't drive PSReadLine.
- Known gaps left by the bug-fix wave, not yet filed: `install.sh --reinstall` removes `~/.gitconfig.local` before regenerating, so it doesn't carry your settings over the way `--force` does; `install.ps1` STEP 6b still writes with `Add-Content`'s default encoding.

## Prerequisites to Run

- **Windows:** Git for Windows, PowerShell 7+, Python 3 (PyManager or python.org); run `scripts/windows version/install.ps1` (elevates for symlinks + scheduled task).
- **macOS/Linux:** bash, Python 3, and cron on Linux for the auto-update job; run `bash scripts/unix/install.sh` (`--force` for unattended runs; it exits 1 if a step fails).
- **Tests:** Pester 5+; `tests/run-tests.ps1` (add `-IncludeIntegration` only on a throwaway machine/VM). bats-core + pytest for `tests/shared/`. CI (`.github/workflows/test.yml`) runs all of them on Windows (pwsh 7 and 5.1, plus the integration tests), Linux and macOS for every PR.
- **Beads:** `bd` CLI; `bd bootstrap` on a fresh clone, then `bd dolt pull` / `bd dolt push` to sync.
