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
| `scripts/windows version/install.ps1` | Windows setup entrypoint |
| `scripts/shared/` | Shared bash library and scripts (mac + linux) |
| `scripts/mac version/` | macOS bash entry points |
| `scripts/linux version/` | Linux bash entry points |
| `tests/` | Pester tests for Windows scripts |

---

## Testing

- Windows: Pester (`tests/run-tests.ps1`)
- macOS/Linux: no formal test runner — validate manually or with bash assertions
- Integration tests live in `tests/Integration.Tests.ps1` — these require a real machine or VM, not a mock environment


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for durable, cross-session task tracking in this repo — not ad-hoc markdown TODO lists. The **GitHub Issue stays the shippable unit**; bd is the execution/memory layer beneath it.
- Run `bd prime` for detailed command reference and the session-close protocol
- Use `bd remember` for **repo-scoped** knowledge that should travel with this repo; the global `~/.claude` memory (and `MEMORY.md`) remains the home for cross-repo / user-level context

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on the git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Close (reconciled with the git-policies skill)

> This section overrides bd's default "auto-push to main" wording to match this
> project's git workflow. **Merges to `main` stay human-gated via PR — never
> auto-push or auto-merge to `main`.**

When ending a work session:

1. **File issues for remaining work** — `bd create` for fine-grained follow-ups; open a GitHub issue for anything shippable
2. **Run quality gates** (if code changed) — tests, linters, builds
3. **Update issue status** — `bd close` finished work, update in-progress items
4. **Make work durable WITHOUT merging:**
   ```bash
   git commit -S ...                    # signed, on the FEATURE branch
   git push -u origin <feature-branch>  # push the branch, never main
   bd dolt push                         # sync the bead graph (refs/dolt/data)
   ```
5. **Open/update the PR** (`Fixes #N`) and **stop at the merge gate** — a human approves the squash-merge
6. **Clean up** — clear stashes, prune merged branches (`git cleanup`)

Note: editing this block makes `bd setup claude --check` report it as "stale" — that is expected; do **not** run `bd setup claude` to clear it (doing so reverts this reconciliation).
<!-- END BEADS INTEGRATION -->
