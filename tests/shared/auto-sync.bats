#!/usr/bin/env bats
#
# Auto-sync must actually run (issue #225): the login/daily updater and the
# installers that schedule it (cron on Linux, launchd on macOS).
#
# Everything runs in a mktemp sandbox: HOME, the repos and the crontab are all
# fake, so the developer's real config, crontab and LaunchAgents are untouched.
#
# Run with:  bats tests/shared/auto-sync.bats
# Requires:  bats-core (>= 1.5), git and python3 (to parse the generated plist).

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME" "$SANDBOX/bin"

    # Isolate git from the developer's global/system config. Commits made by the
    # tests themselves are unsigned and use a fixed identity.
    unset GIT_CONFIG_GLOBAL
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

    # The installers call install_python_deps, which would pip-install into the
    # real user site. Stub every interpreter it probes so it skips cleanly.
    for p in py python3 python; do
        printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/$p"
        chmod +x "$SANDBOX/bin/$p"
    done
}

teardown() {
    rm -rf "$SANDBOX"
}

_git() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# A bare "origin" plus a clone of it at $SANDBOX/clone that contains the shared
# updater (so the updater's own location points at the clone).
_make_clone() {
    _git init -q --bare "$SANDBOX/origin.git"
    _git clone -q "$SANDBOX/origin.git" "$SANDBOX/clone" 2>/dev/null
    mkdir -p "$SANDBOX/clone/scripts/shared"
    cp "$REPO_ROOT/scripts/shared/update-gitconfig.sh" "$REPO_ROOT/scripts/shared/functions.sh" \
        "$SANDBOX/clone/scripts/shared/"
    # The updater exits 1 when it can't converge ~/.gitconfig, so the clone
    # needs the template it renders.
    cp "$REPO_ROOT/.gitconfig.template" "$SANDBOX/clone/"
    printf 'docs/update-gitconfig.log\n' > "$SANDBOX/clone/.gitignore"
    _git -C "$SANDBOX/clone" add -A
    _git -C "$SANDBOX/clone" commit -q -m "initial"
    _git -C "$SANDBOX/clone" push -q -u origin main 2>/dev/null
}

# Advance origin/main by one commit (made in a throwaway second clone).
_advance_origin() {
    _git clone -q "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
    echo "upstream change" > "$SANDBOX/other/upstream.txt"
    _git -C "$SANDBOX/other" add upstream.txt
    _git -C "$SANDBOX/other" commit -q -m "upstream change"
    _git -C "$SANDBOX/other" push -q origin main 2>/dev/null
    git -C "$SANDBOX/other" rev-parse HEAD
}

_updater_log() { cat "$SANDBOX/clone/docs/update-gitconfig.log"; }

# ---------------------------------------------------------------------------
# scripts/shared/update-gitconfig.sh
# ---------------------------------------------------------------------------

@test "updater with a missing repo path fails loudly and creates nothing" {
    run bash "$REPO_ROOT/scripts/shared/update-gitconfig.sh" "$SANDBOX/no-such-repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Repository path not found: $SANDBOX/no-such-repo"* ]]
    # The old order ran `mkdir -p <path>/docs` first, which made the check pass.
    [ ! -e "$SANDBOX/no-such-repo" ]
}

@test "updater defaults to the repo it lives in, not ~/Documents/Scripts/gitconfig" {
    _make_clone
    run bash "$SANDBOX/clone/scripts/shared/update-gitconfig.sh"
    [ "$status" -eq 0 ]
    [ -f "$SANDBOX/clone/docs/update-gitconfig.log" ]
    [ ! -e "$HOME/Documents" ]
    [[ "$(_updater_log)" == *"Repository synchronization completed"* ]]
}

@test "updater on main fast-forwards it" {
    _make_clone
    upstream="$(_advance_origin)"
    run bash "$SANDBOX/clone/scripts/shared/update-gitconfig.sh" "$SANDBOX/clone"
    [ "$status" -eq 0 ]
    [ "$(git -C "$SANDBOX/clone" rev-parse main)" = "$upstream" ]
    [[ "$(_updater_log)" == *"SUCCESS: repo up to date"* ]]
}

@test "updater leaves a feature branch checked out and fast-forwards main in place" {
    _make_clone
    _git -C "$SANDBOX/clone" switch -q -c feature/wip
    upstream="$(_advance_origin)"

    run bash "$SANDBOX/clone/scripts/shared/update-gitconfig.sh" "$SANDBOX/clone"
    [ "$status" -eq 0 ]
    # Still on the branch the user left...
    [ "$(git -C "$SANDBOX/clone" branch --show-current)" = "feature/wip" ]
    # ...and main caught up anyway.
    [ "$(git -C "$SANDBOX/clone" rev-parse main)" = "$upstream" ]
    [[ "$(_updater_log)" == *"still on 'feature/wip'"* ]]
}

