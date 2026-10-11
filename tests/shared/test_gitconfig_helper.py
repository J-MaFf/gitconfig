# Pytest suite for the pure-logic helpers in gitconfig_helper.py.
#
# These run on the primary dev platforms (Linux/macOS), complementing the
# Windows-only Pester suite. Most exercise the deterministic parts of the helper
# (slugifying, label->prefix mapping, default-branch resolution, alias parsing)
# with run_git monkeypatched. The branch-cleanup, `git main` and `git start`
# tests build throwaway repos under tmp_path with a local bare remote and an
# isolated GIT_CONFIG_GLOBAL: no network, and the developer's config is untouched.
# The same sandbox runs the template's `git pushf` alias against two clones.
#
# Run with:  pytest tests/shared/test_gitconfig_helper.py
# Requires:  pytest and the helper's own dependency, `rich`.

import importlib.util
import json
import os
import subprocess
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
# _default_branch  (origin/HEAD, then init.defaultBranch, then main)
# --------------------------------------------------------------------------

class _Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _fake_git(responses):
    """run_git stand-in: map the first git argument to a _Result (default: failure)."""
    def run_git(*args, **kwargs):
        return responses.get(args[0], _Result(returncode=1))
    return run_git


class TestDefaultBranch:
    def test_uses_origin_head(self, helper, monkeypatch):
        monkeypatch.setattr(helper, "run_git", _fake_git({
            "symbolic-ref": _Result(stdout="origin/trunk\n"),
            "config": _Result(stdout="main\n"),
        }))
        assert helper._default_branch() == "trunk"

    def test_origin_head_wins_over_init_default_branch(self, helper, monkeypatch):
        # init.defaultBranch only names *new* repos; it used to override the
        # remote's real default and send `git main` to the wrong branch.
        monkeypatch.setattr(helper, "run_git", _fake_git({
            "symbolic-ref": _Result(stdout="origin/master\n"),
            "config": _Result(stdout="main\n"),
        }))
        assert helper._default_branch() == "master"

    def test_falls_back_to_init_default_branch(self, helper, monkeypatch):
        monkeypatch.setattr(helper, "run_git", _fake_git({
            "config": _Result(stdout="develop\n"),
        }))
        assert helper._default_branch() == "develop"

    def test_falls_back_to_main_when_nothing_is_set(self, helper, monkeypatch):
        monkeypatch.setattr(helper, "run_git", _fake_git({}))
        assert helper._default_branch() == "main"


# --------------------------------------------------------------------------
# _local_branches / _delete_branch  (branch state from for-each-ref)
# --------------------------------------------------------------------------

def _ref_line(name, head="", upstream="", track="", worktree="", tip="abc1234"):
    return "\x1f".join((name, head, upstream, track, worktree, tip))


class TestLocalBranches:
    def test_parses_structured_fields(self, helper, monkeypatch):
        stdout = "\n".join([
            _ref_line("main", head="*", upstream="refs/remotes/origin/main"),
            _ref_line("feat/x", upstream="refs/remotes/origin/feat/x", track="[gone]", tip="1111111"),
            _ref_line("fork", upstream="refs/remotes/upstream/main", track="[behind 2]"),
            _ref_line("wt", upstream="refs/remotes/origin/wt", track="[gone]", worktree="/tmp/wt"),
            _ref_line("local"),
        ]) + "\n"
        monkeypatch.setattr(helper, "run_git", _fake_git({"for-each-ref": _Result(stdout=stdout)}))
        by_name = {b["name"]: b for b in helper._local_branches()}

        assert by_name["main"]["current"] is True
        assert by_name["main"]["worktree"] is False  # its own worktree path is not "another"
        assert by_name["feat/x"]["gone"] is True
        assert by_name["feat/x"]["tip"] == "1111111"
        # A branch tracking a non-origin remote is neither gone nor local-only.
        assert by_name["fork"]["gone"] is False
        assert by_name["fork"]["upstream"] == "refs/remotes/upstream/main"
        assert by_name["wt"]["worktree"] is True
        assert by_name["local"]["upstream"] == ""
        assert by_name["local"]["gone"] is False

    def test_git_failure_returns_none(self, helper, monkeypatch):
        monkeypatch.setattr(helper, "run_git", _fake_git({}))
        assert helper._local_branches() is None


class TestDeleteBranch:
    @staticmethod
    def _patch(helper, monkeypatch, d_ok, big_d_ok):
        calls = []

        def run_git(*args, **kwargs):
            calls.append(args)
            ok = d_ok if args[1] == "-d" else big_d_ok
            return _Result(returncode=0 if ok else 1, stderr="" if ok else "error: nope")

        monkeypatch.setattr(helper, "run_git", run_git)
        return calls

    def test_merged_branch_uses_d_only(self, helper, monkeypatch):
        calls = self._patch(helper, monkeypatch, d_ok=True, big_d_ok=True)
        assert helper._delete_branch("b", gone=True) == ("deleted", "")
        assert calls == [("branch", "-d", "b")]

    def test_gone_unmerged_branch_falls_back_to_force(self, helper, monkeypatch):
        calls = self._patch(helper, monkeypatch, d_ok=False, big_d_ok=True)
        assert helper._delete_branch("b", gone=True) == ("forced", "")
        assert calls == [("branch", "-d", "b"), ("branch", "-D", "b")]

    def test_unmerged_local_only_branch_is_never_forced(self, helper, monkeypatch):
        calls = self._patch(helper, monkeypatch, d_ok=False, big_d_ok=True)
        assert helper._delete_branch("b", gone=False) == ("kept", "error: nope")
        assert ("branch", "-D", "b") not in calls

    def test_reports_failure_when_force_fails(self, helper, monkeypatch):
        self._patch(helper, monkeypatch, d_ok=False, big_d_ok=False)
        assert helper._delete_branch("b", gone=True) == ("failed", "error: nope")


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


