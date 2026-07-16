# Project Status

## What This Is

A cross-platform tool that generates a portable `~/.gitconfig` from a version-controlled template (`.gitconfig.template`), layers machine-specific overrides via `~/.gitconfig.local`, and keeps it converged on Windows through a login scheduled task. Helper logic (`gitconfig_helper.py`) backs the custom git aliases. Windows setup is PowerShell + Pester; macOS/Linux are bash.

## Current State — 2026-07-16

Healthy; `main` is clean. [#208](https://github.com/J-MaFf/gitconfig/issues/208) (`git skill diff` subcommand — shows the full diff of drifted skill(s) in `~/.claude/skills`, so you can review changes before publishing) is implemented and awaiting PR review/merge.

Four follow-up fixes from the #198 adversarial review landed: [#203](https://github.com/J-MaFf/gitconfig/pull/203) makes `Resolve-Python` probe WindowsApps stubs as a last resort (Store-only Python installs can now resolve) and hardens the probe against a candidate that throws instead of failing cleanly; [#204](https://github.com/J-MaFf/gitconfig/pull/204) makes `install.ps1` STEP 7 reuse `Resolve-Python` instead of a weaker duplicate resolution chain; [#205](https://github.com/J-MaFf/gitconfig/pull/205) and [#206](https://github.com/J-MaFf/gitconfig/pull/206) fix a vacuous parse-validity test and a bare-`python` invocation, both in the Pester suite itself. [#198](https://github.com/J-MaFf/gitconfig/pull/198) fixed the login task's persistent "No Python interpreter found" warning — the real root cause behind #160/#161: Windows PowerShell 5.1 drops empty-string args to native commands, so the `-c ''` interpreter probe ran as `py -c` and rejected every candidate; the probe is now `-c 'pass'` with a regression suite (`tests/Functions.Tests.ps1`). [#185](https://github.com/J-MaFf/gitconfig/pull/185) landed the wrong-platform `install.sh` guard (STEP 0 no longer displaces `~/.gitconfig.local` before the OS check); [#194](https://github.com/J-MaFf/gitconfig/pull/194) hardens the shared bats suites by converting every negated-`grep` assertion to `run ! grep` (dead mid-test `! grep` checks were silently swallowed). Latest unit-suite run on the Windows work PC (2026-07-15) was green (Pester 209 pass / 0 fail / 18 integration excluded); last full macOS run (2026-07-05) was also green (Pester 185 pass / 0 fail / 13 skip; bats 31/31);
[#186](https://github.com/J-MaFf/gitconfig/issues/186) bakes `core.longpaths = true` into the Windows-generated `~/.gitconfig.local` — template regeneration had silently wiped the hand-set global copy, breaking beads' `bd dolt push` with "Filename too long";
[#188](https://github.com/J-MaFf/gitconfig/issues/188) fixes `git skill publish` on Windows — the dispatcher launched wrapper scripts with Windows PowerShell 5.1, which refuses `publish-skill.ps1`'s `#Requires -Version 7`; it now prefers pwsh;
[#190](https://github.com/J-MaFf/gitconfig/issues/190) re-renders `git skill sync`/`status` in Python with rich — live drift only (no stale log replay), colored counts, one state block, actionable pull-failure hints; [#180](https://github.com/J-MaFf/gitconfig/pull/180) grows the bats suites to 41 tests (new Linux local-config suite + mac guard test — validated on Linux via a plain-bash sandbox replay; rerun `bats tests/shared/` on the Mac to reconfirm). Recent work: the mac credential block gained the same reset-line hardening as Linux ([#183](https://github.com/J-MaFf/gitconfig/issues/183)), Linux now gets a proper HTTPS credential helper and the platform scripts refuse cross-OS runs ([#179](https://github.com/J-MaFf/gitconfig/issues/179)), the mac `initialize-local-config.sh` regen-wipe bugs are fixed (Homebrew safe.directory, file-based signing), beads runs on bd 1.1.0's native schema after a fresh re-init ([#172](https://github.com/J-MaFf/gitconfig/issues/172)), and the Pester helper suite is sandbox-safe on macOS ([#174](https://github.com/J-MaFf/gitconfig/issues/174)).

### Components

| Path | Description |
|------|-------------|
| `.gitconfig.template` | Source template for `~/.gitconfig` (placeholders: `{{REPO_PATH}}`, `{{HOME_DIR}}`) |
| `gitconfig_helper.py` | Cross-platform Python 3 helper backing the git aliases |
| `scripts/windows version/` | PowerShell setup (`install.ps1`, `Initialize-*`, `Update-GitConfig.ps1`, `Functions.ps1`) |
| `scripts/shared/`, `scripts/mac version/`, `scripts/linux version/` | bash library + macOS/Linux entry points |
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

### Open Issues

None.

## Natural Next Steps

- On every other machine with this repo: upgrade `bd` to ≥ 1.1.0, delete the stale `.beads/embeddeddolt/`, and run `bd bootstrap` — the shared graph was re-created fresh ([#172](https://github.com/J-MaFf/gitconfig/issues/172)), so v32-era clones cannot sync until they re-bootstrap.
- On each additional machine, run `bd setup claude` (the SessionStart/PreCompact hooks live in the gitignored `.claude/settings.json`) and `bd bootstrap` to hydrate the Dolt graph.
- Consider a small cleanup of `Integration.Tests.ps1` assertions that check `.gitconfig.local` for `[commit]`/`[user]` keys that actually live in `.gitconfig`.

## Prerequisites to Run

- **Windows:** Git for Windows, PowerShell 7+, Python 3 (PyManager or python.org); run `scripts/windows version/install.ps1` (elevates for symlinks + scheduled task).
- **Tests:** Pester 5+; `tests/run-tests.ps1` (add `-IncludeIntegration` only on a throwaway machine/VM).
- **Beads:** `bd` CLI; `bd bootstrap` on a fresh clone, then `bd dolt pull` / `bd dolt push` to sync.