@test "updater stays on a dirty feature branch too" {
    _make_clone
    _git -C "$SANDBOX/clone" switch -q -c feature/wip
    echo "edit" >> "$SANDBOX/clone/.gitignore"
    run bash "$SANDBOX/clone/scripts/shared/update-gitconfig.sh" "$SANDBOX/clone"
    [ "$status" -eq 0 ]
    [ "$(git -C "$SANDBOX/clone" branch --show-current)" = "feature/wip" ]
    grep -q '^edit$' "$SANDBOX/clone/.gitignore"
}

@test "updater runs every git command with GIT_TERMINAL_PROMPT=0" {
    _make_clone
    real_git="$(command -v git)"
    # A git wrapper that records the variable each call sees, then runs git.
    cat > "$SANDBOX/bin/git" <<EOF
#!/bin/sh
echo "\${GIT_TERMINAL_PROMPT-unset}" >> "$SANDBOX/prompt-seen"
exec "$real_git" "\$@"
EOF
    chmod +x "$SANDBOX/bin/git"

    run env -u GIT_TERMINAL_PROMPT PATH="$SANDBOX/bin:$PATH" \
        bash "$SANDBOX/clone/scripts/shared/update-gitconfig.sh" "$SANDBOX/clone"
    [ "$status" -eq 0 ]
    [ -s "$SANDBOX/prompt-seen" ]
    # Every recorded value is 0: no call could fall back to a terminal prompt.
    [ "$(sort -u "$SANDBOX/prompt-seen")" = "0" ]
}

# ---------------------------------------------------------------------------
# Installers
# ---------------------------------------------------------------------------

@test "no shell script uses ((X++)), which returns 1 at zero and trips set -e" {
    run ! grep -rnE '\(\([A-Za-z_]+(\+\+|--)\)\)' "$REPO_ROOT/scripts" --include='*.sh'
}

# A crontab stub backed by a file: `crontab -l` prints it, `crontab -` replaces it
# once stdin ends (like real crontab), so `crontab -l | ... | crontab -` is safe.
_stub_crontab() {
    cat > "$SANDBOX/bin/crontab" <<EOF
#!/bin/sh
case "\$1" in
    -l) [ -f "$SANDBOX/crontab.txt" ] || exit 1; cat "$SANDBOX/crontab.txt" ;;
    -)  cat > "$SANDBOX/crontab.new" && mv "$SANDBOX/crontab.new" "$SANDBOX/crontab.txt" ;;
    *)  exit 2 ;;
esac
EOF
    chmod +x "$SANDBOX/bin/crontab"
}

@test "linux install puts the repo path in the cron entry" {
    _stub_crontab
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Created cron job"* ]]
    # The job runs the shared updater directly (issue #229) with this clone's path.
    grep -qF "\"$REPO_ROOT/scripts/shared/update-gitconfig.sh\" \"$REPO_ROOT\"" "$SANDBOX/crontab.txt"
}

@test "linux install tags its cron line and replaces it instead of adding a second" {
    _stub_crontab
    for _ in 1 2; do
        run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
            bash "$REPO_ROOT/scripts/linux version/install.sh" --force
        [ "$status" -eq 0 ]
    done
    # Exactly one line, and it ends with the marker cleanup removes it by.
    [ "$(grep -c 'update-gitconfig.sh' "$SANDBOX/crontab.txt")" -eq 1 ]
    grep -qE ' # gitconfig-autoupdate$' "$SANDBOX/crontab.txt"
    # The marker is a shell comment: the line still parses as one command.
    line="$(grep -F 'gitconfig-autoupdate' "$SANDBOX/crontab.txt")"
    sh -n -c "${line#0 9 \* \* \* }"
}

@test "linux install migrates an untagged cron line from an older install" {
    _stub_crontab
    # What the pre-#229 Linux installer wrote: the per-OS wrapper, no marker.
    printf '0 8 * * * echo keep-me\n0 9 * * * bash "/old/clone/scripts/linux version/update-gitconfig.sh" "/old/clone" >> /tmp/gitconfig-update.log 2>&1\n' \
        > "$SANDBOX/crontab.txt"
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Created cron job"* ]]
    [ "$(grep -c 'update-gitconfig.sh' "$SANDBOX/crontab.txt")" -eq 1 ]
    run ! grep -qF '/old/clone' "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
}

@test "linux cleanup removes an untagged cron line from an older install" {
    _stub_crontab
    printf '0 8 * * * echo keep-me\n0 9 * * * bash "/old/clone/scripts/linux version/update-gitconfig.sh" "/old/clone" >> /tmp/gitconfig-update.log 2>&1\n' \
        > "$SANDBOX/crontab.txt"
    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed cron job"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    run ! grep -qF "update-gitconfig.sh" "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
}

@test "linux install verifies the cron job and prints the error summary" {
    _stub_crontab
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] cron job verified"* ]]
    [[ "$output" == *"Verify your git aliases:"* ]]
}

@test "--no-scheduler and the old per-OS spellings all skip the job" {
    _stub_crontab
    for flag in --no-scheduler --no-cron --no-launchd; do
        run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
            bash "$REPO_ROOT/scripts/linux version/install.sh" --force "$flag"
        [ "$status" -eq 0 ]
        [[ "$output" != *"[STEP 5]"* ]]
        [ ! -e "$SANDBOX/crontab.txt" ]
    done
}

