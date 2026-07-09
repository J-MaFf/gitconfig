#!/usr/bin/env bats
#
# Platform guards on the install.sh wrappers (issue #181).
#
# PR #180 guarded initialize-local-config.sh, but install.sh runs STEP 0
# (cleanup-gitconfig.sh --force, which moves an existing ~/.gitconfig.local to a
# backup) BEFORE it reaches that guard at STEP 3. So running the wrong platform's
# installer displaced the correct local config and then aborted mid-install.
# These tests pin that the installer now aborts BEFORE any destructive step, so
# ~/.gitconfig.local is never displaced.
#
# Run with:  bats tests/shared/install-platform-guard.bats
# Requires:  bats-core and git.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MAC_INSTALL="$REPO_ROOT/scripts/mac version/install.sh"
    LINUX_INSTALL="$REPO_ROOT/scripts/linux version/install.sh"

    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    # A correct machine-specific config that must survive a wrong-platform run.
    printf 'CORRECT-LOCAL-CONFIG\n' > "$SANDBOX/.gitconfig.local"

    # Stub uname so the "wrong platform" verdict can be forced on any host.
    mkdir -p "$SANDBOX/bin"
}

teardown() {
    rm -rf "$SANDBOX"
}

# $1 = the value `uname -s` should print
_stub_uname() {
    printf '#!/bin/sh\necho %s\n' "$1" > "$SANDBOX/bin/uname"
    chmod +x "$SANDBOX/bin/uname"
}

@test "mac installer aborts on a non-macOS host before any destructive step (issue #181)" {
    _stub_uname Linux
    run env -u GITCONFIG_ALLOW_CROSS_OS PATH="$SANDBOX/bin:$PATH" bash "$MAC_INSTALL" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"macOS installer"* ]]
    # STEP 0 (the destructive cleanup) was never reached...
    [[ "$output" != *"STEP 0"* ]]
    # ...so the correct local config is untouched and no backup was created.
    [ "$(cat "$SANDBOX/.gitconfig.local")" = "CORRECT-LOCAL-CONFIG" ]
    run bash -c "ls \"$SANDBOX\"/*.bak \"$SANDBOX\"/Existing* 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "linux installer aborts on macOS before any destructive step (issue #181)" {
    _stub_uname Darwin
    run env -u GITCONFIG_ALLOW_CROSS_OS PATH="$SANDBOX/bin:$PATH" bash "$LINUX_INSTALL" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"Linux installer"* ]]
    [[ "$output" != *"STEP 0"* ]]
    [ "$(cat "$SANDBOX/.gitconfig.local")" = "CORRECT-LOCAL-CONFIG" ]
    run bash -c "ls \"$SANDBOX\"/*.bak \"$SANDBOX\"/Existing* 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "both installers carry the GITCONFIG_ALLOW_CROSS_OS escape hatch" {
    # The override lets the sandboxed bats suites (and deliberate cross-OS runs)
    # past the guard; a full cross-OS install is out of scope for this suite.
    grep -qF 'GITCONFIG_ALLOW_CROSS_OS' "$MAC_INSTALL"
    grep -qF 'GITCONFIG_ALLOW_CROSS_OS' "$LINUX_INSTALL"
}
