# Spec: CI workflow to run the Pester suite on the self-hosted Windows runner

> **Completed 2026-08-26.** Built via the forge generator/evaluator loop; all 9 acceptance
> criteria (C1-C9, C-final) passed on round 1. Shipped in
> [PR #222](https://github.com/J-MaFf/gitconfig/pull/222) (`Fixes #221`). The workflow's own
> first real trigger on `GH-RUNNER-FLAUI` then exposed a real, pre-existing bug this spec's
> criteria didn't catch: `tests/run-tests.ps1` always exited 0 regardless of test results when
> called without `-PassThru` (its own primary documented usage) — `Invoke-Pester`'s
> `Run.PassThru` config was wired to the script's own `-PassThru` switch instead of always
> being requested internally, so the exit-code check silently no-op'd. Fixed in the same PR
> and re-verified on the real runner (same 61 pre-existing failures now correctly produce a
> failed job instead of a false "success").

## Goal

Add a GitHub Actions workflow that runs `tests/run-tests.ps1` (the non-integration Pester
suite) on every pull request, using the self-hosted Windows runner already connected to this
repo, so tests execute automatically instead of only ever being run manually.

## Context

- GitHub issue: [#221](https://github.com/J-MaFf/gitconfig/issues/221) — this spec supersedes
  its "gate on merge" framing per decisions made with the user below.
- Verified: `gh api repos/J-MaFf/gitconfig/actions/runners` shows one connected runner:
  `GH-RUNNER-FLAUI`, status `online`, labels `[self-hosted, Windows, X64]`.
- Verified: the repo's only existing workflow is
  [.github/workflows/claude.yml](../../.github/workflows/claude.yml) — the `@claude` mention
  GitHub App integration, `uses:` a reusable workflow on `runs-on: ubuntu-latest`. It has
  nothing to do with testing and is not touched by this spec.
- Verified: `tests/run-tests.ps1` ([tests/run-tests.ps1](../../tests/run-tests.ps1)) is the
  existing, correct entry point:
  - Defaults to `-Path ./tests`, excludes `Tag 'Integration'` unless `-IncludeIntegration` is
    passed (integration tests mutate real machine state: scheduled task, symlinks,
    `~/.gitconfig` — must never run against the runner machine's real state).
  - Requires `Pester` module `-MinimumVersion 5.0`; if missing, prints
    `"Pester 5.0+ is required. Install with: Install-Module -Name Pester -Force"` and
    `exit 1` — it does not install it itself.
  - `exit 1` if `$results.FailedCount -gt 0`, `exit 0` otherwise — a plain non-zero exit is
    sufficient for a CI step to fail; no custom result parsing is needed.
- Verified (ran directly on a real Windows dev machine in this conversation, not a sandboxed
  agent): `tests/gitconfig_helper.Tests.ps1` run alone is fully green (73/73). But the **full**
  suite (`.\tests\run-tests.ps1`, all 10 files together) hit a real, different failure in
  `switch_to_main`'s "Should fail when there are uncommitted changes" test (a `git rev-parse`
  exit-128 error) and then hung past a 2-minute timeout — apparent cross-test state pollution
  when the suite runs as a whole, not a fluke of one sandboxed subagent. This is real,
  reproduced evidence, not a report from an untrusted source.
- Decisions already made with the user (do not re-litigate):
  - **Do not gate merges on this check.** The branch ruleset (verified via
    `gh api repos/J-MaFf/gitconfig/rulesets/11141898` — rules are currently only
    `non_fast_forward` and `pull_request`, no `required_status_checks`) is NOT modified by
    this spec. Given the reproduced hang above, requiring this check would risk blocking every
    PR on an unstable suite. Gating is explicitly deferred to a separate follow-up once the
    suite's flakiness is diagnosed (tracked outside this spec — see Out of scope).
  - **Trigger: `pull_request` only.** No `push` trigger (nothing pushes directly to `main` in
    this repo's PR-gated workflow per the git-policies skill).
  - **The workflow bootstraps the Pester module if missing** (installs it, doesn't just fail)
    — this repo's CI should "just work" without someone first hand-provisioning the runner.
    This covers the `Pester` PowerShell *module* only, not the `pwsh` interpreter itself:
    installing an entire PowerShell version in a CI step is out of scope and riskier on a
    persistent self-hosted machine; if `pwsh` itself is missing, the job must fail with
    GitHub Actions' own clear "unable to locate executable file: pwsh" error rather than
    something swallowed or ambiguous — this happens automatically by specifying
    `shell: pwsh` on the steps, no extra handling needed.
  - **A firm `timeout-minutes` cap is required** on the job, specifically because of the
    reproduced hang above. There is exactly one connected runner
    (`GH-RUNNER-FLAUI`) — an unbounded hung job would block every subsequent workflow run on
    this repo indefinitely, which is a much worse failure mode than a job that times out and
    reports failure. Use **20 minutes** (single-file runs completed in under a minute each;
    20 minutes is a generous cap that still fails fast relative to "indefinitely").
  - No path filters on the trigger — run on every PR regardless of which files changed. There
    is no GitHub-hosted-runner billing concern (self-hosted), and the repo is small enough
    that a blanket trigger is simpler and cheaper to reason about than a paths allowlist that
    must be kept in sync with the test suite's actual coverage.

## Deliverable

One new file: `.github/workflows/test.yml`.

No other files are modified by this spec (CHANGELOG.md/STATUS.md updates, if any, follow the
git-policies skill's standing PR convention and are not spec requirements here).

## Requirements

- R1. The workflow triggers on `pull_request` only — no `push`, `workflow_dispatch`, or other
  trigger. [verify: read the `on:` block]
- R2. The job specifies `runs-on: [self-hosted, Windows, X64]`, matching the connected
  runner's exact labels. [verify: read the `runs-on:` line]
- R3. The job specifies `timeout-minutes: 20`. [verify: read the job-level key]
- R4. The workflow checks out the repository (e.g. `actions/checkout@v4`) before running
  tests. [verify: a checkout step precedes the test-run step]
- R5. A step ensures the `Pester` PowerShell module (version 5.0+) is installed before running
  tests: check via `Get-Module -ListAvailable -Name Pester` (or equivalent) for a version
  `>= 5.0`, and if none is found, install one (e.g.
  `Install-Module -Name Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck -Scope CurrentUser`).
  This step must not fail (or skip installation) when a suitable Pester version is already
  present — it must be idempotent / safe to run on every job. [verify: read the step; trace
  both branches (module present / absent) by hand]
- R6. A step runs `./tests/run-tests.ps1` with no arguments (default behavior: excludes
  `Tag 'Integration'`; `-IncludeIntegration` is never passed). The step must use
  `shell: pwsh`. [verify: read the step's `run:` and `shell:` keys — no `-IncludeIntegration`
  flag anywhere in the file]
- R7. The job fails (non-zero exit / red check) when `run-tests.ps1` exits non-zero, and
  succeeds when it exits zero — i.e. no step swallows or ignores the script's exit code (no
  `continue-on-error: true`, no `2>&1 | Out-Null`-style suppression, no `|| $true` etc. after
  the invocation). [verify: read the step; confirm no error-suppression pattern wraps the
  `run-tests.ps1` invocation]
- R8. `.github/workflows/claude.yml` is not modified. [verify: `git diff` shows no changes to
  that file]
- R9. The branch ruleset is not modified — no `required_status_checks` rule is added, no
  existing rule is changed. [verify: `gh api repos/J-MaFf/gitconfig/rulesets/11141898` before
  and after this spec's work shows identical `rules[].type` values]

## Out of scope

- Adding `required_status_checks` to the branch ruleset (gating). Deferred to a follow-up
  after the suite's cross-file flakiness/hang (see Context) is diagnosed and fixed.
- Diagnosing or fixing the `switch_to_main` full-suite failure/hang itself. That is real,
  separate work — file it as its own follow-up (bead/issue), not part of this spec.
- Running the macOS/Linux bash/bats suites. `GH-RUNNER-FLAUI` is Windows-only; those suites
  need a different runner.
- Running `-IncludeIntegration` tests. They mutate real machine state (scheduled task,
  symlinks, `~/.gitconfig`) and must never run against the runner's persistent real state.
- Installing or upgrading `pwsh` itself if it's missing from the runner — that's a runner
  provisioning task for a human with access to the machine, not something this CI workflow
  does for itself.
- Test result annotations, a step summary, or a third-party test-reporter action. A plain
  pass/fail job status (via `run-tests.ps1`'s exit code) is sufficient per the goal; anything
  fancier is unrequested scope.
- `CHANGELOG.md` / `STATUS.md` edits — handled by the standing git-policies PR convention,
  not spelled out as a numbered requirement here.
- `push` or `workflow_dispatch` triggers.

## Constraints

- YAML must be valid GitHub Actions workflow syntax (a workflow with invalid syntax simply
  never runs — no separate linter is available, so this must be checked by careful reading
  and, if possible, `actionlint` or similar if installed; not a hard requirement to install
  new tooling for this).
- Follow this repo's existing workflow file's header-comment style (a short `#`-prefixed
  explanation of what the file does and why) — see the top of
  [.github/workflows/claude.yml](../../.github/workflows/claude.yml) for precedent.
- Match the labels **exactly** as reported by
  `gh api repos/J-MaFf/gitconfig/actions/runners`: `self-hosted`, `Windows`, `X64` (this
  exact casing).

## Acceptance rubric

- C1 (from R1): PASS iff the workflow's `on:` block contains only `pull_request`.
- C2 (from R2): PASS iff `runs-on:` is exactly `[self-hosted, Windows, X64]` (or equivalent
  YAML list syntax with the same three labels, no more, no fewer).
- C3 (from R3): PASS iff the job sets `timeout-minutes: 20`.
- C4 (from R4): PASS iff a checkout action step exists and precedes the test-run step.
- C5 (from R5): PASS iff the Pester-bootstrap step correctly handles both "already present"
  and "missing" cases without failing the job in the "already present" case, traced by hand.
- C6 (from R6): PASS iff the test-run step invokes `./tests/run-tests.ps1` with no arguments,
  under `shell: pwsh`, and no `-IncludeIntegration` flag appears anywhere in the file.
- C7 (from R7): PASS iff no error-suppression/continue-on-error pattern wraps the test-run
  step — a non-zero exit from `run-tests.ps1` would fail the job.
- C8 (from R8): PASS iff `git diff` (this spec's change vs. the branch point) touches no file
  other than `.github/workflows/test.yml` (plus whatever CHANGELOG/STATUS convention edits
  the implementing PR makes per house convention — those are not part of this criterion, but
  `claude.yml` specifically must be untouched).
- C9 (from R9): PASS iff `gh api repos/J-MaFf/gitconfig/rulesets/11141898 --jq '.rules[].type'`
  returns exactly `non_fast_forward` and `pull_request` — unchanged from the verified
  pre-spec state.
- C-final: PASS iff a maintainer reading this workflow file would conclude: "yes, this will
  run the unit Pester suite on our self-hosted Windows runner for every PR, fail visibly on
  real test failures, won't silently no-op if Pester isn't installed, and won't hang the
  runner forever if the suite pollutes state again."

## Open questions

(none)
