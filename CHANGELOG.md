# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Adopted **beads (`bd`)** as the Dolt-backed task/memory layer beneath GitHub Issues ([#152](https://github.com/J-MaFf/gitconfig/issues/152)). The bead graph syncs via `refs/dolt/data` on `origin`; `.beads/config.yaml` and `.beads/metadata.json` are tracked while the JSONL exports and embedded Dolt DB are gitignored (dolt-only sync).

### Fixed
- Windows login scheduled task logged "No Python interpreter found" even when Python was installed: `Resolve-Python` picked the 0-byte WindowsApps app-execution-alias stub, which only resolves in an interactive session. It now skips those stubs and falls back to the real PyManager/launcher path ([#161](https://github.com/J-MaFf/gitconfig/pull/161)).
- Non-ASCII em-dashes (U+2014) in `Update-GitConfig.ps1` and `gitconfig_helper.py` failed the ASCII Encoding tests (Windows PowerShell 5.1 compatibility) ([#164](https://github.com/J-MaFf/gitconfig/pull/164)).
- The Pester suite mutated the real machine (overwrote `~/.gitconfig`/`~/.gitconfig.local`, toggled the login scheduled task): `run-tests.ps1` set tag filters under the wrong Pester config section so `-ExcludeTag Integration` was ignored, and two test files generated config against the real `$env:USERPROFILE`. Tests now sandbox HOME and integration tests are excluded by default ([#167](https://github.com/J-MaFf/gitconfig/pull/167)).

### Changed
- `install.ps1` no longer overwrites an existing `~/.gitconfig.local` (create-if-missing). The machine-specific config is preserved on re-install; regenerate deliberately with `Initialize-LocalConfig.ps1 -Force` ([#166](https://github.com/J-MaFf/gitconfig/pull/166)).
- `tests/run-tests.ps1` excludes integration tests by default; opt in with `-IncludeIntegration` (run only on a real machine or VM) ([#167](https://github.com/J-MaFf/gitconfig/pull/167)).
