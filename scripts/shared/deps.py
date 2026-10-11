#!/usr/bin/env python3
"""Print the project's declared Python dependencies from pyproject.toml.

Usage: deps.py {required|optional|all}
  required  core deps ([project] dependencies)        -> one spec per line
  optional  the 'tui' optional-dependencies group     -> one spec per line
  all       both                                       -> one spec per line

No third-party imports: this runs to *bootstrap* installing 'rich'/'textual', so
it must work on a bare interpreter. Uses tomllib (Python 3.11+) when available,
otherwise a small regex fallback that reads the quoted strings (extras and
environment markers included) in the `dependencies` and `tui` arrays.
One spec per line so callers can read them into an array without word-splitting
on version operators or PEP 508 spaces.
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
# pyproject.toml lives at the repo root: scripts/shared/ -> ../../
PYPROJECT = os.path.normpath(os.path.join(_HERE, "..", "..", "pyproject.toml"))


# One token of a TOML array of strings: a basic "..." string (with backslash
# escapes), a literal '...' string, a comment, or the array's closing bracket.
# Matching whole strings first is what keeps a ']' or quote *inside* a spec --
# extras like "rich[jupyter]" or a marker like "x; python_version < '3.11'" --
# from ending the array or splitting the spec (#261).
_ARRAY_TOKEN = re.compile(r"""
    "(?P<basic>(?:[^"\\\n]|\\.)*)"
  | '(?P<literal>[^'\n]*)'
  | \#[^\n]*
  | (?P<close>\])
""", re.VERBOSE)


def _array_items(text, key):
    """Return the strings in the first `key = [ ... ]` array in a TOML text.

    Handles single- and multi-line arrays, comments and trailing commas. Not a
    TOML parser: multi-line (triple-quoted) strings are not supported, which a
    dependency list doesn't need.
    """
    # `^[ \t]*dependencies[ \t]*=` matches the core array but not the
    # `[project.optional-dependencies]` table header or a `tui =` sub-key.
    start = re.search(r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=[ \t]*\[", text)
    if not start:
        return []
    items = []
    for token in _ARRAY_TOKEN.finditer(text, start.end()):
        if token.group("close"):
            break
        if token.group("basic") is not None:
            items.append(re.sub(r"\\(.)", r"\1", token.group("basic")))
        elif token.group("literal") is not None:
            items.append(token.group("literal"))
    return items


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
    return _array_items(text, "dependencies"), _array_items(text, "tui")


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
