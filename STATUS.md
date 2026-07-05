# Project Status

## What This Is

A cross-platform tool that generates a portable `~/.gitconfig` from a version-controlled template (`.gitconfig.template`), layers machine-specific overrides via `~/.gitconfig.local`, and keeps it converged on Windows through a login scheduled task. Helper logic (`gitconfig_helper.py`) backs the custom git aliases. Windows setup is PowerShell + Pester; macOS/Linux are bash.

## Current State — 2026-07-05

Healthy; `main` is clean. The mac `initialize-local-config.sh` regen-wipe bugs (Homebrew safe.directory, file-based signing) are fixed; beads sync is blocked on the Mac clone pending a schema-migration decision ([#172](https://github.com/J-MaFf/gitconfig/issues/172)).

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
| [#160](https://github.com/J-MaFf/gitconfig/issues/160) | Login task "No Python interpreter found" (WindowsApps alias stub) | [#161](https://github.com/J-MaFf/gitconfig/pull/161) |
| [#163](https://github.com/J-MaFf/gitconfig/issues/163) | Non-ASCII em-dashes failing Encoding tests | [#164](https://github.com/J-MaFf/gitconfig/pull/164) |
| [#165](https://github.com/J-MaFf/gitconfig/issues/165) | `install.ps1` overwrote existing `~/.gitconfig.local` | [#166](https://github.com/J-MaFf/gitconfig/pull/166) |
| [#162](https://github.com/J-MaFf/gitconfig/issues/162) | Tests mutated the real machine config | [#167](https://github.com/J-MaFf/gitconfig/pull/167) |
| [#169](https://github.com/J-MaFf/gitconfig/issues/169) | Regen wiped the `/opt/homebrew` safe.directory entry on shared Macs, breaking `brew update` | [#170](https://github.com/J-MaFf/gitconfig/pull/170) |
| [#171](https://github.com/J-MaFf/gitconfig/issues/171) | Regen reverted mac signing to the agent-based key (Touch ID prompt, hangs unattended) | [#173](https://github.com/J-MaFf/gitconfig/pull/173) |

### Open Issues

- [#172](https://github.com/J-MaFf/gitconfig/issues/172) — beads Dolt DB on schema v32 blocks bd 1.1.0 clones (Mac); a single designated machine must migrate, then other clones re-bootstrap.

## Natural Next Steps

- Resolve [#172](https://github.com/J-MaFf/gitconfig/issues/172): pick the designated migrator machine, `BD_ALLOW_REMOTE_MIGRATE=1 bd migrate && bd dolt push` there, `bd bootstrap` elsewhere; align bd versions across machines.
- On each additional machine, run `bd setup claude` (the SessionStart/PreCompact hooks live in the gitignored `.claude/settings.json`) and `bd bootstrap` to hydrate the Dolt graph.
- Consider a small cleanup of `Integration.Tests.ps1` assertions that check `.gitconfig.local` for `[commit]`/`[user]` keys that actually live in `.gitconfig`.

## Prerequisites to Run

- **Windows:** Git for Windows, PowerShell 7+, Python 3 (PyManager or python.org); run `scripts/windows version/install.ps1` (elevates for symlinks + scheduled task).
- **Tests:** Pester 5+; `tests/run-tests.ps1` (add `-IncludeIntegration` only on a throwaway machine/VM).
- **Beads:** `bd` CLI; `bd bootstrap` on a fresh clone, then `bd dolt pull` / `bd dolt push` to sync.
