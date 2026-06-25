#!/usr/bin/env python3
"""Print the project's declared Python dependencies from pyproject.toml.

Usage: deps.py {required|optional|all}
  required  core deps ([project] dependencies)        -> one spec per line
  optional  the 'tui' optional-dependencies group     -> one spec per line
  all       both                                       -> one spec per line

No third-party imports: this runs to *bootstrap* installing 'rich'/'textual', so
it must work on a bare interpreter. Uses tomllib (Python 3.11+) when available,
otherwise a small regex fallback that handles this repo's simple manifest layout.
One spec per line so callers can read them into an array without word-splitting
on version operators or PEP 508 spaces.
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
# pyproject.toml lives at the repo root: scripts/shared/ -> ../../
PYPROJECT = os.path.normpath(os.path.join(_HERE, "..", "..", "pyproject.toml"))


def _load_required_optional():
    """Return (required_list, optional_tui_list) of requirement strings."""
    try:
        import tomllib  # Python 3.11+
        with open(PYPROJECT, "rb") as fh:
            data = tomllib.load(fh)
        project = data.get("project", {})
        required = list(project.get("dependencies", []))
        optional = list(project.get("optional-dependencies", {}).get("tui", []))
        return required, optional
    except ModuleNotFoundError:
        pass  # fall through to the regex fallback

    with open(PYPROJECT, encoding="utf-8") as fh:
        text = fh.read()

    def _array(pattern):
        match = re.search(pattern, text, re.DOTALL)
        if not match:
            return []
        return re.findall(r"""["']([^"']+)["']""", match.group(1))

    # `^\s*dependencies\s*=` matches the core array but not the
    # `[project.optional-dependencies]` table header or a `tui =` sub-key.
    required = _array(r"(?m)^\s*dependencies\s*=\s*\[(.*?)\]")
    optional = _array(r"(?ms)^\s*tui\s*=\s*\[(.*?)\]")
    return required, optional


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    required, optional = _load_required_optional()
    if which == "required":
        out = required
    elif which == "optional":
        out = optional
    else:
        out = required + optional
    for spec in out:
        print(spec)


if __name__ == "__main__":
    main()
