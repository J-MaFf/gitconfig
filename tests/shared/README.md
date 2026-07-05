# Shared-script tests (Linux / macOS)

These suites cover the cross-platform bash and Python code that the mac and
linux setup scripts depend on. They complement the Windows-only Pester suite in
`../` so regressions on the primary dev platforms are caught.

| Suite | Runner | Covers |
| --- | --- | --- |
| `functions.bats` | [bats-core](https://github.com/bats-core/bats-core) | `scripts/shared/functions.sh` — `backup_file`, `create_symlink`, `file_owner_uid`, `update_allowed_signers`, `generate_gitconfig`, git-alias widget enable/disable |
| `mac-initialize-local-config.bats` | bats-core | `scripts/mac version/initialize-local-config.sh` — always writes `allowedSignersFile` when signing is enabled ([#116](https://github.com/J-MaFf/gitconfig/issues/116)); trusts an other-owned Homebrew repo so `brew update` keeps working ([#169](https://github.com/J-MaFf/gitconfig/issues/169)) |
| `test_gitconfig_helper.py` | [pytest](https://docs.pytest.org/) | `gitconfig_helper.py` — `_slugify`, `LABEL_PREFIX` selection, `_have`, `_default_branch`, `get_git_aliases` |

## Running

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
