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
    # The cron log lives under XDG_STATE_HOME when it's set, the systemd units
    # under XDG_CONFIG_HOME; keep both in HOME.
    unset XDG_STATE_HOME XDG_CONFIG_HOME
    # The scheduler must never reach the real systemd user manager: no session
    # bus, and a systemctl that finds no user manager, so the Linux installer
    # uses cron. The systemd tests replace it with _stub_systemctl.
    unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
    printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/systemctl"
    chmod +x "$SANDBOX/bin/systemctl"

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

@test "linux install logs the cron job per user and creates the log directory (#259)" {
    _stub_crontab
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Log: $HOME/.local/state/gitconfig/gitconfig-update.log"* ]]
    # A shared /tmp log that another user owns makes sh skip the whole job.
    run ! grep -qF '/tmp/gitconfig-update.log' "$SANDBOX/crontab.txt"
    grep -qF ">> \"$HOME/.local/state/gitconfig/gitconfig-update.log\" 2>&1" "$SANDBOX/crontab.txt"
    # The >> redirect can't create a directory, so install must.
    [ -d "$HOME/.local/state/gitconfig" ]
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

# What the pre-#229 Linux installer wrote for this clone: the per-OS wrapper,
# no marker, the shared /tmp log. Plus another clone's job, which is not ours.
_old_crontab() {
    {
        echo '0 8 * * * echo keep-me'
        printf '0 9 * * * bash "%s/scripts/linux version/update-gitconfig.sh" "%s" >> /tmp/gitconfig-update.log 2>&1\n' \
            "$REPO_ROOT" "$REPO_ROOT"
        echo '0 9 * * * bash "/other/clone/scripts/shared/update-gitconfig.sh" "/other/clone" >> /tmp/gitconfig-update.log 2>&1 # gitconfig-autoupdate'
    } > "$SANDBOX/crontab.txt"
}

@test "linux install migrates an untagged cron line from an older install" {
    _stub_crontab
    _old_crontab
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Created cron job"* ]]
    [ "$(grep -cF "\"$REPO_ROOT/scripts/" "$SANDBOX/crontab.txt")" -eq 1 ]
    run ! grep -qF "$REPO_ROOT/scripts/linux version/" "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
    # Another clone's job is left alone (#259).
    grep -qF '"/other/clone/scripts/shared/update-gitconfig.sh"' "$SANDBOX/crontab.txt"
}

@test "linux cleanup removes an untagged cron line from an older install" {
    _stub_crontab
    _old_crontab
    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed cron job"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    run ! grep -qF "$REPO_ROOT/scripts/" "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
    # Another clone's job is left alone (#259).
    grep -qF '"/other/clone/scripts/shared/update-gitconfig.sh"' "$SANDBOX/crontab.txt"
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

@test "linux cleanup exits 2 when the prompt has no answer (#258)" {
    _stub_crontab
    printf '[user]\n\tname = Mine\n' > "$HOME/.gitconfig"
    # The prompt's read used to fail at end of input and end the run, under
    # set -e, with exit 1 and no message.
    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"Cancelled."* ]]
    grep -qF "name = Mine" "$HOME/.gitconfig"
}

@test "linux cleanup exits 1 when something could not be removed (#258)" {
    # A crontab that lists this clone's job (only that is ours, #259) but
    # refuses every rewrite.
    cat > "$SANDBOX/bin/crontab" <<EOF
#!/bin/sh
[ "\$1" = -l ] || exit 1
echo '0 9 * * * bash "$REPO_ROOT/scripts/shared/update-gitconfig.sh" "$REPO_ROOT" # gitconfig-autoupdate'
EOF
    chmod +x "$SANDBOX/bin/crontab"
    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] cron job still exists!"* ]]
    [[ "$output" == *"Cleanup INCOMPLETE"* ]]
}

# ---------------------------------------------------------------------------
# launchctl bootstrap/bootout and the install-time race (issue #234)
# ---------------------------------------------------------------------------

# A launchctl that logs each call to $SANDBOX/launchctl.log. `bootout` exits
# $BOOTOUT_RC (default 0); on `bootstrap` it records whether the update lock is
# held at that moment, as the RunAtLoad sync would find it.
_stub_launchctl() {
    cat > "$SANDBOX/bin/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$SANDBOX/launchctl.log"
case "\$1" in
    bootout) exit \${BOOTOUT_RC:-0} ;;
    bootstrap)
        if [ -d "$HOME/.local/state/gitconfig/update.lock" ]; then
            echo "lock held at bootstrap" >> "$SANDBOX/launchctl.log"
        fi
        ;;
esac
exit 0
EOF
    chmod +x "$SANDBOX/bin/launchctl"
}

