# gitconfig — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Git Workflow

Use the **git-policies** skill for all git and GitHub work in this repo: issue-first workflow, branch naming, signed commits, PR conventions, squash & merge, and branch cleanup.

Invoke it at the start of any session that involves git: `/git-policies`

---

## Platform

This repo targets **macOS, Linux, and Windows** — it's a cross-platform dotfiles/git-config tool.

- **Windows scripts:** PowerShell (`scripts/`), tested with Pester (`tests/`)
- **macOS/Linux scripts:** bash (`scripts/mac version/`, `scripts/linux version/`)
- `gitconfig_helper.py` is cross-platform Python 3
- Always confirm which platform a change targets before editing

---

## Key Files

| File | Purpose |
|------|---------|
| `gitconfig_helper.py` | Cross-platform helper — Python 3 |
| `scripts/windows version/Setup-GitConfig.ps1` | Windows setup entrypoint |
| `scripts/shared/` | Shared bash library and scripts (mac + linux) |
| `scripts/mac version/` | macOS bash entry points |
| `scripts/linux version/` | Linux bash entry points |
| `tests/` | Pester tests for Windows scripts |

---

## Testing

- Windows: Pester (`tests/run-tests.ps1`)
- macOS/Linux: no formal test runner — validate manually or with bash assertions
- Integration tests live in `tests/Integration.Tests.ps1` — these require a real machine or VM, not a mock environment
