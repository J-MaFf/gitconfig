# Pytest suite for scripts/shared/deps.py, the bootstrap script that lists the
# Python dependencies declared in pyproject.toml.
#
# Python 3.11+ reads the manifest with tomllib; older interpreters use a regex
# fallback. These tests force the fallback (by blocking `import tomllib`) and
# point it at throwaway manifests under tmp_path, so they cover the < 3.11 path
# on any interpreter. Where tomllib exists, the fallback is checked against it.
#
# Run with:  pytest tests/shared/test_deps.py

import importlib.util
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEPS_PATH = os.path.join(REPO_ROOT, "scripts", "shared", "deps.py")


@pytest.fixture
def deps():
    spec = importlib.util.spec_from_file_location("deps", DEPS_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _fallback(deps, monkeypatch, tmp_path, text):
    """Parse `text` as pyproject.toml with tomllib unavailable."""
    manifest = tmp_path / "pyproject.toml"
    manifest.write_text(text, encoding="utf-8")
    monkeypatch.setattr(deps, "PYPROJECT", str(manifest))
    monkeypatch.setitem(sys.modules, "tomllib", None)  # import -> ModuleNotFoundError
    return deps._load_required_optional()


def _tomllib(text):
    tomllib = pytest.importorskip("tomllib")
    project = tomllib.loads(text)["project"]
    return (
        list(project.get("dependencies", [])),
        list(project.get("optional-dependencies", {}).get("tui", [])),
    )


MANIFESTS = {
    "simple": """\
[project]
name = "x"
dependencies = [
    "rich>=13",
]

[project.optional-dependencies]
tui = [
    "textual>=0.50",
]
""",
    # #261: the ']' in an extra used to end the array early.
    "extras": """\
[project]
dependencies = [
    "rich[jupyter]>=13",
    "requests[socks,security]",
]

[project.optional-dependencies]
tui = ["textual[syntax]>=0.50"]
""",
    # #261: the quotes in a marker used to split the spec into fragments.
    "markers": """\
[project]
dependencies = [
    "rich>=13; python_version >= '3.8'",
    'tomli>=1.1; python_version < "3.11"',
]

[project.optional-dependencies]
tui = [
    "textual>=0.50 ; sys_platform != 'win32'",
]
""",
    "comments-and-single-line": """\
[project]
dependencies = ["rich>=13", "click"]  # core [deps]

[project.optional-dependencies]
tui = [
    # the browser ] needs this
    "textual>=0.50",  # trailing comment
]
""",
}

EXPECTED = {
    "simple": (["rich>=13"], ["textual>=0.50"]),
    "extras": (
        ["rich[jupyter]>=13", "requests[socks,security]"],
        ["textual[syntax]>=0.50"],
    ),
    "markers": (
        ["rich>=13; python_version >= '3.8'", 'tomli>=1.1; python_version < "3.11"'],
        ["textual>=0.50 ; sys_platform != 'win32'"],
    ),
    "comments-and-single-line": (["rich>=13", "click"], ["textual>=0.50"]),
}


@pytest.mark.parametrize("name", sorted(MANIFESTS))
def test_fallback_parses_manifest(deps, monkeypatch, tmp_path, name):
    required, optional = _fallback(deps, monkeypatch, tmp_path, MANIFESTS[name])
    assert (required, optional) == EXPECTED[name]


@pytest.mark.parametrize("name", sorted(MANIFESTS))
def test_fallback_matches_tomllib(deps, monkeypatch, tmp_path, name):
    expected = _tomllib(MANIFESTS[name])
    assert _fallback(deps, monkeypatch, tmp_path, MANIFESTS[name]) == expected


def test_fallback_reads_repo_manifest(deps, monkeypatch):
    with open(deps.PYPROJECT, encoding="utf-8") as fh:
        text = fh.read()
    expected = _tomllib(text) if sys.version_info >= (3, 11) else None
    monkeypatch.setitem(sys.modules, "tomllib", None)
    required, optional = deps._load_required_optional()
    assert any(spec.startswith("rich") for spec in required)
    assert any(spec.startswith("textual") for spec in optional)
    if expected is not None:
        assert (required, optional) == expected


def test_missing_arrays_give_empty_lists(deps, monkeypatch, tmp_path):
    assert _fallback(deps, monkeypatch, tmp_path, '[project]\nname = "x"\n') == ([], [])
