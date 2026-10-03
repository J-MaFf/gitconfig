# Shared-script tests (Linux / macOS)

These suites cover the cross-platform bash and Python code that the mac and
linux setup scripts depend on. They complement the Windows-only Pester suite in
`../` so regressions on the primary dev platforms are caught.

| Suite | Runner | Covers |
| --- | --- | --- |
| `functions.bats` | [bats-core](https://github.com/bats-core/bats-core) | `scripts/shared/functions.sh` — `backup_file`/`backup_copy` (timestamped backups) and `prune_backups` (retention), `create_symlink`, `file_owner_uid`, `update_allowed_signers`, `generate_gitconfig`, git-alias widget enable/disable |
| `mac-initialize-local-config.bats` | bats-core | `scripts/mac version/initialize-local-config.sh` — always writes `allowedSignersFile` when signing is enabled ([#116](https://github.com/J-MaFf/gitconfig/issues/116)); trusts an other-owned Homebrew repo so `brew update` keeps working ([#169](https://github.com/J-MaFf/gitconfig/issues/169)); emits file-based no-agent signing config from an on-disk key ([#171](https://github.com/J-MaFf/gitconfig/issues/171)); refuses to run on a non-macOS host ([#179](https://github.com/J-MaFf/gitconfig/issues/179)) |
| `linux-initialize-local-config.bats` | bats-core | `scripts/linux version/initialize-local-config.sh` — emits a Linux-appropriate HTTPS credential helper (gh CLI scoped to github.com, libsecret fallback, commented hint otherwise) and never osxkeychain; refuses to run on a macOS host ([#179](https://github.com/J-MaFf/gitconfig/issues/179)) |
| `install-backups.bats` | bats-core | Runs the real mac and linux `install.sh` in a sandboxed `$HOME`: re-running never loses the original files, links into the repo aren't backed up, cleanup runs only with `--reinstall`, no `core.excludesfile` drift in `~/.gitconfig`, retention limit ([#226](https://github.com/J-MaFf/gitconfig/issues/226)) |
| `auto-sync.bats` | bats-core | The login/daily auto-sync ([#225](https://github.com/J-MaFf/gitconfig/issues/225)): `scripts/shared/update-gitconfig.sh` defaults to its own repo, fails loudly on a missing path, keeps a feature branch checked out while fast-forwarding main, and runs git with `GIT_TERMINAL_PROMPT=0`; the Linux installer puts the repo path in the cron entry and finishes without `crontab`; the mac installer writes a launchd plist with a Homebrew `PATH`; mac cleanup survives its counters under `set -e`. Uses stub `crontab`/`launchctl` and a fake `HOME` |
| `test_gitconfig_helper.py` | [pytest](https://docs.pytest.org/) | `gitconfig_helper.py` — `_slugify`, `LABEL_PREFIX` selection, `_have`, `_default_branch`, `get_git_aliases` |

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
python -m pip install pytest rich   # rich is gitconfig_helper.py's own dependency
pytest tests/shared/test_gitconfig_helper.py
```

The pytest suite imports `gitconfig_helper.py` by path and monkeypatches
`run_git`, so it needs neither a real repository nor network access.