@test "mac install uses launchctl bootstrap/bootout, never the deprecated load/unload" {
    _stub_launchctl
    uid="$(id -u)"
    plist="$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/mac version/install.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] launchd agent registered"* ]]
    # The reload hint names the new commands too.
    [[ "$output" == *"launchctl bootstrap gui/$uid"* ]]
    [[ "$output" != *"launchctl unload"* ]]
    grep -qxF "bootout gui/$uid/com.gitconfig.update" "$SANDBOX/launchctl.log"
    grep -qxF "bootstrap gui/$uid $plist" "$SANDBOX/launchctl.log"
    run ! grep -qE '^(load|unload)( |$)' "$SANDBOX/launchctl.log"

    # Re-installing unloads the running copy before bootstrapping again.
    : > "$SANDBOX/launchctl.log"
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/mac version/install.sh" --force
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$SANDBOX/launchctl.log")" = "bootout gui/$uid/com.gitconfig.update" ]
    grep -qxF "bootstrap gui/$uid $plist" "$SANDBOX/launchctl.log"
}

@test "mac install holds the update lock while the agent is bootstrapped, then releases it" {
    # RunAtLoad starts the updater the moment the agent is bootstrapped. It
    # used to run the same pip install as STEP 6 at the same time.
    _stub_launchctl
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/mac version/install.sh" --force
    [ "$status" -eq 0 ]
    grep -qxF "lock held at bootstrap" "$SANDBOX/launchctl.log"
    [ ! -e "$HOME/.local/state/gitconfig/update.lock" ]
}

@test "mac cleanup boots the agent out, and still removes the plist when it wasn't loaded" {
    _stub_launchctl
    uid="$(id -u)"
    mkdir -p "$HOME/Library/LaunchAgents"
    : > "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"

    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/mac version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Unloaded launchd agent"* ]]
    grep -qxF "bootout gui/$uid/com.gitconfig.update" "$SANDBOX/launchctl.log"
    run ! grep -qE '^(load|unload)( |$)' "$SANDBOX/launchctl.log"
    [ ! -e "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]

    # bootout fails for an agent that isn't loaded (launchctl exits 3 or 113).
    : > "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    run env BOOTOUT_RC=113 PATH="$SANDBOX/bin:$PATH" \
        bash "$REPO_ROOT/scripts/mac version/cleanup-gitconfig.sh" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP] launchd agent was not loaded"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    [ ! -e "$HOME/Library/LaunchAgents/com.gitconfig.update.plist" ]
}

# ---------------------------------------------------------------------------
# systemd user timer (issue #246)
# ---------------------------------------------------------------------------

# A systemctl stub for a host with a running user manager. Every call is
# logged to $SANDBOX/systemctl.log. `enable`/`disable` add and remove the
# timers.target.wants link like the real one. ENABLE_RC makes `enable` fail.
# Also a loginctl that reports Linger=${LINGER:-no}.
_stub_systemctl() {
    cat > "$SANDBOX/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$SANDBOX/systemctl.log"
[ "\$1" = --user ] || exit 1
wants="\$HOME/.config/systemd/user/timers.target.wants"
case "\$2" in
    show-environment|daemon-reload|stop) exit 0 ;;
    enable)  [ "\${ENABLE_RC:-0}" -eq 0 ] || exit "\$ENABLE_RC"
             mkdir -p "\$wants" && ln -sf ../gitconfig-update.timer "\$wants/gitconfig-update.timer" ;;
    disable) rm -f "\$wants/gitconfig-update.timer" ;;
    *)       exit 1 ;;
esac
EOF
    chmod +x "$SANDBOX/bin/systemctl"
    cat > "$SANDBOX/bin/loginctl" <<EOF
#!/bin/sh
[ "\$1" = show-user ] || exit 1
echo "Linger=\${LINGER:-no}"
EOF
    chmod +x "$SANDBOX/bin/loginctl"
}

_unit_dir() { echo "$HOME/.config/systemd/user"; }

_linux_install() {
    run env GITCONFIG_ALLOW_CROSS_OS=1 PATH="$SANDBOX/bin:$PATH" "$@" \
        bash "$REPO_ROOT/scripts/linux version/install.sh" --force
}

_linux_cleanup() {
    run env PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/linux version/cleanup-gitconfig.sh" --force
}

@test "linux install with a user manager writes and enables a daily systemd timer" {
    _stub_crontab
    _stub_systemctl
    _linux_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STEP 5] Setting up systemd timer..."* ]]
    [[ "$output" == *"[OK] Enabled systemd timer gitconfig-update.timer"* ]]
    [[ "$output" == *"Logs: journalctl --user -u gitconfig-update"* ]]
    [[ "$output" == *"[OK] systemd timer verified"* ]]

    service="$(_unit_dir)/gitconfig-update.service"
    timer="$(_unit_dir)/gitconfig-update.timer"
    grep -qx 'Type=oneshot' "$service"
    grep -qF "ExecStart=\"$(command -v bash)\" \"$REPO_ROOT/scripts/shared/update-gitconfig.sh\" \"$REPO_ROOT\"" "$service"
    grep -qx 'OnCalendar=daily' "$timer"
    grep -qx 'Persistent=true' "$timer"
    grep -qx 'WantedBy=timers.target' "$timer"
    grep -qx -- '--user daemon-reload' "$SANDBOX/systemctl.log"
    grep -qx -- '--user enable --now gitconfig-update.timer' "$SANDBOX/systemctl.log"
    # Never both: no cron line was written.
    [ ! -e "$SANDBOX/crontab.txt" ]
}