# $1 = the value `uname -s` should print
_stub_uname() {
    printf '#!/bin/sh\necho %s\n' "$1" > "$SANDBOX/bin/uname"
    chmod +x "$SANDBOX/bin/uname"
}

@test "scripts/unix/install.sh on a Linux host schedules a cron job" {
    _stub_crontab
    _stub_uname Linux
    run env -u GITCONFIG_PLATFORM -u GITCONFIG_ALLOW_CROSS_OS PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/unix/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"GitConfig Setup (Linux)"* ]]
    [[ "$output" == *"[OK] Created cron job"* ]]
    grep -qF 'gitconfig-autoupdate' "$SANDBOX/crontab.txt"
    [ ! -e "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]
    grep -qF '(Linux)' "$HOME/.gitconfig.local"
}

@test "scripts/unix/install.sh on a macOS host registers a launchd agent" {
    _stub_crontab
    _stub_uname Darwin
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/launchctl"
    chmod +x "$SANDBOX/bin/launchctl"
    # The macOS file-owner probe uses BSD stat; HOMEBREW_REPO keeps it unused.
    run env -u GITCONFIG_PLATFORM -u GITCONFIG_ALLOW_CROSS_OS PATH="$SANDBOX/bin:$PATH" \
        HOMEBREW_REPO="$SANDBOX/no-such-brew" GITCONFIG_OP_SSH_SIGN="" \
        bash "$REPO_ROOT/scripts/unix/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"GitConfig Setup (macOS)"* ]]
    [[ "$output" == *"[OK] launchd agent verified"* ]]
    [ -f "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]
    [ ! -e "$SANDBOX/crontab.txt" ]
    grep -qF 'helper = osxkeychain' "$HOME/.gitconfig.local"

    run env -u GITCONFIG_PLATFORM PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/unix/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed launchd plist"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    [ ! -e "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]
}

# A PATH dir ($SANDBOX/sysbin) with the usual tools but no crontab binary.
_path_without_crontab() {
    mkdir -p "$SANDBOX/sysbin"
    for dir in /usr/local/bin /usr/bin /bin; do
        [ -d "$dir" ] || continue
        for tool in "$dir"/*; do
            name="${tool##*/}"
            [ "$name" = crontab ] && continue
            [ -e "$SANDBOX/sysbin/$name" ] || [ -L "$SANDBOX/sysbin/$name" ] || ln -s "$tool" "$SANDBOX/sysbin/$name"
        done
    done
    run env PATH="$SANDBOX/bin:$SANDBOX/sysbin" bash -c 'command -v crontab'
    [ "$status" -ne 0 ]
}

@test "linux cleanup removes the cron entry install added" {
    _stub_crontab
    printf '0 8 * * * echo keep-me\n' > "$SANDBOX/crontab.txt"
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    grep -qF "update-gitconfig.sh" "$SANDBOX/crontab.txt"

    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed cron job"* ]]
    run ! grep -qF "update-gitconfig.sh" "$SANDBOX/crontab.txt"
    # Other users' entries survive.
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
}

@test "linux cleanup finishes when crontab is not installed" {
    _path_without_crontab
    run env PATH="$SANDBOX/bin:$SANDBOX/sysbin" \
        bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"crontab not found"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
}

@test "linux install finishes when crontab is not installed" {
    _path_without_crontab

    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$SANDBOX/sysbin" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"crontab not found"* ]]
    # The steps after the cron step still ran.
    [[ "$output" == *"[STEP 7] Verifying setup"* ]]
    [[ "$output" == *"Setup Complete!"* ]]
}

@test "mac install writes a launchd plist with the repo path and a Homebrew PATH" {
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/launchctl"
    chmod +x "$SANDBOX/bin/launchctl"
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/mac version/install.sh" --force
    [ "$status" -eq 0 ]

    plist="$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    [ -f "$plist" ]
    # Parse it as a real plist, not by grepping text.
    run python3 - "$plist" "$REPO_ROOT" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    p = plistlib.load(f)
repo = sys.argv[2]
assert p["ProgramArguments"][-1] == repo, p["ProgramArguments"]
assert p["ProgramArguments"][1] == repo + "/scripts/shared/update-gitconfig.sh", p["ProgramArguments"]
path = p["EnvironmentVariables"]["PATH"].split(":")
assert "/opt/homebrew/bin" in path and "/usr/local/bin" in path, path
assert path.index("/opt/homebrew/bin") < path.index("/usr/bin"), path
PY
    [ "$status" -eq 0 ]
}

@test "mac cleanup with only the launchd plist left still completes" {
    # Nothing to back up, so REMOVED is 0 when the plist is removed; the old
    # ((REMOVED++)) returned 1 there and set -e ended the script.
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/launchctl"
    chmod +x "$SANDBOX/bin/launchctl"
    mkdir -p "$HOME/Library/LaunchAgents"
    : > "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"

    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/mac version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    [ ! -e "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]
}
