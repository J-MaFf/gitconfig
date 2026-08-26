# Spec: Python preflight check + remove premature `git alias` self-test

> **Completed 2026-08-26.** Built via the forge generator/evaluator loop; all 8 acceptance
> criteria (C1-C7, C-final) passed on round 1. Shipped in
> [PR #220](https://github.com/J-MaFf/gitconfig/pull/220) (`Fixes #219`).

## Goal

`install.ps1` should tell the user up front — before doing any work — when no working Python
interpreter is available, and let them choose whether to continue (Python only powers the
`git alias` browser / `rich`+`textual` deps; the core gitconfig install works without it).
Separately, remove the `git alias` self-test in `Initialize-Symlinks.ps1` STEP 2, which
structurally cannot pass on a fresh install because it runs before Python deps are installed.

## Context

- Prior conversation (this session) diagnosed a real run: on a fresh machine with no Python,
  [install.ps1](../../scripts/windows%20version/install.ps1) completed correctly but produced
  three confusing warnings, all one root cause (no Python). After the user installed Python,
  a second run still printed `[WARN] git alias command failed` at STEP 2, even though STEP 7
  later confirmed `[OK] Git aliases working` in the *same run*.
- Root cause (verified by reading the file): `gitconfig_helper.py` hard-requires `rich` at
  import time and calls `sys.exit(1)` if it's missing
  ([gitconfig_helper.py:17-24](../../gitconfig_helper.py:17)):
  ```python
  try:
      from rich.console import Console
      from rich.table import Table
      from rich.markup import escape
  except ImportError:
      print("Error: the 'rich' library is not installed.")
      print("Run the install script for your platform, or: pip install rich")
      sys.exit(1)
  ```
  `install.ps1` doesn't `pip install rich`/`textual` until **STEP 6**
  ([install.ps1:176-184](../../scripts/windows%20version/install.ps1:176), via
  `Install-PythonDeps` in
  [Functions.ps1:167](../../scripts/windows%20version/Functions.ps1:167)). But
  `Initialize-Symlinks.ps1`'s self-test runs `git alias` at **STEP 2**
  ([Initialize-Symlinks.ps1:221-234](../../scripts/windows%20version/Initialize-Symlinks.ps1:221)),
  before `rich` exists — so on any machine where Python/rich aren't already installed from a
  prior run, it warns every time, regardless of whether the eventual install succeeds.
  `install.ps1` STEP 7 ([install.ps1:246-252](../../scripts/windows%20version/install.ps1:246))
  already re-runs the identical `git alias` check, correctly ordered after STEP 6 — it is the
  authoritative verification and makes the STEP 2 copy redundant.
- `install.ps1`'s existing control flow (verified by reading the file):
  - Line 37-40: a preflight check — `git` missing → `Write-Error` + `exit 1` — runs **before**
    the admin-elevation block (line 43-67).
  - Line 43-67: if not elevated, the script relaunches itself via
    `Start-Process powershell ... -Verb RunAs -Wait` and the *original, non-elevated* process
    then `exit 0`s. This means any code placed **before** line 43 runs once in the
    non-elevated process (and, if it prompts and the user says yes to proceed, will run
    *again* in the freshly-relaunched elevated process — the same script starts over from the
    top). Code placed **after** the elevation block (i.e. after line 67, before STEP 0 at line
    85) runs exactly once, in the elevated process only.
  - `-Force` already exists as a switch and already means "don't prompt me, just proceed"
    (e.g. it's threaded into `Initialize-Symlinks.ps1` to skip its own prompts under
    `-Force`).
  - Resolve-Python ([Functions.ps1:32-90](../../scripts/windows%20version/Functions.ps1:32)) is
    the existing, already-correct way to detect a *working* interpreter (`py`/`python3`/
    `python`, with WindowsApps-stub and PyManager-fallback handling already built in — do not
    duplicate or reimplement this logic). It is dot-sourced from `Functions.ps1`, which
    `install.ps1` already dot-sources at STEP 6 (line 182); for the new preflight check, dot
    source `Functions.ps1` earlier instead, once, and reuse it at STEP 6 as before.
  - Decisions already made with the user (do not re-litigate):
    - Missing Python → warn, then prompt `Continue anyway? (y/n)`, same interaction style as
      the existing scheduled-task prompt in `Initialize-Symlinks.ps1:202`. `n` exits the
      script cleanly (exit code 0) without touching any files. `y` proceeds into STEP 0
      exactly as today's Python-missing runs already do (degrade gracefully).
    - `-Force` skips this new prompt too (auto-continue), consistent with what `-Force`
      already means everywhere else in this script.
    - The STEP 2 `git alias` self-test in `Initialize-Symlinks.ps1` is **removed outright**,
      not relocated. It is not moved into `install.ps1`'s STEP 6/7 sequence either — STEP 7
      already covers this exact check, correctly ordered.
- `Initialize-Symlinks.ps1` is also documented as a standalone script
  ([README.md:183](../../README.md:183): `Initialize-Symlinks.ps1 -Force  # Recreate symlinks`).
  Removing its self-test means standalone runs no longer get an automatic `git alias` sanity
  check — that's accepted; users can run `git alias` themselves, and this file's job is
  symlinks, not Python dependency verification.
- No existing Pester test asserts on the STEP 2 self-test's output strings or on the
  `install.ps1` preflight block (`grep` over `tests/*.ps1` for `"Testing symlink setup"`,
  `"git alias command failed"`, `"git not found"`, `"Preflight"` returned nothing) — removal
  and addition are both free of test breakage from string matching, but `tests/run-tests.ps1`
  must still pass (syntax, no regressions elsewhere).

## Deliverable

Edits to two existing files (no new files):
- [scripts/windows version/install.ps1](../../scripts/windows%20version/install.ps1)
- [scripts/windows version/Initialize-Symlinks.ps1](../../scripts/windows%20version/Initialize-Symlinks.ps1)

## Requirements

- R1. `install.ps1` gains a Python preflight check placed after the admin-elevation block
  (after line 67, before the `[STEP 0]` banner at line 85), so it runs exactly once, in the
  elevated process. [verify: read the diff — the new block's first line appears after the
  `catch { ... exit 1 }` that closes the elevation `try`, and before
  `Write-Host "GitConfig Setup"`]
- R2. The check dot-sources `Functions.ps1` and calls `Resolve-Python` (the existing function)
  to determine whether a working interpreter exists — no new/duplicate interpreter-probing
  logic is written. [verify: read the diff — no new `Get-Command py|python3|python` or
  `command -v` logic appears outside of `Functions.ps1`; STEP 6's later dot-source of
  `Functions.ps1` is removed since it's now redundant, or left in place harmlessly (dot-
  sourcing twice is not an error) — either is acceptable as long as `Resolve-Python` isn't
  reimplemented]