# --------------------------------------------------------------------------
# _repo_dirt_paths / _render_repo_dirt
# --------------------------------------------------------------------------

class TestRepoDirt:
    """`git skill status` used to report only what skill-audit sees (skill
    directories), so uncommitted changes anywhere else in the skills repo left
    it printing "nothing to publish" while `git update` skipped the repo as
    dirty. The repo-wide check must catch those and only those."""

    @staticmethod
    def _patch_status(helper, monkeypatch, stdout, returncode=0):
        class _Result:
            def __init__(self):
                self.stdout = stdout
                self.stderr = ""
                self.returncode = returncode

        monkeypatch.setattr(helper, "run_git", lambda *a, **k: _Result())

    @staticmethod
    def _make_skill(tmp_path, name):
        (tmp_path / name).mkdir()
        (tmp_path / name / "SKILL.md").write_text("---\nname: x\n---\n")

    def test_reports_non_skill_paths(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(
            helper, monkeypatch, " M .claude-plugin/marketplace.json\n?? notes.txt\n"
        )
        assert helper._repo_dirt_paths() == [".claude-plugin/marketplace.json", "notes.txt"]

    def test_ignores_paths_inside_skill_dirs(self, helper, tmp_path, monkeypatch):
        # Drift inside a skill folder is already counted by skill-audit;
        # reporting it here too would double-count it.
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._make_skill(tmp_path, "my-skill")
        self._patch_status(helper, monkeypatch, " M my-skill/SKILL.md\n")
        assert helper._repo_dirt_paths() == []

    def test_rename_reports_both_sides(self, helper, tmp_path, monkeypatch):
        # The bug that motivated this: .claude-plugin/ renamed to
        # .claude-plugin.offtest/ - git may report it as a rename entry.
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(
            helper, monkeypatch, "R  .claude-plugin/a.txt -> .claude-plugin.offtest/a.txt\n"
        )
        assert helper._repo_dirt_paths() == [
            ".claude-plugin.offtest/a.txt",
            ".claude-plugin/a.txt",
        ]

    def test_arrow_in_untracked_filename_is_not_split(self, helper, tmp_path, monkeypatch):
        # Only R/C entries carry "old -> new"; an untracked file may just be
        # named that way, and splitting it would invent two phantom paths.
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(helper, monkeypatch, "?? a -> b.txt\n")
        assert helper._repo_dirt_paths() == ["a -> b.txt"]

    def test_quoted_paths_are_unquoted(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(helper, monkeypatch, '?? "dir with spaces/file.txt"\n')
        assert helper._repo_dirt_paths() == ["dir with spaces/file.txt"]

    def test_clean_tree_is_empty(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(helper, monkeypatch, "")
        assert helper._repo_dirt_paths() == []

    def test_git_failure_returns_none(self, helper, tmp_path, monkeypatch):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        self._patch_status(helper, monkeypatch, "", returncode=128)
        assert helper._repo_dirt_paths() is None

    def test_render_returns_false_when_clean(self, helper, monkeypatch):
        monkeypatch.setattr(helper, "_repo_dirt_paths", lambda: [])
        assert helper._render_repo_dirt(helper.Console()) is False

    def test_render_says_so_when_status_unavailable(self, helper, monkeypatch, capsys):
        monkeypatch.setattr(helper, "_repo_dirt_paths", lambda: None)
        assert helper._render_repo_dirt(helper.Console()) is False
        assert "unchecked" in capsys.readouterr().out

    def test_render_warns_and_names_the_consequence(self, helper, monkeypatch, capsys):
        monkeypatch.setattr(helper, "_repo_dirt_paths", lambda: [".claude-plugin/a.json"])
        assert helper._render_repo_dirt(helper.Console()) is True
        out = capsys.readouterr().out
        assert ".claude-plugin/a.json" in out
        assert "git update" in out

    def test_render_truncates_long_lists(self, helper, monkeypatch, capsys):
        monkeypatch.setattr(helper, "_repo_dirt_paths", lambda: [f"f{i}.txt" for i in range(8)])
        assert helper._render_repo_dirt(helper.Console()) is True
        out = capsys.readouterr().out
        assert "8 uncommitted file(s)" in out
        assert "and 3 more" in out


# --------------------------------------------------------------------------
# Real-git behaviour: cleanup, git main, git start, CLI dispatch
# --------------------------------------------------------------------------

def _git(cwd, *args):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def _commit(cwd, name, subject):
    (cwd / name).write_text(subject + "\n")
    _git(cwd, "add", name)
    _git(cwd, "commit", "-q", "-m", subject)


@pytest.fixture
def git_env(tmp_path, monkeypatch):
    """Isolate git from the developer's config (signing, hooks, aliases)."""
    gitconfig = tmp_path / "gitconfig"
    gitconfig.write_text(
        "[user]\n\tname = Test\n\temail = test@example.com\n"
        "[commit]\n\tgpgsign = false\n"
        "[init]\n\tdefaultBranch = main\n"
    )
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(gitconfig))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    return tmp_path


@pytest.fixture
def repo(git_env, monkeypatch):
    """A clone of a bare remote, on main, with origin/HEAD -> origin/main."""
    remote = git_env / "remote.git"
    _git(git_env, "init", "-q", "--bare", "-b", "main", str(remote))
    work = git_env / "work"
    _git(git_env, "clone", "-q", str(remote), str(work))
    _commit(work, "README.md", "Initial")
    _git(work, "push", "-q", "-u", "origin", "main")
    _git(work, "remote", "set-head", "origin", "main")
    monkeypatch.chdir(work)
    return work


def _branches(cwd):
    return set(_git(cwd, "for-each-ref", "--format=%(refname:short)", "refs/heads/").split())


class TestCleanupBranches:
    @staticmethod
    def _build(repo, tmp_path):
        tips = {}
        # gone-merged: fast-forwarded into main, then its remote branch deleted.
        _git(repo, "switch", "-q", "-c", "gone-merged")
        _commit(repo, "m.txt", "merged work")
        _git(repo, "push", "-q", "-u", "origin", "gone-merged")
        _git(repo, "switch", "-q", "main")
        _git(repo, "merge", "-q", "--ff-only", "gone-merged")
        _git(repo, "push", "-q", "origin", "main")
        # gone-unmerged: squash-merge stand-in (commits never reach main as-is).
        _git(repo, "switch", "-q", "-c", "gone-unmerged")
        _commit(repo, "u.txt", "squashed work")
        _git(repo, "push", "-q", "-u", "origin", "gone-unmerged")
        tips["gone-unmerged"] = _git(repo, "rev-parse", "--short", "HEAD")
        # trap: live branch whose subject contains ": gone]".
        _git(repo, "switch", "-q", "-c", "trap", "main")
        _commit(repo, "t.txt", "docs: gone] marks a deleted upstream")
        _git(repo, "push", "-q", "-u", "origin", "trap")
        # fork: tracks a second remote, which the old parser read as local-only.
        upstream = tmp_path / "upstream.git"
        _git(tmp_path, "clone", "-q", "--bare", str(tmp_path / "remote.git"), str(upstream))
        _git(repo, "remote", "add", "upstream", str(upstream))
        _git(repo, "fetch", "-q", "upstream")
        _git(repo, "switch", "-q", "-c", "fork", "main")
        _commit(repo, "f.txt", "fork work")
        _git(repo, "branch", "-q", "--set-upstream-to=upstream/main")
        # local-merged / local-unmerged: no upstream at all.
        _git(repo, "branch", "local-merged", "main")
        _git(repo, "switch", "-q", "-c", "local-unmerged", "main")
        _commit(repo, "l.txt", "local work")
        tips["local-unmerged"] = _git(repo, "rev-parse", "--short", "HEAD")
        # gone-worktree: gone, but checked out in another worktree.
        _git(repo, "switch", "-q", "-c", "gone-worktree", "main")
        _commit(repo, "w.txt", "worktree work")
        _git(repo, "push", "-q", "-u", "origin", "gone-worktree")
        _git(repo, "switch", "-q", "main")
        _git(repo, "worktree", "add", "-q", str(tmp_path / "wt"), "gone-worktree")
        for b in ("gone-merged", "gone-unmerged", "gone-worktree"):
            _git(repo, "push", "-q", "origin", "--delete", b)
        _git(repo, "switch", "-q", "trap")  # start somewhere other than main
        return tips

    def test_force_cleanup(self, helper, repo, tmp_path, capsys):
        tips = self._build(repo, tmp_path)
        assert helper.cleanup_branches(force=True) == 0
        out = capsys.readouterr().out
        assert _branches(repo) == {
            "main", "trap", "fork", "local-unmerged", "gone-worktree",
        }
        assert _git(repo, "branch", "--show-current") == "trap"
        assert tips["gone-unmerged"] in out  # tip printed so it can be restored
        assert "local-unmerged" in out and tips["local-unmerged"] in out  # kept, listed
        assert "gone-worktree" in out  # skipped, listed

    def test_default_cleanup_leaves_local_only_branches(self, helper, repo, tmp_path):
        self._build(repo, tmp_path)
        assert helper.cleanup_branches(force=False) == 0
        assert _branches(repo) == {
            "main", "trap", "fork", "local-merged", "local-unmerged", "gone-worktree",
        }

    def test_cleanup_from_linked_worktree_does_not_switch(self, helper, repo, tmp_path, monkeypatch):
        # main is checked out in the primary worktree, so cleanup can't switch
        # to it here; it deletes from there instead and leaves this worktree be.
        self._build(repo, tmp_path)
        _git(repo, "switch", "-q", "main")
        wt = tmp_path / "wt-trap"
        _git(repo, "worktree", "add", "-q", str(wt), "trap")
        monkeypatch.chdir(wt)
        assert helper.cleanup_branches(force=True) == 0
        assert _git(wt, "branch", "--show-current") == "trap"
        assert _branches(repo) == {
            "main", "trap", "fork", "local-unmerged", "gone-worktree",
        }

    def test_detached_head_is_restored(self, helper, repo, tmp_path):
        self._build(repo, tmp_path)
        _git(repo, "switch", "-q", "--detach", "trap")
        sha = _git(repo, "rev-parse", "HEAD")
        assert helper.cleanup_branches(force=False) == 0
        assert _git(repo, "rev-parse", "HEAD") == sha
        assert _git(repo, "branch", "--show-current") == ""  # still detached

    def test_failed_deletion_returns_1(self, helper, repo, tmp_path):
        self._build(repo, tmp_path)
        (repo / ".git" / "refs" / "heads" / "gone-unmerged.lock").write_text("")
        assert helper.cleanup_branches(force=False) == 1
        assert "gone-unmerged" in _branches(repo)

    def test_failed_fetch_returns_1(self, helper, repo, tmp_path):
        self._build(repo, tmp_path)
        _git(repo, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
        assert helper.cleanup_branches(force=False) == 1


    def test_repo_without_remote_cleans_up_quietly(self, helper, git_env, monkeypatch, capsys):
        work = git_env / "solo"
        _git(git_env, "init", "-q", "-b", "main", str(work))
        _commit(work, "README.md", "Initial")
        _git(work, "branch", "done", "main")
        monkeypatch.chdir(work)
        assert helper.cleanup_branches(force=True) == 0
        assert _branches(work) == {"main"}
        assert "Error" not in capsys.readouterr().out


class TestSwitchToMain:
    @staticmethod
    def _advance_remote(tmp_path):
        other = tmp_path / "other"
        _git(tmp_path, "clone", "-q", str(tmp_path / "remote.git"), str(other))
        _commit(other, "remote.txt", "remote work")
        _git(other, "push", "-q", "origin", "main")
        return _git(other, "rev-parse", "HEAD")

    def test_fetches_once_and_fast_forwards(self, helper, repo, tmp_path, monkeypatch):
        remote_head = self._advance_remote(tmp_path)
        _git(repo, "switch", "-q", "-c", "work")
        calls = []
        real = helper.run_git

        def spy(*args, **kwargs):
            calls.append(args)
            return real(*args, **kwargs)

        monkeypatch.setattr(helper, "run_git", spy)
        assert helper.switch_to_main() == 0
        assert _git(repo, "rev-parse", "HEAD") == remote_head
        assert _git(repo, "branch", "--show-current") == "main"
        assert sum(1 for c in calls if c[0] == "fetch") == 1
        assert not any(c[0] == "pull" for c in calls)

    def test_diverged_main_fails_without_merging(self, helper, repo, tmp_path, capsys):
        self._advance_remote(tmp_path)
        _commit(repo, "local.txt", "local-only commit on main")
        before = _git(repo, "rev-parse", "HEAD")
        assert helper.switch_to_main() == 1
        assert _git(repo, "rev-parse", "HEAD") == before  # no merge commit
        assert "1 commit(s)" in capsys.readouterr().out

    def test_follows_origin_head_not_init_default_branch(self, helper, repo, tmp_path):
        # The remote's default is "trunk"; init.defaultBranch says "main".
        _git(repo, "push", "-q", "origin", "main:trunk")
        _git(repo, "remote", "set-head", "origin", "trunk")
        _git(repo, "switch", "-q", "-c", "trunk", "--track", "origin/trunk")
        _git(repo, "switch", "-q", "main")
        assert helper.switch_to_main() == 0
        assert _git(repo, "branch", "--show-current") == "trunk"


    def test_inside_linked_worktree_updates_main_where_it_lives(self, helper, repo, tmp_path, monkeypatch, capsys):
        # main is checked out in the primary worktree; we run from a linked one.
        _git(repo, "switch", "-q", "-c", "done")
        _commit(repo, "d.txt", "done work")
        _git(repo, "push", "-q", "-u", "origin", "done")
        _git(repo, "switch", "-q", "main")
        _git(repo, "branch", "other-gone", "done")
        _git(repo, "branch", "-q", "--set-upstream-to=origin/done", "other-gone")
        wt = tmp_path / "wt"
        _git(repo, "worktree", "add", "-q", str(wt), "done")
        _git(repo, "push", "-q", "origin", "--delete", "done")
        remote_head = self._advance_remote(tmp_path)
        monkeypatch.chdir(wt)
        assert helper.switch_to_main() == 0
        out = capsys.readouterr().out
        assert _git(repo, "rev-parse", "main") == remote_head  # fast-forwarded in place
        assert _git(wt, "branch", "--show-current") == "done"  # this worktree untouched
        assert "other-gone" not in _branches(repo)  # cleanup ran
        assert "done" in _branches(repo)  # still checked out here
        assert "git worktree remove" in out

    def test_main_in_linked_worktree_from_primary(self, helper, repo, tmp_path):
        _git(repo, "switch", "-q", "-c", "work")
        wt = tmp_path / "wt-main"
        _git(repo, "worktree", "add", "-q", str(wt), "main")
        remote_head = self._advance_remote(tmp_path)
        assert helper.switch_to_main() == 0
        assert _git(wt, "rev-parse", "HEAD") == remote_head
        assert _git(repo, "branch", "--show-current") == "work"

    def test_dirty_worktree_holding_main_is_not_touched(self, helper, repo, tmp_path, capsys):
        _git(repo, "switch", "-q", "-c", "work")
        wt = tmp_path / "wt-main"
        _git(repo, "worktree", "add", "-q", str(wt), "main")
        (wt / "README.md").write_text("edited\n")
        before = _git(wt, "rev-parse", "HEAD")
        self._advance_remote(tmp_path)
        assert helper.switch_to_main() == 1
        assert _git(wt, "rev-parse", "HEAD") == before
        assert "Uncommitted changes" in capsys.readouterr().out

    def test_fetches_default_branch_remote_not_current_branch_remote(self, helper, repo, tmp_path):
        # On a branch tracking a second remote, a bare `git fetch` skipped origin.
        upstream = tmp_path / "upstream.git"
        _git(tmp_path, "clone", "-q", "--bare", str(tmp_path / "remote.git"), str(upstream))
        _git(repo, "remote", "add", "upstream", str(upstream))
        _git(repo, "fetch", "-q", "upstream")
        _git(repo, "switch", "-q", "-c", "forkwork", "--track", "upstream/main")
        remote_head = self._advance_remote(tmp_path)
        assert helper.switch_to_main() == 0
        assert _git(repo, "rev-parse", "HEAD") == remote_head

    def test_repo_without_remote_succeeds(self, helper, git_env, monkeypatch, capsys):
        work = git_env / "solo"
        _git(git_env, "init", "-q", "-b", "main", str(work))
        _commit(work, "README.md", "Initial")
        _git(work, "switch", "-q", "-c", "feature")
        monkeypatch.chdir(work)
        assert helper.switch_to_main() == 0
        assert _git(work, "branch", "--show-current") == "main"
        assert "Error" not in capsys.readouterr().out

    def test_bracketed_dirty_path_is_printed_verbatim(self, helper, repo, capsys):
        (repo / "[slug].tsx").write_text("x\n")
        assert helper.switch_to_main() == 1
        assert "[slug].tsx" in capsys.readouterr().out


class TestFastForwardConflictReport:
    """Unmerged paths come from `git diff --diff-filter=U`, not from searching
    `git status` text for "UU"/"AA"/"DD" (which also matched file names)."""

    @staticmethod
    def _patch(helper, monkeypatch, unmerged):
        monkeypatch.setattr(helper, "run_git", _fake_git({
            "rev-parse": _Result(stdout="abc1234\n"),  # an upstream exists
            "merge": _Result(returncode=1, stderr="fatal: Not possible to fast-forward"),
            "diff": _Result(stdout=unmerged),
            "status": _Result(stdout="?? UU_notes.md\n"),
            "rev-list": _Result(stdout="0\n"),
        }))

    def test_status_code_lookalike_file_name_is_not_a_conflict(self, helper, monkeypatch, capsys):
        self._patch(helper, monkeypatch, unmerged="")
        assert helper._fast_forward(helper.Console(), "main") is False
        assert "Unmerged paths" not in capsys.readouterr().out

    def test_reports_real_unmerged_paths(self, helper, monkeypatch, capsys):
        self._patch(helper, monkeypatch, unmerged="src/a.py\n")
        assert helper._fast_forward(helper.Console(), "main") is False
        out = capsys.readouterr().out
        assert "Unmerged paths" in out and "src/a.py" in out


class TestStartBranch:
    @staticmethod
    def _issues(helper, monkeypatch, issues):
        """Stub `gh issue view <n>` with issues = {number: (title, [labels])}."""
        real_run = subprocess.run

        def fake_run(cmd, *args, **kwargs):
            if cmd[0] == "gh":
                title, labels = issues[cmd[3]]
                body = json.dumps({"title": title, "labels": [{"name": n} for n in labels]})
                return subprocess.CompletedProcess(cmd, 0, stdout=body, stderr="")
            return real_run(cmd, *args, **kwargs)

        monkeypatch.setattr(helper, "_have", lambda cmd: True)
        monkeypatch.setattr(helper.subprocess, "run", fake_run)

    @staticmethod
    def _upstream(repo):
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "@{upstream}"],
            cwd=repo, capture_output=True, text=True,
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def test_new_branch_has_issue_number_and_no_upstream(self, helper, repo, monkeypatch):
        self._issues(helper, monkeypatch, {"7": ("Fix the thing", ["bug"])})
        assert helper.start_branch("7") == 0
        assert _git(repo, "branch", "--show-current") == "fix/7-fix-the-thing"
        assert _git(repo, "rev-parse", "HEAD") == _git(repo, "rev-parse", "origin/main")
        assert self._upstream(repo) is None  # untracked: first push sets it

    def test_tracks_branch_started_on_another_machine(self, helper, repo, git_env, monkeypatch):
        other = git_env / "other"
        _git(git_env, "clone", "-q", str(git_env / "remote.git"), str(other))
        _git(other, "switch", "-q", "-c", "fix/7-fix-the-thing")
        _commit(other, "o.txt", "work from the other machine")
        _git(other, "push", "-q", "-u", "origin", "fix/7-fix-the-thing")
        remote_tip = _git(other, "rev-parse", "HEAD")

        self._issues(helper, monkeypatch, {"7": ("Fix the thing", ["bug"])})
        assert helper.start_branch("7") == 0
        assert _git(repo, "branch", "--show-current") == "fix/7-fix-the-thing"
        assert _git(repo, "rev-parse", "HEAD") == remote_tip  # not a fresh branch from main
        assert self._upstream(repo) == "origin/fix/7-fix-the-thing"

    def test_issues_with_the_same_slug_get_different_branches(self, helper, repo, monkeypatch):
        self._issues(helper, monkeypatch, {
            "7": ("Fix the thing", ["bug"]),
            "8": ("Fix: the thing!", ["bug"]),
        })
        assert helper.start_branch("7") == 0
        _commit(repo, "seven.txt", "issue 7 work")
        seven_tip = _git(repo, "rev-parse", "HEAD")
        assert helper.start_branch("8") == 0
        assert _git(repo, "branch", "--show-current") == "fix/8-fix-the-thing"
        assert _git(repo, "rev-parse", "HEAD") != seven_tip  # not issue 7's branch
        assert _git(repo, "rev-parse", "fix/7-fix-the-thing") == seven_tip

    def test_non_ascii_titles_get_unique_branches(self, helper, repo, monkeypatch):
        self._issues(helper, monkeypatch, {
            # Japanese and Russian titles: no ASCII letters, so both slug to "issue".
            "7": ("\u65e5\u672c\u8a9e\u306e\u30bf\u30a4\u30c8\u30eb", []),
            "8": ("\u041e\u0448\u0438\u0431\u043a\u0430 \u0432 \u0441\u043a\u0440\u0438\u043f\u0442\u0435", []),
        })
        assert helper.start_branch("7") == 0
        assert _git(repo, "branch", "--show-current") == "feat/7-issue"
        assert helper.start_branch("8") == 0
        assert _git(repo, "branch", "--show-current") == "feat/8-issue"

    def test_existing_branch_found_by_number_after_relabel(self, helper, repo, monkeypatch):
        _git(repo, "branch", "feat/7-old-title")
        _git(repo, "branch", "fix/70-other-issue")
        self._issues(helper, monkeypatch, {"7": ("New title", ["bug"])})
        assert helper.start_branch("7") == 0
        assert _git(repo, "branch", "--show-current") == "feat/7-old-title"
        assert "fix/7-new-title" not in _branches(repo)

    def test_fetch_failure_warns_and_bases_on_local_default(self, helper, repo, git_env, monkeypatch, capsys):
        _git(repo, "switch", "-q", "-c", "feat/other-work")
        _commit(repo, "f.txt", "unrelated feature work")
        _git(repo, "remote", "set-url", "origin", str(git_env / "missing.git"))
        _git(repo, "update-ref", "-d", "refs/remotes/origin/main")

        self._issues(helper, monkeypatch, {"7": ("Fix the thing", ["bug"])})
        assert helper.start_branch("7") == 0
        out = capsys.readouterr().out
        assert "Warning: fetch failed" in out
        assert _git(repo, "branch", "--show-current") == "fix/7-fix-the-thing"
        assert _git(repo, "rev-parse", "HEAD") == _git(repo, "rev-parse", "main")

    def test_old_style_branch_is_noted_not_reused(self, helper, repo, monkeypatch, capsys):
        _git(repo, "branch", "fix/fix-the-thing")
        self._issues(helper, monkeypatch, {"7": ("Fix the thing", ["bug"])})
        assert helper.start_branch("7") == 0
        assert _git(repo, "branch", "--show-current") == "fix/7-fix-the-thing"
        assert "old naming" in capsys.readouterr().out


class TestIssueBranches:
    def test_matches_on_issue_number_only(self, helper):
        refs = ["fix/7-a", "feat/7", "docs/7-b", "fix/70-c", "fix/a-7", "chore/7-d", "fix/7x"]
        assert helper._issue_branches("7", refs) == ["fix/7-a", "feat/7", "docs/7-b"]


class TestCli:
    @staticmethod
    def _run(*args):
        return subprocess.run(
            [sys.executable, HELPER_PATH, *args], capture_output=True, text=True
        )

    def test_unknown_function_exits_2_on_stderr(self):
        result = self._run("bogus")
        assert result.returncode == 2
        assert "bogus" in result.stderr
        assert result.stdout == ""

    def test_missing_function_exits_2(self):
        result = self._run()
        assert result.returncode == 2
        assert result.stderr

    def test_issues_rejects_unknown_flag(self, helper, monkeypatch, capsys):
        monkeypatch.setattr(helper, "_have", lambda cmd: pytest.fail("must not reach gh"))
        monkeypatch.setattr(helper, "_run_gh", lambda *a, **k: pytest.fail("must not reach gh"))
        assert helper.list_issues(["--lable", "bug"]) == 2
        assert "--lable" in capsys.readouterr().err

    def test_issues_help_exits_0_without_gh(self, helper, monkeypatch, capsys):
        monkeypatch.setattr(helper, "_have", lambda cmd: pytest.fail("must not reach gh"))
        assert helper.list_issues(["-h"]) == 0
        assert "Usage: git issues" in capsys.readouterr().out

    @pytest.mark.parametrize("sub", ["publish", "sync", "list"])
    def test_skill_rejects_unknown_flag(self, helper, tmp_path, monkeypatch, capsys, sub):
        monkeypatch.setattr(helper, "SKILLS_DIR", str(tmp_path))
        monkeypatch.setattr(helper, "_run_skill_script", lambda *a: pytest.fail("must not run"))
        monkeypatch.setattr(helper, "_skill_sync_or_status", lambda *a: pytest.fail("must not run"))
        monkeypatch.setattr(helper, "list_skills", lambda: pytest.fail("must not run"))
        assert helper.skill([sub, "--dry-run"]) == 2
        assert "--dry-run" in capsys.readouterr().err
        assert helper.skill([sub, "-h"]) == 0
        assert f"Usage: git skill {sub}" in capsys.readouterr().out


class TestCliArgValidation:
    """Unrecognised arguments must never fall through to the real command
    (#250: `git cleanup -h` force-deleted a gone branch)."""

    @staticmethod
    def _run(*args):
        # Inherits cwd and the isolated GIT_CONFIG_GLOBAL from the fixtures.
        return subprocess.run(
            [sys.executable, HELPER_PATH, *args], capture_output=True, text=True
        )

    @staticmethod
    def _gone_branch(repo):
        """Give `repo` a branch whose upstream has been deleted."""
        _git(repo, "switch", "-q", "-c", "feat/x")
        _commit(repo, "x.txt", "x work")
        _git(repo, "push", "-q", "-u", "origin", "feat/x")
        _git(repo, "switch", "-q", "main")
        _git(repo, "push", "-q", "origin", "--delete", "feat/x")
        _git(repo, "switch", "-q", "-c", "work")  # start away from main

    @pytest.mark.parametrize("flag", ["-h", "--help"])
    def test_cleanup_help_prints_usage_and_deletes_nothing(self, repo, flag):
        self._gone_branch(repo)
        result = self._run("cleanup", flag)
        assert result.returncode == 0
        assert "Usage: git cleanup" in result.stdout
        assert "feat/x" in _branches(repo)
        assert _git(repo, "branch", "--show-current") == "work"

    @pytest.mark.parametrize("flag", ["--dry-run", "-n", "--forse", "extra"])
    def test_cleanup_unknown_arg_exits_2_and_deletes_nothing(self, repo, flag):
        self._gone_branch(repo)
        result = self._run("cleanup", flag)
        assert result.returncode == 2
        assert flag in result.stderr and "Usage: git cleanup" in result.stderr
        assert result.stdout == ""
        assert "feat/x" in _branches(repo)
        assert _git(repo, "branch", "--show-current") == "work"

    @pytest.mark.parametrize("flag", ["--force", "-f"])
    def test_cleanup_documented_flags_still_run(self, repo, flag):
        self._gone_branch(repo)
        _git(repo, "branch", "local-only", "main")
        result = self._run("cleanup", flag)
        assert result.returncode == 0, result.stdout + result.stderr
        assert _branches(repo) == {"main"}  # gone + local-only (incl. work)

    def test_cleanup_without_args_still_runs(self, repo):
        self._gone_branch(repo)
        assert self._run("cleanup").returncode == 0
        assert "feat/x" not in _branches(repo)

    @pytest.mark.parametrize("flag", ["-h", "--help"])
    def test_main_help_does_not_switch(self, repo, flag):
        _git(repo, "switch", "-q", "-c", "work")
        result = self._run("switch_to_main", flag)
        assert result.returncode == 0
        assert "Usage: git main" in result.stdout
        assert _git(repo, "branch", "--show-current") == "work"

    def test_main_unknown_flag_exits_2_and_does_not_switch(self, repo):
        _git(repo, "switch", "-q", "-c", "work")
        result = self._run("switch_to_main", "--dry-run")
        assert result.returncode == 2
        assert "--dry-run" in result.stderr and "Usage: git main" in result.stderr
        assert _git(repo, "branch", "--show-current") == "work"

    def test_main_still_switches(self, repo):
        _git(repo, "switch", "-q", "-c", "work")
        result = self._run("switch_to_main")
        assert result.returncode == 0, result.stdout + result.stderr
        assert _git(repo, "branch", "--show-current") == "main"

    @staticmethod
    def _run_sandboxed(git_env, *args):
        """Run a copy of the helper whose derived Scripts root is an empty
        sandbox. `git main --all` sweeps every repo under that root, so any
        test that might reach it must never use the real checkout's path."""
        helper_dir = git_env / "root" / "gitconfig"
        helper_dir.mkdir(parents=True, exist_ok=True)
        sandboxed = helper_dir / "gitconfig_helper.py"
        sandboxed.write_text(open(HELPER_PATH, encoding="utf-8").read(), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(sandboxed), *args], capture_output=True, text=True
        )

    @pytest.mark.parametrize("flag", ["--all", "-a"])
    def test_main_all_still_dispatches(self, git_env, monkeypatch, flag):
        monkeypatch.chdir(git_env)
        result = self._run_sandboxed(git_env, "switch_to_main", flag)
        assert "Unknown argument" not in result.stderr
        assert "No git repositories found" in result.stdout  # update_all_main ran

    @pytest.mark.parametrize("args", [["--all", "--help"], ["-a", "--dry-run"]])
    def test_main_all_with_bad_args_does_not_sweep(self, git_env, monkeypatch, args):
        monkeypatch.chdir(git_env)
        result = self._run_sandboxed(git_env, "switch_to_main", *args)
        assert result.returncode in (0, 2)
        assert "Usage: git main" in result.stdout + result.stderr
        assert "No git repositories found" not in result.stdout

    def test_start_help_and_extra_args(self, git_env, monkeypatch):
        monkeypatch.chdir(git_env)
        result = self._run("start", "-h")
        assert result.returncode == 0 and "Usage: git start" in result.stdout
        result = self._run("start", "12", "34")
        assert result.returncode == 2 and "Unknown argument: 34" in result.stderr

    def test_alias_accepts_documented_flags_and_rejects_others(self, git_env, monkeypatch, tmp_path):
        monkeypatch.chdir(git_env)
        out = tmp_path / "sel.txt"
        assert self._run("print_aliases", "--plain").returncode == 0
        # --out is accepted; with no terminal it then fails on purpose (#254), not as a usage error
        result = self._run("print_aliases", "--out", str(out))
        assert result.returncode == 1 and "not a terminal" in result.stderr
        assert "Usage: git alias" not in result.stderr
        result = self._run("print_aliases", "--bogus")
        assert result.returncode == 2 and "Usage: git alias" in result.stderr
        result = self._run("print_aliases", "-h")
        assert result.returncode == 0 and "Usage: git alias" in result.stdout


# --------------------------------------------------------------------------
# `git pushf` alias from .gitconfig.template (#251)
# --------------------------------------------------------------------------

def _git_version():
    out = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout
    return tuple(int(n) for n in out.split()[2].split(".")[:2])


@pytest.mark.skipif(_git_version() < (2, 30), reason="--force-if-includes needs git 2.30+")
class TestPushfAlias:
    """Runs the template's real pushf alias against a bare remote shared by
    two clones. A bare --force-with-lease trusts whatever origin/<branch> was
    last fetched, so a background fetch (IDE autofetch, git main) silently
    disarms it; --force-if-includes keeps it armed."""

    @staticmethod
    def _template_alias(name):
        return subprocess.run(
            ["git", "config", "--file", os.path.join(REPO_ROOT, ".gitconfig.template"),
             f"alias.{name}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    @pytest.fixture
    def pushf_env(self, git_env, repo):
        """`me` (the repo fixture's clone, on a pushed feature branch) and a
        teammate clone; the template's pushf alias is installed globally."""
        _git(git_env, "config", "--global", "alias.pushf", self._template_alias("pushf"))
        _git(repo, "switch", "-q", "-c", "feature")
        _commit(repo, "a.txt", "my work")
        _git(repo, "push", "-q", "-u", "origin", "feature")
        mate = git_env / "mate"
        _git(git_env, "clone", "-q", "-b", "feature", str(git_env / "remote.git"), str(mate))
        _commit(mate, "b.txt", "teammate work")
        _git(mate, "push", "-q", "origin", "feature")
        return repo, mate, _git(mate, "rev-parse", "HEAD")

    @staticmethod
    def _remote_feature(repo):
        return _git(repo, "ls-remote", "origin", "refs/heads/feature").split()[0]

    def test_template_alias_includes_both_flags(self):
        args = self._template_alias("pushf").split()
        assert args[0] == "push"
        assert "--force-with-lease" in args
        assert "--force-if-includes" in args

    def test_bare_lease_clobbers_after_background_fetch(self, pushf_env):
        # Control: shows the hole the alias closes.
        me, _, mate_tip = pushf_env
        _git(me, "fetch", "-q")
        _git(me, "commit", "-q", "--amend", "-m", "my work, amended")
        _git(me, "push", "-q", "--force-with-lease")
        assert self._remote_feature(me) != mate_tip

    def test_pushf_rejects_after_background_fetch(self, pushf_env):
        me, _, mate_tip = pushf_env
        _git(me, "fetch", "-q")
        _git(me, "commit", "-q", "--amend", "-m", "my work, amended")
        result = subprocess.run(["git", "pushf"], cwd=me, capture_output=True, text=True)
        assert result.returncode != 0
        # Rejected by the push check itself, not some unrelated failure.
        assert "[rejected]" in result.stderr
        assert self._remote_feature(me) == mate_tip

    def test_pushf_allowed_once_remote_work_is_integrated(self, pushf_env):
        me, _, _ = pushf_env
        _git(me, "fetch", "-q")
        _git(me, "rebase", "-q", "origin/feature")
        _git(me, "commit", "-q", "--amend", "-m", "teammate work, reworded")
        subprocess.run(["git", "pushf"], cwd=me, check=True, capture_output=True, text=True)
        remote_tip = self._remote_feature(me)
        assert remote_tip == _git(me, "rev-parse", "HEAD")
        # The teammate's change survives in the rewritten history.
        assert (me / "b.txt").exists()
        assert _git(me, "show", "-s", "--format=%B", remote_tip) == "teammate work, reworded"


# --------------------------------------------------------------------------
# print_aliases: selection mode (`git alias --out`, the Ctrl-G widgets)
# --------------------------------------------------------------------------

class TestPrintAliasesSelectionMode:
    """Selection mode must fail loudly when the browser can't run (#254).

    Before, `--out` with no TTY (the PowerShell widget's redirected stdout)
    printed nothing and exited 0, so Ctrl-G silently did nothing.
    """

    @staticmethod
    def _run(tmp_path, *args):
        # Isolated global config with one known alias; captured stdout/stderr
        # are pipes, i.e. exactly the "no TTY" case.
        cfg = tmp_path / "gitconfig"
        cfg.write_text("[alias]\n\tst = status\n", encoding="utf-8")
        env = dict(os.environ, GIT_CONFIG_GLOBAL=str(cfg), GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(
            [sys.executable, HELPER_PATH, "print_aliases", *args],
            capture_output=True, text=True, env=env, cwd=tmp_path,
        )

    def test_out_without_tty_exits_nonzero_with_stderr_message(self, tmp_path):
        out = tmp_path / "selection with space.txt"
        out.write_text("", encoding="utf-8")
        result = self._run(tmp_path, "--out", str(out))
        assert result.returncode == 1
        assert "git alias --out" in result.stderr
        assert "not a terminal" in result.stderr
        assert result.stdout == ""  # no static table dumped into the widget
        assert out.read_text(encoding="utf-8") == ""

    def test_piped_without_out_still_prints_table(self, tmp_path):
        # install.ps1 runs `git alias | Out-Null`; `git alias | grep` must work.
        result = self._run(tmp_path)
        assert result.returncode == 0
        assert "Git Aliases" in result.stdout
        assert "st" in result.stdout
        assert "git alias --out" not in result.stderr

    def test_plain_with_out_stays_silent_and_succeeds(self, tmp_path):
        result = self._run(tmp_path, "--plain", "--out", str(tmp_path / "o"))
        assert result.returncode == 0
        assert result.stdout == ""

    def test_out_on_tty_when_browser_unavailable_fails_loudly(
        self, helper, monkeypatch, capsys, tmp_path
    ):
        monkeypatch.setattr(helper, "get_git_aliases", lambda: [])
        monkeypatch.setattr(helper.sys.stdout, "isatty", lambda: True)
        monkeypatch.setattr(
            helper, "_launch_alias_browser",
            lambda aliases, select_out=None: (False, "textual is missing"),
        )
        rc = helper.print_aliases(select_out=str(tmp_path / "o"))
        captured = capsys.readouterr()
        assert rc == 1
        assert "git alias --out: textual is missing" in captured.err
        assert "Git Aliases" not in captured.out

    def test_out_on_tty_when_browser_runs_returns_zero(
        self, helper, monkeypatch, capsys, tmp_path
    ):
        seen = {}
        monkeypatch.setattr(helper, "get_git_aliases", lambda: [])
        monkeypatch.setattr(helper.sys.stdout, "isatty", lambda: True)

        def fake_launch(aliases, select_out=None):
            seen["select_out"] = select_out
            return True, None

        monkeypatch.setattr(helper, "_launch_alias_browser", fake_launch)
        target = str(tmp_path / "o")
        assert helper.print_aliases(select_out=target) == 0
        assert seen["select_out"] == target
        assert capsys.readouterr().err == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
