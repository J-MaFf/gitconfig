# Spec: `git issues` alias — list open GitHub issues

## Goal

Add a `git issues` alias to the gitconfig template that lists open GitHub issues for the
current repo by default, and across all of the user's GitHub repos with `--all`. As part of
the same change, retarget the existing `git main --all` scan from the current working
directory to the same derived Scripts root, so both aliases share one repo-discovery rule.

## Context

- This repo ([.gitconfig.template](../.gitconfig.template)) defines git aliases; complex ones
  dispatch to [gitconfig_helper.py](../gitconfig_helper.py) through a shell function that
  probes Python interpreters in the order `py` → `python3` → `python` (see the existing
  `alias`, `cleanup`, `main`, `start`, `skill` lines, e.g. template line 43). New helper-backed
  aliases MUST reuse that exact pattern — the probe order is enforced by
  [tests/GitconfigTemplate.Tests.ps1](../tests/GitconfigTemplate.Tests.ps1), and each probe
  must use a non-empty `-c` argument (`-c 'pass'`-style is not used here; the template uses
  `-c ''` guarded by pwsh — follow the template's existing probe string verbatim).
- `gitconfig_helper.py` conventions (verified by reading the file):
  - Subcommand dispatch happens in the `__main__` block (line ~1495): `sys.argv[1]` selects a
    function; flags are checked with `in sys.argv` (no argparse).
  - Output uses `rich` (`Console`, `Table`); errors print in `[red]` and return exit code 1.
  - `start_branch()` (line ~846) is the model for GitHub CLI usage: check `_have("gh")`,
    run `gh ... --json ...`, parse with `json.loads`, print `[red]` errors on failure.
  - `update_all_main()` (line ~1061) is the model for scanning immediate subdirectories for
    git repos (`os.scandir(".")`, `.git` entry may be a dir or file).
  - New aliases must be registered in `ALIAS_METADATA` (line ~197) so `git alias` lists them.
- Existing GitHub-category aliases: `pr` (`gh pr view --web`), `prs` (`gh pr status`).
- Decisions already made with the user (do not re-litigate):
  - `--all` queries GitHub account-wide (all repos owned by the authenticated user), NOT the
    on-disk subdirectory scan. A separate `--local` modifier restricts `--all` to git repos on
    disk under the user's Scripts directory (see next bullet), regardless of the current
    working directory.
  - The Scripts root is `~/Documents/Scripts` on every supported OS (verified: the install
    scripts assume `~/Documents/Scripts/gitconfig` — `scripts/shared/update-gitconfig.sh:6`,
    both `initialize-local-config.sh` files). Since `gitconfig_helper.py` lives inside
    `<ScriptsRoot>/gitconfig/`, the helper derives the root as the parent of its own repo
    directory: `os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`. No hardcoded
    path, no per-OS branching, and it self-adapts if the repo is cloned elsewhere.
  - Supported flags: `--all`/`-a`, `--local`, `--web`/`-w`, `--mine`/`-m`, `--label <name>`/`-l <name>`.
    No `--limit` flag; use a fixed cap.
  - GitHub issues only — no beads/bd integration.
  - `git main --all` (`update_all_main()`, line ~1061) currently scans `os.scandir(".")` —
    the current working directory. Per the user's decision it must be changed to scan the
    derived Scripts root instead, sharing the discovery logic with `git issues --all --local`.

## Deliverable

Edits to four existing files (no new files except this spec):

1. `.gitconfig.template` — new `issues` alias in the `[alias]` section under the
   `# --- GitHub ---` group, with a comment block matching the style of neighboring aliases.
2. `gitconfig_helper.py` — new `issues(args)` function (or equivalently named), dispatch wiring
   in `__main__`, an `ALIAS_METADATA` entry, a shared Scripts-root/repo-discovery helper, and
   `update_all_main()` retargeted to that helper (including updated docstring, `main`'s
   `ALIAS_METADATA` description, and the `main` alias's template comment).
3. `tests/GitconfigTemplate.Tests.ps1` — `issues` added to the `$pythonAliases` list.
4. `CHANGELOG.md` — entry describing the new alias.
4b. `tests/gitconfig_helper.Tests.ps1` — the existing `update_all_main` fixture tests must be
   adapted to the Scripts-root retarget (R11): they must exercise the sweep against a
   sandboxed fixture tree (e.g. by running a copy of the helper placed inside it), never
   against the developer's real Scripts repos, and must pass.
5. `~/.claude/skills/git-policies/SKILL.md` (in the claude-skills store, outside this repo) —
   reference the new `git issues` alias in the issue-first workflow section (near the
   `gh issue create` example at line ~21) as the way to list open issues before picking work.
   Verified: the skill currently references only the `git cleanup` and `git branches` aliases
   (Branch Cleanup section, lines ~204–215) and never mentions `git main`, so no existing
   text needs correcting for the `--all` scope change — this is purely an addition.

## Requirements

- R1. `.gitconfig.template` defines `issues` exactly once, dispatching to
  `gitconfig_helper.py issues "$@"` using the same `py` → `python3` → `python` probe string as
  the existing `skill` alias (byte-identical except for the subcommand name).
  [verify: diff the `issues` line against the `skill` line; run
  `tests/run-tests.ps1` — the GitconfigTemplate suite must pass with `issues` in `$pythonAliases`]
- R2. `git issues` (no flags) run inside a git repo with a GitHub remote lists that repo's
  open issues via `gh issue list --json number,title,labels,updatedAt --limit 50`, rendered as
  a rich table with columns: number, title, labels (comma-joined names), and updated age.
  Exit code 0 on success.
  [verify: run in this repo; table shows the same issue numbers as `gh issue list`]
- R3. `git issues --all` (or `-a`) lists open issues across all GitHub repos owned by the
  authenticated user: resolve the login via `gh api user --jq .login`, then query
  `gh search issues --owner <login> --state open --json number,title,labels,updatedAt,repository --limit 50`.
  The rich table gains a leading "repo" column (repository name). Works from any directory
  (no git-repo requirement in this mode).
  [verify: run from a non-repo directory; output includes issues from more than one repo when
  such issues exist, matching `gh search issues --owner <login> --state open`]
- R4. `git issues --all --local` restricts the listing to git repos found in immediate
  subdirectories of the Scripts root — the parent directory of the repo containing
  `gitconfig_helper.py` (`os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`),
  which resolves to `~/Documents/Scripts` on a standard install on any OS. The current
  working directory is irrelevant. Discovery uses the same rule as `update_all_main()`:
  entry is a dir and contains a `.git` dir-or-file. For each such repo that has a GitHub
  remote, its open issues are fetched per R2's query and shown in one combined table with a
  "repo" column. Subdirectory repos without a GitHub remote or where `gh` fails are skipped
  with a `[yellow]` note, not a fatal error.
  [verify: run from a directory OUTSIDE the Scripts tree; output still lists issues from the
  Scripts-root repos and only those]
- R5. `--mine` (or `-m`) filters to issues assigned to the authenticated user: per-repo modes
  add `--assignee @me` to `gh issue list`; account-wide mode adds `--assignee <login>` to
  `gh search issues`. Composable with `--all` and `--label`.
  [verify: `git issues -m` output is the subset of `git issues` output assigned to the user]
- R6. `--label <name>` (or `-l <name>`) filters by label, passed through as `--label <name>`
  to the underlying `gh` command in every mode. The flag takes exactly one value; a missing
  value prints a `[red]` usage error and exits 1.
  [verify: `git issues -l bug` shows only bug-labeled issues; `git issues -l` exits 1 with a
  usage message]
- R7. `--web` (or `-w`) opens the browser instead of printing a table: repo mode runs
  `gh issue list --web`; `--all` mode opens
  `https://github.com/issues?q=is:open+is:issue+user:<login>` via `gh browse` or
  `webbrowser.open`. `--web` combined with `--local` is a `[red]` usage error, exit 1.
  [verify: each mode opens the expected page; `git issues --all --local --web` exits 1]
- R8. Error handling, mirroring `start_branch()`:
  (a) `gh` not installed → `[red]` message naming gh, exit 1;
  (b) no-flag mode outside a git repo → `[red]Error: Not in a git repository[/red]`, exit 1;
  (c) repo has no GitHub remote / `gh` command fails in single-repo mode → the `gh` stderr is
  surfaced in `[red]`, exit 1;
  (d) `--local` without `--all` → `[red]` usage error, exit 1;
  (e) zero matching issues in any mode → a `[green]`/plain "No open issues" message, exit 0.
  [verify: simulate each case (e.g. run outside a repo, unset PATH entry for gh in a subshell)
  and check message + exit code]
- R9. `ALIAS_METADATA` gains an `"issues"` entry in the `GitHub` category whose description
  mentions the `--all` account-wide mode, and the template comment above the alias documents
  the default, `--all`, `--local`, `--mine`, `--label`, and `--web` behaviors in ≤6 comment lines.
  [verify: `git alias --plain` lists `issues` under GitHub; read the template comment]
- R10. All flag parsing follows the file's existing `in sys.argv` / positional style — no
  argparse import — and the helper remains a single self-contained script with `rich` as its
  only third-party dependency.
  [verify: `git diff` shows no new imports beyond stdlib; grep confirms no `argparse`]
- R11. Repo discovery is factored into one shared helper function that returns the derived
  Scripts root and/or the list of git-repo subdirectory names under it, and BOTH
  `git issues --all --local` and `update_all_main()` (`git main --all`) call it.
  `update_all_main()` no longer scans the current working directory: it scans the Scripts
  root regardless of where the command runs, and its docstring, the `"main"` entry in
  `ALIAS_METADATA`, and the `main` alias's comment in `.gitconfig.template` are updated to
  say so. All other `git main --all` behavior (dirty-repo triage, per-repo headers, summary
  table, exit codes) is unchanged.
  [verify: run `git main --all` from a directory outside the Scripts tree — it processes the
  Scripts-root repos; grep confirms `update_all_main` and the issues code path call the same
  discovery function and `os.scandir(".")` no longer appears in either]
- R12. `~/.claude/skills/git-policies/SKILL.md` documents `git issues` in the issue-first
  workflow section: a short mention (≤4 lines, matching the skill's existing style of alias
  references) that `git issues` lists the current repo's open issues and `git issues --all`
  lists them account-wide, placed near the `gh issue create` example. Editing the file is in
  scope; publishing it (the `git skill publish` PR flow in the claude-skills repo) is NOT —
  the edit is left for the user to publish.
  [verify: grep SKILL.md for `git issues`; the mention appears once, in the issue-first
  section, and no other part of the skill was reworded]

## Out of scope

- Beads/bd issue integration (bd has its own commands).
- A `--limit`/`-n` flag, pagination, or interactive browsing (no Ctrl-G browser like `git alias`).
- Closed-issue or state filtering (`--state`, `--closed`).
- Issue creation, editing, or claiming — listing only.
- Caching, parallel fetching, or performance tuning of the `--all --local` scan.
- A configurable Scripts-root override (e.g. an `issues.localRoot` git config key) — the
  derived root is the single source of truth.
- Changes to the bash/mac/linux install scripts (the template is shared; no per-OS work needed).
- Updating `STATUS.md` or docs beyond the CHANGELOG entry.

## Constraints

- Cross-platform: the helper must behave identically on Windows (Python via `py`), macOS, and
  Linux; no OS-specific paths or shell calls inside the new function (use `subprocess` with
  list argv, as the file already does).
- `gh` invocations must use `--json` + `json.loads`, never scrape human-readable output.
- Follow repo git workflow (git-policies skill): GitHub issue first, `feat/git-issues-alias`
  branch, signed commits, PR with `Fixes #N`, squash & merge. The generator loop produces the
  code; committing/PR happens outside the loop per the repo's human-gated merge policy.
- Table styling must match existing rich tables in the file (e.g. `_print_aliases_table`,
  cleanup's table): `Table` with headed columns, no custom themes.
- Pester suite (`tests/run-tests.ps1`) must pass on Windows; unit tests must not require
  network or a live `gh` login (template/regex assertions only — do not add tests that call gh).

## Acceptance rubric

- C1 (R1): PASS iff `issues` appears exactly once in `.gitconfig.template`, its probe string
  matches the `skill` alias byte-for-byte apart from the subcommand name, and the Pester
  GitconfigTemplate suite passes with `issues` in `$pythonAliases`.
- C2 (R2): PASS iff `git issues` in a GitHub-remoted repo prints a rich table whose issue
  numbers equal `gh issue list --state open --limit 50`'s, with columns repo-number/title/labels/updated,
  and exits 0.
- C3 (R3): PASS iff `git issues --all` from a non-repo directory resolves the login via
  `gh api user`, queries `gh search issues --owner <login> --state open`, shows a repo column,
  and exits 0.
- C4 (R4): PASS iff `git issues --all --local`, run from a directory outside the Scripts
  tree, lists issues only for GitHub-remoted git repos in immediate subdirectories of the
  helper's derived Scripts root (`__file__`'s grandparent directory), skipping non-GitHub
  repos with a yellow note and no fatal error.
- C5 (R5): PASS iff `--mine`/`-m` maps to `--assignee @me` (repo modes) or `--assignee <login>`
  (search mode) and composes with `--all` and `--label`.
- C6 (R6): PASS iff `--label X`/`-l X` passes `--label X` to gh in all three modes, and a
  missing value yields a red usage error with exit 1.
- C7 (R7): PASS iff `--web` opens `gh issue list --web` in repo mode and the account-wide
  issues URL in `--all` mode, and `--web` + `--local` exits 1 with a usage error.
- C8 (R8): PASS iff each of the five error/empty cases (missing gh; outside repo; gh failure;
  `--local` without `--all`; zero issues) produces exactly the specified message style and
  exit code.
- C9 (R9): PASS iff `git alias --plain` lists `issues` in the GitHub category and the template
  comment block documents all five flags in at most six comment lines.
- C10 (R10): PASS iff the diff adds no third-party or argparse imports and flag handling
  matches the file's existing style.
- C11 (deliverable 4): PASS iff `CHANGELOG.md` gains an entry covering both the new alias and
  the `git main --all` retargeting, following the file's existing entry format.
- C12 (R11): PASS iff one shared discovery function is called by both `update_all_main()` and
  the `--all --local` path, `git main --all` run from outside the Scripts tree processes the
  Scripts-root repos with its prior triage/summary behavior intact, and the `main` docstring,
  metadata description, and template comment all describe the new scope.
- C13 (R12): PASS iff the git-policies SKILL.md's issue-first section mentions `git issues`
  (repo-scoped) and `git issues --all` (account-wide) in ≤4 lines, with no other sections of
  the skill modified and no publish performed.
- C-final: PASS iff a maintainer of this repo reviewing the diff would accept it without
  substantive changes.

## Open questions

(none)