- R3. When `Resolve-Python` returns nothing (no working interpreter):
  - Print a warning explaining that Python powers the `git alias` browser and its `rich`/
    `textual` dependencies, and that the core gitconfig install works fine without it.
  - If `-Force` was **not** passed: prompt `Continue anyway? (y/n)` via `Read-Host`
    (matching the existing prompt style at
    [Initialize-Symlinks.ps1:202](../../scripts/windows%20version/Initialize-Symlinks.ps1:202)).
    - Answer `y` (case-insensitive): proceed to STEP 0 as normal.
    - Any other answer: print a one-line message that setup was cancelled, and `exit 0`
      (not `exit 1` — declining is not an error) without creating or modifying any files.
  - If `-Force` **was** passed: skip the prompt, print a note that the Python-missing warning
    was auto-continued because of `-Force`, and proceed to STEP 0.
  [verify: read the diff for the conditional structure; manually trace: `-Force` + no Python →
  no `Read-Host` call reachable; no `-Force` + no Python + input `n` → script exits 0 before
  `[STEP 0]` prints and before `Cleanup-GitConfig.ps1` is invoked]
- R4. When `Resolve-Python` returns a working interpreter, the preflight check prints nothing
  beyond (at most) a single `[OK]`-style line or nothing at all — it must not become a second
  copy of STEP 7's later, more detailed `rich`/`textual` import checks. [verify: read the
  diff — the found-Python branch is at most one line, no `import rich`/`import textual`
  probing added here]
