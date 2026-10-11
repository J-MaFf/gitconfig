# Shared-script tests (Linux / macOS)

These suites cover the cross-platform bash and Python code that the mac and
linux setup scripts depend on (since [#229](https://github.com/J-MaFf/gitconfig/issues/229)
one implementation in `scripts/unix/`, run directly or through the
`scripts/mac version/` and `scripts/linux version/` wrappers). They complement the Windows-only Pester suite in
`../` so regressions on the primary dev platforms are caught.

| Suite | Runner | Covers |
| --- | --- | --- |
| `functions.bats` | [bats-core](https://github.com/bats-core/bats-core) | `scripts/shared/functions.sh` — `backup_file`/`backup_copy` (timestamped backups and the pinned `<file>.pre-gitconfig` original) and `prune_backups` (retention), `create_symlink`, `file_owner_uid`, `update_allowed_signers`, `generate_gitconfig` (including an `&` in the repo path; a foreign or dangling `~/.gitconfig` symlink is replaced, never written through, [#257](https://github.com/J-MaFf/gitconfig/issues/257)), `keep_local_settings`, git-alias widget enable/disable (disable removes only a complete block, after a backup, #257), `ask_yes_no` and the exit codes of `generate_gitconfig`/`initialize-gitconfig.sh` (2 when declined or unanswered, 1 when unwritable; an unparsable `~/.gitconfig` no longer exits 128, [#258](https://github.com/J-MaFf/gitconfig/issues/258)) |
| `gitignore-global.bats` | bats-core | `.gitignore_global` — ignores editor/OS junk and secrets (at any depth, with no root-anchored patterns, and a project `!pattern` can re-include a public `.pem`/`.key`, [#263](https://github.com/J-MaFf/gitconfig/issues/263)), never lockfiles, `bin/`, `lib/`, `.vscode/`, `*.bat`/`*.cmd` or other files projects commit, and has no duplicate patterns |
| `platform.bats` | bats-core | `scripts/shared/platform.sh` ([#229](https://github.com/J-MaFf/gitconfig/issues/229)) — OS detection and the wrong-platform guard (`GITCONFIG_PLATFORM`, `GITCONFIG_ALLOW_CROSS_OS`), the cron line format (`%`/quote escaping, per-user log under `${XDG_STATE_HOME:-~/.local/state}`) and removal that claims only this clone's lines (never another clone's or a commented-out one, [#259](https://github.com/J-MaFf/gitconfig/issues/259)), the launchd plist's XML escaping and `plutil -lint` check, signing-key priority (key file, op-ssh-sign, existing `user.signingkey`) and op-ssh-sign probe paths, credential helper choice per OS |
| `mac-initialize-local-config.bats` | bats-core | `scripts/mac version/initialize-local-config.sh` (wrapper for `scripts/unix/initialize-local-config.sh`) — always writes `allowedSignersFile` when signing is enabled ([#116](https://github.com/J-MaFf/gitconfig/issues/116)); trusts an other-owned Homebrew repo so `brew update` keeps working ([#169](https://github.com/J-MaFf/gitconfig/issues/169)); emits file-based no-agent signing config from an on-disk key ([#171](https://github.com/J-MaFf/gitconfig/issues/171)); refuses to run on a non-macOS host ([#179](https://github.com/J-MaFf/gitconfig/issues/179)) |
| `linux-initialize-local-config.bats` | bats-core | `scripts/linux version/initialize-local-config.sh` (wrapper for `scripts/unix/initialize-local-config.sh`) — emits a Linux-appropriate HTTPS credential helper (gh CLI scoped to github.com, libsecret fallback, commented hint otherwise) and never osxkeychain; refuses to run on a macOS host ([#179](https://github.com/J-MaFf/gitconfig/issues/179)); signs like macOS ([#229](https://github.com/J-MaFf/gitconfig/issues/229)): `claude_desktop` key and no-agent wrapper, op-ssh-sign, `allowedSignersFile` for an existing signing key; no Homebrew safe directory; `--force` keeps settings you added, replaces a symlinked file, and survives an unreadable one ([#257](https://github.com/J-MaFf/gitconfig/issues/257)); exits 2 when the prompt has no input ([#258](https://github.com/J-MaFf/gitconfig/issues/258)) |
| `install-platform-guard.bats` | bats-core | The per-OS `install.sh` wrappers abort on the other OS before any destructive step ([#181](https://github.com/J-MaFf/gitconfig/issues/181)), and the error points at `scripts/unix/install.sh` |
| `install-backups.bats` | bats-core | Runs the real mac and linux `install.sh` in a sandboxed `$HOME`: re-running never loses the original files, links into the repo aren't backed up, cleanup runs only with `--reinstall`, no `core.excludesfile` drift in `~/.gitconfig`, retention limit ([#226](https://github.com/J-MaFf/gitconfig/issues/226)), `install --force` keeps your `~/.gitconfig.local` settings ([#257](https://github.com/J-MaFf/gitconfig/issues/257)), no-input runs finish with `[SKIP]` lines and a failed step makes it exit 1 ([#258](https://github.com/J-MaFf/gitconfig/issues/258)) |
| `auto-sync.bats` | bats-core | The login/daily auto-sync ([#225](https://github.com/J-MaFf/gitconfig/issues/225)): `scripts/shared/update-gitconfig.sh` defaults to its own repo, fails loudly on a missing path, keeps a feature branch checked out while fast-forwarding main, and runs git with `GIT_TERMINAL_PROMPT=0`; the Linux installer puts the shared updater and repo path in the cron entry, tags it `# gitconfig-autoupdate`, replaces rather than duplicates it (migrating an untagged line from an older install), verifies it and finishes without `crontab`, logs to a per-user file and creates its directory, and Linux cleanup removes only that entry, this clone's old untagged ones included but never another clone's (and also finishes without `crontab`); `--no-scheduler`/`--no-cron`/`--no-launchd` all skip the job; `scripts/unix/install.sh` picks cron or launchd from the host; the mac installer writes a launchd plist with a Homebrew `PATH`; mac cleanup survives its counters under `set -e`; linux cleanup exits 2 when its prompt has no input and 1 when the cron job can't be removed ([#258](https://github.com/J-MaFf/gitconfig/issues/258)). Uses stub `crontab`/`launchctl` and a fake `HOME` |
| `update-gitconfig.bats` | bats-core | `scripts/shared/update-gitconfig.sh` — branch prune via `git for-each-ref` (a `: gone]` commit subject can't trigger a delete), `-d` before `-D`, tip SHAs logged, worktree skip, exit codes ([#228](https://github.com/J-MaFf/gitconfig/issues/228)); run on a terminal via `script(1)` (as `git selfupdate` is), progress is shown there and a failed pull exits 1 ([#258](https://github.com/J-MaFf/gitconfig/issues/258)) |
| `test_gitconfig_helper.py` | [pytest](https://docs.pytest.org/) | `gitconfig_helper.py` — `_slugify`, `LABEL_PREFIX` selection, `_have`, `_default_branch`, `get_git_aliases`, branch cleanup, `git main` (and its unmerged-path report), `git start` (branch naming by issue number, `--no-track`, tracking an existing remote branch, base fallback), `git skill`'s cross-repo guard, drift outside skill directories, a `skill-audit` failure reported as an error rather than drift or "nothing to diff", and `git skill diff` covering staged and untracked changes; `git issues --all --local` failing when every repo fails, and `--all --web` keeping `--mine`/`--label` ([#260](https://github.com/J-MaFf/gitconfig/issues/260)); `git alias --out` failing loudly without a TTY ([#254](https://github.com/J-MaFf/gitconfig/issues/254)); CLI exit codes, per-command argument allow-lists (`-h` and unknown flags run nothing, [#250](https://github.com/J-MaFf/gitconfig/issues/250)); the template's `git pushf` alias refuses to overwrite a teammate's commit after a background fetch ([#251](https://github.com/J-MaFf/gitconfig/issues/251)); the alias browser's ctrl+left/right category keys work with the search box focused (driven headlessly with Textual's `App.run_test()`), the clipboard copy doesn't wait on a forking tool (a fake one on an isolated `PATH`), a detached HEAD is labelled by its short SHA, and a `SKILL.md` with a UTF-8 BOM keeps its description ([#261](https://github.com/J-MaFf/gitconfig/issues/261)); the template's `git localconfig` alias opens the editor with no arguments and passes arguments through ([#263](https://github.com/J-MaFf/gitconfig/issues/263)); brackets in issue titles, git/gh stderr, paths, branch names and alias bodies are printed verbatim, not parsed as rich markup ([#239](https://github.com/J-MaFf/gitconfig/issues/239)) |
| `test_deps.py` | pytest | `scripts/shared/deps.py` — the Python < 3.11 regex fallback (forced by blocking `tomllib`) reads extras, environment markers, comments and single-line arrays, and matches `tomllib` on the same manifests ([#261](https://github.com/J-MaFf/gitconfig/issues/261)) |

## Running

CI (`.github/workflows/test.yml`) runs both suites on `ubuntu-latest` and
`macos-latest` for every pull request. To run them locally:

### Bash (bats)

```sh
# Install bats-core (one of):
#   brew install bats-core            # macOS
#   sudo apt-get install bats         # Debian/Ubuntu
#   git clone https://github.com/bats-core/bats-core && ./bats-core/install.sh ~/.local
bats tests/shared/        # runs every *.bats in this directory
```

The suite redirects `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` and works inside a
`mktemp -d` sandbox, so it never touches your real `~/.gitconfig`,
`~/.gitconfig.local`, `~/.ssh/allowed_signers`, or shell rc files.

### Python (pytest)

```sh
python -m pip install pytest rich textual   # the helper's deps; without textual the alias-browser tests skip
pytest tests/shared/            # test_gitconfig_helper.py and test_deps.py
```

The pytest suite imports `gitconfig_helper.py` by path. Most tests monkeypatch
`run_git`; the branch-cleanup, `git main`, `git start` and `git skill diff` tests
build throwaway repos (with a local bare remote) under pytest's `tmp_path`, with
`GIT_CONFIG_GLOBAL` redirected, so they need no network and never touch your
config.