@test "installing the systemd timer removes this clone's cron lines, tagged and untagged" {
    _stub_crontab
    _stub_systemctl
    _old_crontab
    # Plus a tagged line from a later cron install of this clone.
    printf '0 9 * * * bash "%s/scripts/shared/update-gitconfig.sh" "%s" # gitconfig-autoupdate\n' \
        "$REPO_ROOT" "$REPO_ROOT" >> "$SANDBOX/crontab.txt"
    _linux_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed the old cron job (the timer replaces it)"* ]]
    [ -f "$(_unit_dir)/gitconfig-update.timer" ]
    run ! grep -qF "\"$REPO_ROOT/scripts/" "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
    # Another clone's job is not ours to remove.
    grep -qF '"/other/clone/scripts/shared/update-gitconfig.sh"' "$SANDBOX/crontab.txt"
}

@test "the systemd install hints at enable-linger only when linger is off" {
    _stub_crontab
    _stub_systemctl
    _linux_install LINGER=no
    [ "$status" -eq 0 ]
    [[ "$output" == *"loginctl enable-linger"* ]]
    # It's a hint: the installer never turns linger on itself.
    _linux_install LINGER=yes
    [ "$status" -eq 0 ]
    [[ "$output" != *"enable-linger"* ]]
}

@test "linux install falls back to cron when the timer can't be enabled" {
    _stub_crontab
    _stub_systemctl
    _linux_install ENABLE_RC=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not enable the systemd timer; using cron instead"* ]]
    [[ "$output" == *"[OK] Created cron job"* ]]
    [[ "$output" == *"[OK] cron job verified"* ]]
    [ ! -e "$(_unit_dir)/gitconfig-update.service" ]
    [ ! -e "$(_unit_dir)/gitconfig-update.timer" ]
    grep -qF 'gitconfig-autoupdate' "$SANDBOX/crontab.txt"
}

@test "linux install without a user manager uses cron and removes an old timer" {
    _stub_crontab
    # The default systemctl stub finds no user manager.
    mkdir -p "$(_unit_dir)/timers.target.wants"
    : > "$(_unit_dir)/gitconfig-update.service"
    : > "$(_unit_dir)/gitconfig-update.timer"
    ln -s ../gitconfig-update.timer "$(_unit_dir)/timers.target.wants/gitconfig-update.timer"
    _linux_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Created cron job"* ]]
    [[ "$output" == *"[OK] Removed the old systemd timer (the cron job replaces it)"* ]]
    [[ "$output" == *"[OK] cron job verified"* ]]
    [ ! -e "$(_unit_dir)/gitconfig-update.timer" ]
    [ ! -e "$(_unit_dir)/gitconfig-update.service" ]
    [ ! -L "$(_unit_dir)/timers.target.wants/gitconfig-update.timer" ]
}

@test "linux cleanup disables and removes the systemd timer, and a cron line too" {
    _stub_crontab
    _stub_systemctl
    _linux_install
    [ "$status" -eq 0 ]
    [ -L "$(_unit_dir)/timers.target.wants/gitconfig-update.timer" ]
    # A cron line that shouldn't be there alongside it.
    printf '0 8 * * * echo keep-me\n0 9 * * * bash "%s/scripts/shared/update-gitconfig.sh" "%s" # gitconfig-autoupdate\n' \
        "$REPO_ROOT" "$REPO_ROOT" > "$SANDBOX/crontab.txt"

    _linux_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STEP 3] Removing systemd timer..."* ]]
    [[ "$output" == *"[OK] Removed systemd timer: gitconfig-update.timer"* ]]
    [[ "$output" == *"[OK] Removed cron job"* ]]
    [[ "$output" == *"[OK] systemd timer removed"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    grep -qx -- '--user disable --now gitconfig-update.timer' "$SANDBOX/systemctl.log"
    [ ! -e "$(_unit_dir)/gitconfig-update.timer" ]
    [ ! -e "$(_unit_dir)/gitconfig-update.service" ]
    [ ! -L "$(_unit_dir)/timers.target.wants/gitconfig-update.timer" ]
    run ! grep -qF "$REPO_ROOT/scripts/" "$SANDBOX/crontab.txt"
    grep -qF "keep-me" "$SANDBOX/crontab.txt"
}

@test "linux cleanup removes the timer units even with no user manager running" {
    _stub_crontab
    mkdir -p "$(_unit_dir)/timers.target.wants"
    : > "$(_unit_dir)/gitconfig-update.service"
    : > "$(_unit_dir)/gitconfig-update.timer"
    ln -s ../gitconfig-update.timer "$(_unit_dir)/timers.target.wants/gitconfig-update.timer"
    _linux_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] Removed systemd timer"* ]]
    [[ "$output" == *"Cleanup SUCCESSFUL!"* ]]
    [ ! -e "$(_unit_dir)/gitconfig-update.timer" ]
    [ ! -L "$(_unit_dir)/timers.target.wants/gitconfig-update.timer" ]
}
