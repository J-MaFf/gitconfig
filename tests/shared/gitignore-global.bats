#!/usr/bin/env bats
#
# Bats suite for .gitignore_global — the excludesfile every repository on the
# machine inherits. It must ignore editor/OS junk and secrets, and nothing that
# a project might legitimately commit (lockfiles, bin/, lib/, .vscode/, ...).
#
# Run with:  bats tests/shared/gitignore-global.bats
# Requires:  bats-core and git.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GITIGNORE_GLOBAL="$REPO_ROOT/.gitignore_global"

    TESTDIR="$(mktemp -d)"
    export GIT_CONFIG_GLOBAL="$TESTDIR/gitconfig-global"
    export GIT_CONFIG_SYSTEM="$TESTDIR/no-system-config"
    : > "$GIT_CONFIG_GLOBAL"
    git config --global core.excludesfile "$GITIGNORE_GLOBAL"

    SCRATCH="$TESTDIR/scratch"
    git init -q "$SCRATCH"
}

teardown() {
    rm -rf "$TESTDIR"
}

# is_ignored PATH: succeeds when the global excludesfile ignores PATH in a
# repository with no .gitignore of its own.
is_ignored() {
    git -C "$SCRATCH" check-ignore -q --no-index "$1"
}

@test "ignores editor junk" {
    for p in foo.swp foo.swo foo~ '#foo#' .#foo .idea/workspace.xml foo.iml \
             proj.sublime-workspace .VSCodeCounter/report.md foo.orig foo.bak \
             .claude/settings.local.json; do
        is_ignored "$p" || { echo "not ignored: $p"; return 1; }
    done
}

@test "ignores OS junk" {
    for p in .DS_Store sub/.DS_Store Thumbs.db Desktop.ini .directory; do
        is_ignored "$p" || { echo "not ignored: $p"; return 1; }
    done
}

@test "ignores Python bytecode caches" {
    is_ignored __pycache__/mod.cpython-312.pyc
    is_ignored pkg/__pycache__/mod.cpython-312.pyc
}

@test "ignores secrets" {
    for p in .env .env.local .env.dev.local .secrets id.pem private.key \
             credentials.json .ssh/id_ed25519 .aws/credentials .pgpass; do
        is_ignored "$p" || { echo "not ignored: $p"; return 1; }
    done
}

@test "does not ignore files projects legitimately commit" {
    for p in package-lock.json yarn.lock Gemfile.lock Cargo.lock poetry.lock \
             bin/run lib/util.py .vscode/settings.json .vscode/extensions.json \
             build.bat install.cmd example.com setup.exe app.lnk \
             gradle/wrapper/gradle-wrapper.jar vendor/modules.txt dist/index.js \
             build/config.yml .vimrc plugin/foo.vim proj.code-workspace \
             config/local/settings.yaml site/index.md; do
        if is_ignored "$p"; then echo "unexpectedly ignored: $p"; return 1; fi
    done
}

@test "has no duplicate patterns" {
    run bash -c "grep -vE '^[[:space:]]*(#|$)' '$GITIGNORE_GLOBAL' | sort | uniq -d"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
