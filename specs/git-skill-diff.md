# Spec: `git skill diff` subcommand

## Goal
Add a `git skill diff` subcommand that shows which installed Claude skill(s) in
`~/.claude/skills` have drifted (uncommitted local edits to an already-published
skill) and prints the actual diff content for each, so the user can decide
whether to run `git skill publish`.

## Context
- `git skill <subcommand>` is a git alias (`alias.skill` in
  `C:/Users/jmaffiola/Documents/Scripts/gitconfig/.gitconfig`, or wherever the
  repo's shared gitconfig template defines it) that execs
  `gitconfig_helper.py skill "$@"`. All subcommand logic for `list`, `sync`,
  `status`, and `publish` lives in
  [gitconfig_helper.py](../gitconfig_helper.py), specifically:
  - `SKILL_USAGE` (~line 429) — the no-arg/`help` banner listing subcommands.
  - `SKILL_SCRIPTS` (~line 422) — maps subcommand → claude-skills wrapper
    script base name, for subcommands that delegate to the sibling
    `claude-skills` repo (`~/.claude/skills/scripts/*.ps1` / `*.sh`).
  - `skill(args)` (~line 673) — the dispatcher; validates the subcommand,
    calls `_require_skills_dir()`, then routes to `list_skills()`,
    `_skill_sync_or_status()`, or `_run_skill_script()`.
  - `_audit_summary(no_fetch)` (~line 515) and `_render_skill_state()`
    (~line 558) — the existing pattern for shelling out to
    `~/.claude/skills/scripts/skill-audit.{ps1,sh}` and rendering its output
    with `rich`. `skill-audit` is documented in that repo as "the single
    source of truth for local skill state" — this spec reuses it rather than
    reimplementing drift classification in `gitconfig_helper.py`.
  - `SKILLS_DIR` (~line 353) = `~/.claude/skills`, a **separate** git repo
    (github.com/J-MaFf/claude-skills) that this helper only provides a UX
    layer on top of.
- Drift, per `skill-audit.ps1`/`.sh` (in the claude-skills repo, read-only
  from this repo's perspective), means: a top-level skill directory that (a)
  has a `SKILL.md` with frontmatter `name:` matching its folder name, (b) is
  already tracked by git (has been published before), and (c) has
  `git status --porcelain -- <dir>` output (uncommitted local edits). This is
  exactly the "drifted" count shown today by `git skill status`
  (`skill-audit.ps1 -Summary -Strict`), e.g. "Skills: 9 aligned, 1 drifted".
- `skill-audit.ps1`/`.sh`, run **without** `-Summary`, prints a full sectioned
  report including a section formatted as:
  ```
  [!] Drifted (N)
     - <skill-dir-name> - uncommitted local edits
  ```
  (see `skill-audit.ps1` lines ~140-157, `Write-Section`). This is the only
  existing way to get the list of drifted skill directory names — there is no
  `-Json` or machine-readable flag today, and adding one is out of scope (see
  below).
- Existing subcommands print raw subprocess output line-by-line through
  `rich`'s `Console`, escaping each line with `escape()` before printing (see
  `skill_sync()` ~line 620) to avoid `rich` misinterpreting `[...]` sequences
  in diff/git output as markup.
- Tests for this dispatcher live in
  `tests/gitconfig_helper.Tests.ps1` and are **static regex checks against
  the Python source** (they assert function names, dispatch wiring, and
  string literals exist in `gitconfig_helper.py`) — they do not execute the
  Python helper live. See the `"skill aliases"` Context block (~line 199) for
  the existing pattern.

## Deliverable
- Modified [gitconfig_helper.py](../gitconfig_helper.py):
  - New function `skill_diff(args)` implementing the subcommand (see
    Requirements).
  - `SKILL_USAGE` updated to document `diff`.
  - `skill(args)` updated to route `diff` to `skill_diff`.
- New or extended Pester test coverage in
  `tests/gitconfig_helper.Tests.ps1` (static source-regex style, matching the
  existing `"skill aliases"` Context block's conventions) asserting the new
  function, usage text, and dispatch wiring exist.
- No changes to any file under `~/.claude/skills` (that's the separate
  claude-skills repo) — this subcommand only *reads* from it via
  `skill-audit`.

## Requirements
- R1. `git skill diff` (no args) prints, for **every** currently drifted
  skill, a header line naming the skill followed by the full unified diff of
  that skill's directory (`git -C ~/.claude/skills diff -- <skill-dir>`).
  [verify: create/modify a tracked skill file under a test
  `~/.claude/skills` fixture, run `git skill diff`, confirm the skill's name
  appears as a header and the modified line(s) appear with `+`/`-` markers.]
- R2. `git skill diff <skill-name>` scopes output to only that one skill's
  diff, using the same header + full-diff format as R1. [verify: with two
  drifted skills, `git skill diff skill-a` prints only `skill-a`'s diff, not
  `skill-b`'s.]
- R3. `git skill diff <skill-name>` where `<skill-name>` is **not** currently
  drifted (whether aligned, untracked, unknown, or misspelled) prints a red
  error to stderr naming the skill and stating it is not drifted, and exits
  non-zero. It does not print any diff. [verify: run against an aligned
  skill's name and against a nonexistent name; both cases print an error
  matching `not drifted` (or equivalent) and the process exit code is
  nonzero.]
- R4. When no argument is given and there are zero drifted skills, print a
  green `[OK]`-style message (matching the existing style of
  `_render_skill_state`'s "Nothing to publish from this machine" line) and
  exit 0. No diff output, no error. [verify: run `git skill diff` in a
  fixture with 0 drifted skills; stdout contains an OK-style message, exit
  code is 0.]
- R5. `git skill diff` (with or without an argument) determines which skills
  are drifted by invoking `skill-audit.{ps1,sh}` without `-Summary` (the full
  report) and parsing its `[!] Drifted (N)` section for skill directory
  names — it must **not** reimplement the aligned/drifted/untracked
  classification logic itself. [verify: read the diff/PR — no new code in
  `gitconfig_helper.py` calls `git status --porcelain` directly to classify
  skills; the drifted-name list is derived from parsing `skill-audit`'s
  output.]
- R6. `git skill diff` follows the existing per-OS invocation pattern used by
  `_audit_summary()` for locating and running `skill-audit.ps1` (Windows,
  preferring `pwsh`, falling back to `powershell` since `skill-audit.ps1` is
  WinPS-compatible — it is not in `PS7_SCRIPTS`) or `skill-audit.sh`
  (non-Windows, via `bash`). [verify: code reuses/mirrors `_audit_summary()`'s
  script-path and shell-selection logic rather than introducing a divergent
  path.]
- R7. `git skill diff` requires `~/.claude/skills` to exist, same as every
  other real subcommand (`_require_skills_dir()` gate in `skill(args)`).
  [verify: with `SKILLS_DIR` pointed at a nonexistent path, `git skill diff`
  prints the existing "claude-skills repo isn't set up" message and exits
  nonzero — same behavior as `git skill status` today.]
- R8. `git skill diff` does not fetch from the skills repo's remote before
  diffing (diff is a local working-tree-vs-HEAD comparison; no network call
  is needed or made). [verify: code path contains no `git fetch` /
  `-NoFetch`-toggling call for the `diff` subcommand; `skill-audit` is
  invoked in a way equivalent to its `-NoFetch`/`--no-fetch` mode if that
  flag affects anything beyond the ahead/behind line.]
- R9. `git skill diff`, `git skill diff help`, `git skill help`, and bare
  `git skill` (no args) all print `diff` in the subcommand list with a
  one-line description, consistent with the existing `SKILL_USAGE` format
  (see current lines for `list`/`sync`/`status`/`publish`). [verify: grep
  `SKILL_USAGE` in the diff for a `diff` line.]
- R10. Diff output lines are escaped before being handed to `rich`'s
  `Console.print` (matching the existing convention in `skill_sync()`), so
  that diff content containing `[`/`]` characters (e.g. a skill script
  referencing `[some-tag]`) renders literally instead of being interpreted as
  `rich` markup. [verify: diff a skill file containing a literal `[...]`
  substring; confirm it appears unmangled in output rather than being
  swallowed/altered by markup parsing.]

## Out of scope
- Any change to the `claude-skills` repo itself (`skill-audit.ps1`/`.sh`,
  `publish-skill.*`, etc.) — including adding a `-Json`/`--json` output mode
  to `skill-audit`. If parsing its plain-text `Drifted` section proves too
  fragile during implementation, that is a signal to open a follow-up issue
  against `claude-skills`, not to silently expand this spec's file list.
- Diffing/showing **untracked** skills (new, never-published skill
  directories) — `git diff` has no meaningful output for untracked files;
  that case stays covered by `git skill status`'s "untracked" count only.
- A `--stat` / summary-only flag — R1/R2 always print the full diff.
- Color/syntax-highlighting the diff beyond what raw `git diff` already
  produces (e.g. no `rich.syntax.Syntax` diff renderer) — plain escaped
  passthrough only, matching `skill_sync()`'s existing style.
- Changing `git skill status`, `sync`, `publish`, or `list` behavior.
- Piping/paging behavior (e.g. auto-invoking `less`/`$PAGER`) — output goes
  straight to stdout via `rich`, same as every other subcommand today.

## Constraints
- Windows PowerShell 5.1 vs pwsh 7 differences apply per this repo's global
  CLAUDE.md platform-awareness rule and the existing `PS7_SCRIPTS` /
  `_run_skill_script` pattern — `skill-audit.ps1` is **not** PS7-only, so
  `diff` must remain runnable under Windows PowerShell 5.1 (fall back to
  `powershell` when `pwsh` is absent), matching `_audit_summary()`.
- Follow this repo's existing code style in `gitconfig_helper.py`: docstrings
  in the same terse explanatory style as neighboring functions, `rich`
  `Console` for output, `subprocess.run(..., capture_output=True, text=True,
  encoding="utf-8", errors="replace")` for shelling out.
- New Pester tests follow the static source-regex pattern already used in the
  `"skill aliases"` Context block of `tests/gitconfig_helper.Tests.ps1` —
  do not introduce a live-execution test style inconsistent with the rest of
  that file.
- Git workflow: per this repo's CLAUDE.md, use the `git-policies` skill
  (issue first, `fix/`/`feat/` branch prefix, signed commits, PR with
  `Fixes #N`) when implementing — not part of this spec, but binding on
  whoever executes it.

## Acceptance rubric
- C1 (from R1): PASS iff running `git skill diff` with ≥1 drifted skill
  prints that skill's name and its full unified diff (visible `+`/`-` lines
  matching the actual file change).
- C2 (from R1): PASS iff running `git skill diff` with 2+ drifted skills
  prints a distinct header + diff block for each one (not just the first).
- C3 (from R2): PASS iff `git skill diff <name>` with a valid drifted `<name>`
  prints only that skill's header + diff.
- C4 (from R2): PASS iff, with 2 drifted skills present, `git skill diff
  skill-a` does not print any content belonging to `skill-b`.
- C5 (from R3): PASS iff `git skill diff <name>` for a non-drifted (aligned)
  existing skill prints a stderr error naming the skill and stating it is not
  drifted, and the process exits non-zero.
- C6 (from R3): PASS iff `git skill diff <name>` for a nonexistent skill name
  prints a stderr error and exits non-zero (does not crash with a Python
  traceback).
- C7 (from R4): PASS iff `git skill diff` with zero drifted skills prints an
  `[OK]`-style message and exits 0, with no diff content and no error.
- C8 (from R5): PASS iff no code added for the `diff` subcommand calls `git
  status --porcelain` (or reimplements the aligned/untracked/drifted
  classification loop) directly — drifted names are obtained by parsing
  `skill-audit`'s non-summary output.
- C9 (from R6): PASS iff the Windows script-selection logic for `diff`
  matches `_audit_summary()`'s pattern (prefers `pwsh`, falls back to
  `powershell`, targets `skill-audit.ps1`) rather than diverging (e.g.
  incorrectly requiring PS7).
- C10 (from R7): PASS iff `git skill diff` with `SKILLS_DIR` pointed at a
  missing path prints the same "claude-skills repo isn't set up" guidance as
  `git skill status` does today, and exits non-zero.
- C11 (from R8): PASS iff no `git fetch` (or equivalent remote-contacting
  call) executes as part of the `diff` subcommand's code path.
- C12 (from R9): PASS iff `SKILL_USAGE` (and therefore `git skill help` /
  bare `git skill` output) lists `diff` with a one-line description in the
  same format as the other subcommands.
- C13 (from R10): PASS iff diff output containing literal `[`/`]` characters
  renders unmangled (not interpreted as rich markup) in the printed output.
- C14 (from Deliverable): PASS iff `tests/gitconfig_helper.Tests.ps1` gained
  new `It` block(s) asserting `skill_diff` exists and is wired into the
  dispatcher and `SKILL_USAGE`, written in the same static-regex style as the
  existing `"skill aliases"` Context block, and the full Pester suite
  (`tests/run-tests.ps1`) passes.
- C15 (from Out of scope): PASS iff the diff touches no files under
  `~/.claude/skills` or its mirrored repo path in this workspace (only
  `gitconfig_helper.py` and `tests/gitconfig_helper.Tests.ps1` are modified).
- C-final: PASS iff a maintainer familiar with this repo's `git skill`
  subcommands, reviewing the implementation, would accept it without
  substantive changes — consistent styling, error handling, and test
  coverage with the existing `list`/`sync`/`status`/`publish` subcommands.

## Open questions
(none)
