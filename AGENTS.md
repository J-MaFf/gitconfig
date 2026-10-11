# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Testing This Repo

See `CLAUDE.md` for the layout. Before a PR, run the suites that cover what you changed:

```bash
python3 -m pytest tests/shared -q        # gitconfig_helper.py, deps.py
bats tests/shared                         # bash scripts (scripts/unix, scripts/shared)
pwsh tests/run-tests.ps1                  # Windows scripts; skips the Integration tag unless -IncludeIntegration
```

The suites sandbox `HOME`, git config, `crontab`, `launchctl` and `systemctl`. Don't run the install, cleanup or update scripts against your real home directory, and run `tests/Integration.Tests.ps1` only on a throwaway machine or VM.

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