- R5. `install.ps1 -Help` output is updated if the new preflight behavior changes the documented
  flag semantics (it doesn't add a new flag, so this is satisfied by leaving `-Help` text as-is
  unless review finds it now says something inaccurate about `-Force`). [verify: read
  `-Help` text at install.ps1:12-30 after the change; confirm it isn't contradicted]
- R6. `Initialize-Symlinks.ps1`'s STEP 2 `git alias` self-test block
  ([Initialize-Symlinks.ps1:221-234](../../scripts/windows%20version/Initialize-Symlinks.ps1:221))
  is deleted in its entirety, including the `Write-Host "Testing symlink setup..."` header line
  immediately above it. [verify: `grep -n "Testing symlink setup\|git alias" "scripts/windows
  version/Initialize-Symlinks.ps1"` returns no matches]
- R7. Nothing else in `Initialize-Symlinks.ps1` changes — the scheduled-task prompt
  immediately before the removed block (lines 200-215) and the trailing blank-line structure
  around it are otherwise untouched. [verify: diff the file; only the self-test block and its
  header are removed, no other lines change]
- R8. `install.ps1` STEP 7's existing `git alias` verification
  ([install.ps1:246-252](../../scripts/windows%20version/install.ps1:246)) is untouched — it
  remains the sole, correctly-ordered `git alias` self-test in the install flow.
  [verify: diff shows no changes in that line range]
- R9. `tests/run-tests.ps1` (the Pester unit suite, excluding `-Tag Integration`) still passes
  after the change. [verify: run `pwsh -File tests/run-tests.ps1` (or the project's documented
  equivalent) and confirm no new failures relative to a pre-change baseline run]

## Out of scope

- Auto-installing Python (e.g. via `winget`) on the user's behalf. The preflight only detects
  and asks; it never installs anything itself.
- Changing what STEP 6 (`Install-PythonDeps`) does, or how `Resolve-Python` detects
  interpreters — both are reused as-is.
- Adding a new CLI flag (e.g. `-SkipPythonCheck`); `-Force` already covers "don't ask me."
- Touching `Update-GitConfig.ps1` (the login-task script) — it never calls `install.ps1` and
  is already non-interactive/best-effort about Python via `Install-PythonDeps`; this spec does
  not change its behavior.
- Relocating the STEP 2 self-test elsewhere in `Initialize-Symlinks.ps1` or into `install.ps1`
  — it is removed, per the decision already made with the user.
- Rewording or restructuring STEP 6/STEP 7's existing output.
- Any change to `gitconfig_helper.py`'s hard `rich` import requirement.

## Constraints

- PowerShell 5.1+ compatible syntax (repo targets Windows PowerShell + PowerShell 7+ per
  existing scripts).
- Follow this repo's existing `[OK]`/`[WARN]`/`[FAIL]`/`[SKIP]` console-message convention and
  `Write-Host -ForegroundColor` usage seen throughout `install.ps1` and
  `Initialize-Symlinks.ps1`.
- No new external dependencies.
- Do not change the meaning of `-Force` for anything it already controls (file overwrites,
  scheduled-task replacement).

## Acceptance rubric

- C1 (from R1): PASS iff the new Python preflight block's code is located strictly between the
  admin-elevation `try/catch` block and the `[STEP 0]` `Write-Host` banner in `install.ps1`.
- C2 (from R2): PASS iff `Resolve-Python` is called (not reimplemented) and no new interpreter-
  probing code (`Get-Command py|python3|python`, `command -v`, etc.) appears outside
  `Functions.ps1`.
- C3 (from R3): PASS iff, tracing the script by hand for all four combinations of
  {`-Force` present/absent} × {Python found/not found}, the observed behavior in each case
  matches R3 exactly (including exit code 0 on decline, and that decline touches zero files).
- C4 (from R4): PASS iff the found-Python branch of the new block does not perform or print
  `rich`/`textual` import verification (that stays exclusive to STEP 7).
- C5 (from R6): PASS iff `grep -n "Testing symlink setup\|git alias" "scripts/windows
  version/Initialize-Symlinks.ps1"` returns zero matches.
- C6 (from R7, R8): PASS iff a diff of both files shows no unintended changes outside the
  areas named in R1-R3 and R6 — specifically STEP 7's block in `install.ps1` and the
  scheduled-task prompt in `Initialize-Symlinks.ps1` are byte-identical to before.
- C7 (from R9): PASS iff `tests/run-tests.ps1` (non-integration suite) passes with no new
  failures.
- C-final: PASS iff a maintainer re-running the exact two scenarios from this session's
  conversation — (a) fresh machine, no Python, plain `.\install.ps1 -Force` — would now see a
  single clear up-front notice instead of three scattered warnings, with a chance to bail
  before any files are touched when *not* using `-Force`; and (b) a machine with Python
  already installed but `rich` not yet present would no longer see the misleading
  `[WARN] git alias command failed` mid-run.

## Open questions

(none)
