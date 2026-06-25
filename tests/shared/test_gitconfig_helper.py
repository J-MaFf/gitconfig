# Pytest suite for the pure-logic helpers in gitconfig_helper.py.
#
# These run on the primary dev platforms (Linux/macOS), complementing the
# Windows-only Pester suite. They exercise the deterministic, side-effect-free
# parts of the helper (slugifying, label->prefix mapping, default-branch
# resolution, alias parsing) so regressions are caught without needing a real
# repository or network access.
#
# Run with:  pytest tests/shared/test_gitconfig_helper.py
# Requires:  pytest and the helper's own dependency, `rich`.

import importlib.util
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HELPER_PATH = os.path.join(REPO_ROOT, "gitconfig_helper.py")


def _load_helper():
    """Import gitconfig_helper.py by path (it lives at the repo root, not on
    sys.path, and is not a package)."""
    spec = importlib.util.spec_from_file_location("gitconfig_helper", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def helper():
    return _load_helper()


# --------------------------------------------------------------------------
# _slugify
# --------------------------------------------------------------------------

class TestSlugify:
    def test_basic_title(self, helper):
        assert helper._slugify("Add bash test coverage") == "add-bash-test-coverage"

    def test_collapses_punctuation_and_spaces(self, helper):
        assert helper._slugify("Fix:  the   bug!!!") == "fix-the-bug"

    def test_strips_leading_and_trailing_separators(self, helper):
        assert helper._slugify("  --Hello, World--  ") == "hello-world"

    def test_lowercases(self, helper):
        assert helper._slugify("CamelCase TITLE") == "camelcase-title"

    def test_truncates_to_max_length_without_trailing_dash(self, helper):
        title = "word " * 40  # far longer than the default 50-char cap
        slug = helper._slugify(title)
        assert len(slug) <= 50
        assert not slug.endswith("-")

    def test_custom_max_length(self, helper):
        slug = helper._slugify("one two three four five", max_length=7)
        assert len(slug) <= 7
        assert not slug.endswith("-")

    def test_empty_input_falls_back_to_issue(self, helper):
        assert helper._slugify("") == "issue"

    def test_punctuation_only_falls_back_to_issue(self, helper):
        assert helper._slugify("!!!@@@###") == "issue"


# --------------------------------------------------------------------------
# LABEL_PREFIX  (drives the fix/feat/docs branch prefix in start_branch)
# --------------------------------------------------------------------------

class TestLabelPrefix:
    def test_known_labels_map_to_expected_prefixes(self, helper):
        assert helper.LABEL_PREFIX["bug"] == "fix"
        assert helper.LABEL_PREFIX["enhancement"] == "feat"
        assert helper.LABEL_PREFIX["feature"] == "feat"
        assert helper.LABEL_PREFIX["documentation"] == "docs"
        assert helper.LABEL_PREFIX["docs"] == "docs"

    def test_first_matching_label_wins(self, helper):
        # Mirrors the selection logic in start_branch: first label that is a
        # known key determines the prefix, defaulting to "feat".
        labels = ["wontfix", "bug", "enhancement"]
        prefix = next(
            (helper.LABEL_PREFIX[label] for label in labels if label in helper.LABEL_PREFIX),
            "feat",
        )
        assert prefix == "fix"

    def test_unknown_labels_default_to_feat(self, helper):
        labels = ["question", "triage"]
        prefix = next(
            (helper.LABEL_PREFIX[label] for label in labels if label in helper.LABEL_PREFIX),
            "feat",
        )
        assert prefix == "feat"


# --------------------------------------------------------------------------
# _have  (PATH lookup wrapper)
# --------------------------------------------------------------------------

class TestHave:
    def test_returns_true_for_present_executable(self, helper):
        # git is required for the whole project, so it is a safe positive.
        assert helper._have("git") is True

    def test_returns_false_for_absent_executable(self, helper):
        assert helper._have("definitely-not-a-real-command-xyz") is False


# --------------------------------------------------------------------------
# _default_branch  (reads git config init.defaultBranch, falls back to main)
# --------------------------------------------------------------------------

class TestDefaultBranch:
    def test_falls_back_to_main_when_unset(self, helper, monkeypatch):
        class _Result:
            returncode = 1
            stdout = ""

        monkeypatch.setattr(helper, "run_git", lambda *a, **k: _Result())
        assert helper._default_branch() == "main"

    def test_uses_configured_value(self, helper, monkeypatch):
        class _Result:
            returncode = 0
            stdout = "trunk\n"

        monkeypatch.setattr(helper, "run_git", lambda *a, **k: _Result())
        assert helper._default_branch() == "trunk"


# --------------------------------------------------------------------------
# get_git_aliases  (parses `git config --get-regexp alias` output)
# --------------------------------------------------------------------------

class TestGetGitAliases:
    def _patch_git_output(self, helper, monkeypatch, stdout, returncode=0):
        class _Result:
            pass

        res = _Result()
        res.returncode = returncode
        res.stdout = stdout

        def fake_run_git(*args, check=False):
            if check and returncode != 0:
                import subprocess

                raise subprocess.CalledProcessError(returncode, args)
            return res

        monkeypatch.setattr(helper, "run_git", fake_run_git)

    def test_known_alias_uses_curated_metadata(self, helper, monkeypatch):
        self._patch_git_output(helper, monkeypatch, "alias.s status -sb\n")
        aliases = helper.get_git_aliases()
        assert len(aliases) == 1
        name, description, category = aliases[0]
        assert name == "s"
        assert category == "Inspect"
        # Curated description from ALIAS_METADATA, not the raw value.
        assert description == helper.ALIAS_METADATA["s"][1]

    def test_unknown_shell_alias_is_categorized_as_other(self, helper, monkeypatch):
        self._patch_git_output(helper, monkeypatch, "alias.foo !echo hi\n")
        aliases = helper.get_git_aliases()
        assert len(aliases) == 1
        name, description, category = aliases[0]
        assert name == "foo"
        assert category == "Other"
        assert description.startswith("Shell: ")

    def test_unknown_plain_alias_is_categorized_as_other(self, helper, monkeypatch):
        self._patch_git_output(helper, monkeypatch, "alias.co checkout\n")
        aliases = helper.get_git_aliases()
        name, description, category = aliases[0]
        assert name == "co"
        assert category == "Other"
        assert description == "checkout"

    def test_results_sorted_by_category_then_name(self, helper, monkeypatch):
        # "s" is Inspect (earlier in CATEGORY_ORDER), "zzz" is Other (last).
        self._patch_git_output(helper, monkeypatch, "alias.zzz !echo z\nalias.s status -sb\n")
        aliases = helper.get_git_aliases()
        categories = [a[2] for a in aliases]
        order = {c: i for i, c in enumerate(helper.CATEGORY_ORDER)}
        assert [order[c] for c in categories] == sorted(order[c] for c in categories)
        # Inspect ("s") must come before Other ("zzz").
        assert aliases[0][0] == "s"

    def test_empty_config_returns_empty_list(self, helper, monkeypatch):
        # `git config --get-regexp alias` exits non-zero when no aliases exist.
        self._patch_git_output(helper, monkeypatch, "", returncode=1)
        assert helper.get_git_aliases() == []


# --------------------------------------------------------------------------
# _require_skills_dir / skill() cross-repo guard
# --------------------------------------------------------------------------

class TestSkillCrossRepoGuard:
    """`git skill` depends on the separate claude-skills repo at ~/.claude/skills.
    The guard must allow help/usage and unknown-subcommand handling without it,
    but block the real subcommands with an actionable pointer when it's missing."""

    def test_require_true_when_dir_exists(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        assert helper._require_skills_dir() is True

    def test_require_false_when_dir_missing(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path / "nope"))
        assert helper._require_skills_dir() is False

    def test_skill_list_blocked_when_repo_missing(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path / "nope"))
        assert helper.skill(["list"]) == 1

    def test_help_and_usage_work_without_repo(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path / "nope"))
        assert helper.skill(["help"]) == 0
        assert helper.skill([]) == 0

    def test_unknown_subcommand_errors_without_repo(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path / "nope"))
        assert helper.skill(["bogus"]) == 1


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
