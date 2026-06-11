# gitconfig — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

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
| `scripts/Setup-GitConfig.ps1` | Windows setup entrypoint |
| `scripts/mac version/` | macOS bash setup scripts |
| `scripts/linux version/` | Linux bash setup scripts |
| `config/` | Shared git config templates |
| `tests/` | Pester tests for Windows scripts |

---

## Testing

- Windows: Pester (`tests/run-tests.ps1`)
- macOS/Linux: no formal test runner — validate manually or with bash assertions
- Integration tests live in `tests/Integration.Tests.ps1` — these require a real machine or VM, not a mock environment
