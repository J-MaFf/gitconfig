#!/usr/bin/env bats
#
# scripts/unix/move-scripts-root.sh (#304): moving the Scripts root out of
# ~/Documents and re-pointing everything that used it.
#
# Everything runs in a mktemp sandbox: HOME, the repos, the crontab, systemctl,
# launchctl, pgrep and stat are fake (stubs on PATH, logging their calls), the
# systemd user manager is never reached, and the system-scope folders the tool
# reports on come from GITCONFIG_MOVE_SYSROOT inside the sandbox. The tool runs
# from a copy of this repo inside the sandbox's old root, so the generators it
# re-runs act on the sandbox too. Linux behaviour is forced (GITCONFIG_PLATFORM)
# unless a test asks for macOS, so the results are the same on either runner.
#
# Run with:  bats tests/shared/move-scripts-root.bats
# Requires:  bats-core (>= 1.5) and git.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # The physical path: git records worktree paths with symlinks resolved,
    # and macOS's temp folder is under the /var -> /private/var link.
    SANDBOX="$(mktemp -d)"
    [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || return 1
    SANDBOX="$(cd "$SANDBOX" && pwd -P)" || return 1
    export HOME="$SANDBOX/home"
    FROM="$HOME/Documents/Scripts"
    TO="$HOME/Scripts"
    CLONE="$FROM/gitconfig"
    mkdir -p "$FROM" "$SANDBOX/bin" "$SANDBOX/sysroot"
    unset XDG_STATE_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS OneDrive OneDriveCommercial
    export GITCONFIG_MOVE_SYSROOT="$SANDBOX/sysroot"
    export GITCONFIG_ALLOW_CROSS_OS=1
    MOVE_OS=linux

    unset GIT_CONFIG_GLOBAL
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

    # crontab backed by a file; every install is logged.
    cat > "$SANDBOX/bin/crontab" <<EOF
#!/bin/sh
case "\$1" in
    -l) [ -f "$SANDBOX/crontab.txt" ] || exit 1; cat "$SANDBOX/crontab.txt" ;;
    -)  cat > "$SANDBOX/crontab.new" && mv "$SANDBOX/crontab.new" "$SANDBOX/crontab.txt"; echo install >> "$SANDBOX/crontab.log" ;;
    *)  exit 2 ;;
esac
EOF
    # systemctl: no user manager unless USER_MANAGER is set (so scheduler_install
    # uses cron); is-active succeeds for the units listed in STUB_ACTIVE_UNITS.
    cat > "$SANDBOX/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$SANDBOX/systemctl.log"
[ "\$1" = --user ] || exit 1
case "\$2" in
    show-environment) [ -n "\$USER_MANAGER" ] ;;
    is-active) for u in \$STUB_ACTIVE_UNITS; do [ "\$u" = "\$4" ] && exit 0; done; exit 3 ;;
    daemon-reload|restart|stop|disable) exit 0 ;;
    enable) [ -n "\$USER_MANAGER" ] ;;
    *) exit 1 ;;
esac
EOF
    printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\nexit 0\n' "$SANDBOX" > "$SANDBOX/bin/launchctl"
    printf '#!/bin/sh\necho Linger=yes\n' > "$SANDBOX/bin/loginctl"
    # pgrep finds "Google Drive" only when FAKE_DRIVE is set.
    printf '#!/bin/sh\n[ -n "$FAKE_DRIVE" ] && [ "$2" = "Google Drive" ]\n' > "$SANDBOX/bin/pgrep"
    chmod +x "$SANDBOX/bin/"*
    export PATH="$SANDBOX/bin:$PATH"
}

teardown() {
    case "${SANDBOX:-}" in
        */tmp.*) chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" ;;
    esac
}

_git() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# A copy of this repo at <From>/gitconfig, committed.
_make_clone() {
    mkdir -p "$CLONE"
    cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/.gitconfig.template" "$REPO_ROOT/.gitignore_global" \
        "$REPO_ROOT/gitconfig_helper.py" "$REPO_ROOT/pyproject.toml" "$CLONE/"
    _git -C "$CLONE" init -q
    _git -C "$CLONE" add -A
    _git -C "$CLONE" commit -q -m initial
}

# What install.sh leaves for the clone at <From>/gitconfig: ~/.gitconfig
# (with a ~/.gitconfig.local that a sync already marked migrated), the two
# home links, the cron line and the Ctrl-G block in ~/.bashrc.
_install_state() {
    printf '[gitconfig]\n\ttemplateKeysMigrated = true\n' > "$HOME/.gitconfig.local"
    : > "$HOME/.bashrc"
    (
        # shellcheck source=../../scripts/shared/functions.sh
        source "$CLONE/scripts/shared/functions.sh"
        # shellcheck source=../../scripts/shared/platform.sh
        source "$CLONE/scripts/shared/platform.sh"
        generate_gitconfig "$CLONE" "$HOME" true
        create_symlink "$CLONE/.gitignore_global" "$HOME/.gitignore_global" true "$CLONE"
        create_symlink "$CLONE/gitconfig_helper.py" "$HOME/gitconfig_helper.py" true "$CLONE"
        cron_entry "$CLONE" | crontab -
        SHELL=/bin/bash enable_git_alias_widget "$CLONE" "$HOME"
    ) > /dev/null
    rm -f "$SANDBOX/crontab.log"
}

# Run the tool from the sandbox clone (or TOOL) with no input to read.
_move() {
    local tool="${TOOL:-$CLONE/scripts/unix/move-scripts-root.sh}"
    run env GITCONFIG_PLATFORM="$MOVE_OS" bash "$tool" --from "$FROM" --to "$TO" "$@" < /dev/null
}

# Paths, link targets, sizes, write times and checksums of everything under DIR.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
_snapshot() {
    find "$1" -print | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p")"
        elif [ -f "$p" ]; then printf '%s %s %s %s\n' "$p" "$(wc -c < "$p" | tr -d ' ')" "$(_mtime "$p")" "$(cksum < "$p")"
        else printf '%s/\n' "$p"; fi
    done
}

_run_dir() { find "$HOME" -maxdepth 1 -name '.scripts-move-*' -type d | LC_ALL=C sort | tail -n 1; }

_fold() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# Options (R1)
# ---------------------------------------------------------------------------

@test "--help and -h print usage and exit 0" {
    for flag in --help -h; do
        run bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" "$flag"
        [ "$status" -eq 0 ]
        [[ "$output" == *"USAGE: scripts/unix/move-scripts-root.sh"* ]]
        for opt in --from --to --dry-run --yes --allow-synced-target; do
            [[ "$output" == *"$opt"* ]]
        done
        [[ "$output" == *'(default: $HOME/Documents/Scripts)'* ]]
        [[ "$output" == *'(default: $HOME/Scripts)'* ]]
    done
}

@test "defaults are \$HOME/Documents/Scripts and \$HOME/Scripts; an unknown option exits 1" {
    rmdir "$FROM"
    run env GITCONFIG_PLATFORM=linux bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" --dry-run < /dev/null
    [[ "$output" == *"From: $HOME/Documents/Scripts"* ]]
    [[ "$output" == *"To:   $HOME/Scripts"* ]]
    run bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" --dry-rn
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option: --dry-rn"* ]]
}

@test "the options are accepted together, also in --opt=value form" {
    _make_clone
    run env GITCONFIG_PLATFORM=linux bash "$CLONE/scripts/unix/move-scripts-root.sh" \
        --from="$FROM" --to="$TO" --dry-run --yes --allow-synced-target < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run: nothing was changed."* ]]
}

# ---------------------------------------------------------------------------
# Preflight (R3, R4)
# ---------------------------------------------------------------------------

@test "From and To the same, or nested: exit 1 and nothing changes (R3a)" {
    echo data > "$FROM/keep.txt"
    before="$(_snapshot "$HOME")"
    TOOL="$REPO_ROOT/scripts/unix/move-scripts-root.sh"
    run bash "$TOOL" --from "$FROM" --to "$FROM/" --yes < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"same folder, or one is inside the other"* ]]
    run bash "$TOOL" --from "$FROM" --to "$FROM/inner" --yes < /dev/null
    [ "$status" -eq 1 ]
    run bash "$TOOL" --from "$FROM/inner" --to "$FROM" --yes < /dev/null
    [ "$status" -eq 1 ]
    [ "$(_snapshot "$HOME")" = "$before" ]
}

@test "neither From nor To exists: exit 1 (R3b)" {
    before="$(_snapshot "$HOME")"
    run bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" --from "$HOME/nope" --to "$HOME/nope2" --yes < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Neither From ($HOME/nope) nor To ($HOME/nope2) exists."* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
}

@test "To exists and is not empty: exit 1 and From is unchanged (R3c)" {
    echo data > "$FROM/keep.txt"
    mkdir -p "$TO"
    echo other > "$TO/other.txt"
    before="$(_snapshot "$HOME")"
    TOOL="$REPO_ROOT/scripts/unix/move-scripts-root.sh" _move --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an empty folder"* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
}

@test "From and To's parent on different filesystems: exit 1 (R3d)" {
    echo data > "$FROM/keep.txt"
    mkdir -p "$SANDBOX/other-fs"
    # stat reports another device for the other filesystem.
    mkdir -p "$SANDBOX/statbin"
    cat > "$SANDBOX/statbin/stat" <<EOF
#!/bin/sh
for last; do :; done
case "\$last" in *"/other-fs"*) echo 99; exit 0 ;; esac
exec $(command -v stat) "\$@"
EOF
    chmod +x "$SANDBOX/statbin/stat"
    before="$(_snapshot "$HOME")"
    run env PATH="$SANDBOX/statbin:$PATH" bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" \
        --from "$FROM" --to "$SANDBOX/other-fs/Scripts" --yes < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"on different filesystems"* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
    [ ! -e "$SANDBOX/other-fs/Scripts" ]
}

@test "a To under ~/Documents is refused, and moved with --allow-synced-target (R4)" {
    echo data > "$FROM/keep.txt"
    before="$(_snapshot "$HOME")"
    TO="$HOME/Documents/Scripts2"
    TOOL="$REPO_ROOT/scripts/unix/move-scripts-root.sh" _move --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"a folder that cloud sync backs up"* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]

    TOOL="$REPO_ROOT/scripts/unix/move-scripts-root.sh" _move --yes --allow-synced-target
    [ "$status" -eq 0 ]
    [ -f "$TO/keep.txt" ]
    [ ! -e "$FROM" ]
    # This checkout isn't in the moved root: its generators are skipped and reported.
    [[ "$output" == *"generators were skipped"* ]]
}

@test "the other synced folders are refused too (R4)" {
    for dir in "$HOME/Desktop" "$HOME/Pictures" "$HOME/Library/CloudStorage/GoogleDrive" "$HOME/Google Drive" "$HOME/Dropbox"; do
        TO="$dir/Scripts"
        TOOL="$REPO_ROOT/scripts/unix/move-scripts-root.sh" _move --yes
        [ "$status" -eq 1 ]
        [[ "$output" == *"cloud sync"* ]]
    done
    run env OneDrive="$HOME/OneDrive" bash "$REPO_ROOT/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$HOME/OneDrive/S" --yes < /dev/null
    [ "$status" -eq 1 ]
    [ -d "$FROM" ]
}

# ---------------------------------------------------------------------------
# Google Drive (R5) and confirmation (R2, R6)
# ---------------------------------------------------------------------------

@test "Drive running on macOS: declining or no input exits 2 with nothing changed (R5)" {
    _make_clone
    before="$(_snapshot "$HOME")"
    MOVE_OS=macos
    run env FAKE_DRIVE=1 GITCONFIG_PLATFORM=macos bash "$CLONE/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$TO" <<< "n"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Google Drive for desktop is running"* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]

    run env FAKE_DRIVE=1 GITCONFIG_PLATFORM=macos bash "$CLONE/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$TO" < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"No answer (no input to read), so: no. Pass --yes to skip this prompt."* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]

    run env FAKE_DRIVE=1 GITCONFIG_PLATFORM=macos bash "$CLONE/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$TO" --yes < /dev/null
    [ "$status" -eq 0 ]
    [ -d "$TO/gitconfig" ]
}

@test "declining the plan exits 2 after printing it, with nothing changed (R2, R6)" {
    _make_clone
    before="$(_snapshot "$HOME")"
    run env GITCONFIG_PLATFORM=linux bash "$CLONE/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$TO" <<< "n"
    [ "$status" -eq 2 ]
    # (read -p shows the question only on a terminal.)
    [[ "$output" == *"Plan"*"Claude project folders to rename:"*"Cancelled. Nothing was changed."* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
    _move
    [ "$status" -eq 2 ]
    [[ "$output" == *"No answer"* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
}

# ---------------------------------------------------------------------------
# Plan, dry run (R6, R7)
# ---------------------------------------------------------------------------

# A machine with something in every category.
_full_fixture() {
    _make_clone
    _install_state
    mkdir -p "$FROM/agent-skills" "$FROM/tools" "$HOME/.claude/projects" "$HOME/.config/acme" "$HOME/.local/bin"
    ln -s "$FROM/agent-skills" "$HOME/.claude/skills"
    ln -s ../../Documents/Scripts/tools "$HOME/.config/acme/tools"
    printf '#!/bin/sh\n' > "$FROM/tools/tool"
    ln -s "$FROM/tools/tool" "$HOME/.local/bin/tool"
    printf '{"dir": "%s/x"}\n' "$FROM" > "$HOME/.claude/settings.json"
    printf '%s\n' "0 * * * * \"$FROM/tools/backup.sh\" >/dev/null # mine" >> "$SANDBOX/crontab.txt"
    mkdir -p "$HOME/.config/systemd/user" "$HOME/Library/LaunchAgents"
    printf '[Service]\nExecStart=%s/tools/a\n' "$FROM" > "$HOME/.config/systemd/user/mine-a.service"
    printf '[Service]\nExecStart=%s/tools/b\n' "$FROM" > "$HOME/.config/systemd/user/mine-b.service"
    printf '<plist version="1.0"><dict><key>Label</key><string>com.me.tool</string><key>Program</key><string>%s/tools/tool</string></dict></plist>\n' "$FROM" \
        > "$HOME/Library/LaunchAgents/com.me.tool.plist"
    ENC_FROM="$(printf '%s' "$FROM" | sed 's/[^A-Za-z0-9]/-/g')"
    ENC_TO="$(printf '%s' "$TO" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$HOME/.claude/projects/$ENC_FROM" "$HOME/.claude/projects/$ENC_FROM-gitconfig" "$HOME/.claude/projects/${ENC_FROM}Old"
    mkdir -p "$FROM/pyproj/.venv"
    printf 'home = /usr/bin\n' > "$FROM/pyproj/.venv/pyvenv.cfg"
    printf '{"projects": {"%s/gitconfig": {}}}\n' "$FROM" > "$HOME/.claude.json"
    mkdir -p "$SANDBOX/sysroot/etc/systemd/system"
    printf '[Service]\nExecStart=%s/tools/root\n' "$FROM" > "$SANDBOX/sysroot/etc/systemd/system/rooty.service"
}

@test "the plan lists every category with its items before any change (R6)" {
    _full_fixture
    run env GITCONFIG_PLATFORM=linux STUB_ACTIVE_UNITS=mine-a.service bash "$CLONE/scripts/unix/move-scripts-root.sh" \
        --from "$FROM" --to "$TO" --dry-run < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Move:"*"$FROM -> $TO (one rename)"* ]]
    [[ "$output" == *"Repos and worktrees to repair:"* ]]
    [[ "$output" == *"This repo's generators to re-run (from $TO/gitconfig):"*"generate_gitconfig"*"create_symlink"*"scheduler_install"*"enable_git_alias_widget"* ]]
    [[ "$output" == *"Files to rewrite:"*"$HOME/.claude/settings.json (1 match)"* ]]
    [[ "$output" == *"Links to re-point:"*"$HOME/.claude/skills -> $TO/agent-skills"* ]]
    [[ "$output" == *"$HOME/.config/acme/tools -> ../../Scripts/tools"* ]]
    [[ "$output" == *"Scheduled tasks and jobs to update:"*"crontab: 0 * * * * \"$FROM/tools/backup.sh\""* ]]
    [[ "$output" == *"systemd user unit $HOME/.config/systemd/user/mine-a.service (active: restarted)"* ]]
    [[ "$output" == *"launchd agent $HOME/Library/LaunchAgents/com.me.tool.plist (reloaded)"* ]]
    [[ "$output" == *"Claude project folders to rename:"*"$HOME/.claude/projects/$ENC_FROM-gitconfig -> $HOME/.claude/projects/$ENC_TO-gitconfig"* ]]
    [[ "$output" == *"Report only (not changed):"*"Python venv to recreate: $TO/pyproj/.venv"* ]]
    [[ "$output" == *"System scope: $SANDBOX/sysroot/etc/systemd/system/rooty.service"* ]]
    [[ "$output" == *"App state that mentions the old root: $HOME/.claude.json"* ]]
}

@test "--dry-run changes nothing at all (R7)" {
    _full_fixture
    before="$(_snapshot "$HOME")"
    cron_before="$(cat "$SANDBOX/crontab.txt")"
    _move --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run: nothing was changed."* ]]
    [ "$(_snapshot "$HOME")" = "$before" ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$cron_before" ]
    [ ! -e "$SANDBOX/crontab.log" ]
    [ -z "$(_run_dir)" ]
    run ! grep -qE '^--user (daemon-reload|restart)' "$SANDBOX/systemctl.log"
    [ ! -e "$SANDBOX/launchctl.log" ]
}

# ---------------------------------------------------------------------------
# Move (R8, R9, R10)
# ---------------------------------------------------------------------------

@test "a failed rename exits 1 and leaves everything in place (R8)" {
    _make_clone
    before="$(_snapshot "$HOME")"
    # Without write access to From's parent the rename fails.
    chmod 555 "$HOME/Documents"
    _move --yes
    chmod 755 "$HOME/Documents"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Close the programs and terminals that use files under it"* ]]
    [ -d "$CLONE" ]
    [ ! -e "$TO" ]
    [ "$(_snapshot "$HOME")" = "$before" ]
    [ -z "$(_run_dir)" ]
}

@test "the move is one mv of From to To, never a copy (R8)" {
    [ "$(grep -c 'mv -- "$FROM" "$TO"' "$REPO_ROOT/scripts/unix/move-scripts-root.sh")" -eq 1 ]
    run ! grep -nE '(cp -[a-zA-Z]*R|rsync|ditto)[^#]*FROM' "$REPO_ROOT/scripts/unix/move-scripts-root.sh"
}

@test "runs from its own copy inside From with the working directory inside From (R9)" {
    _make_clone
    cd "$CLONE/scripts"
    run env GITCONFIG_PLATFORM=linux bash ../scripts/unix/move-scripts-root.sh --from "$FROM" --to "$TO" --yes < /dev/null
    [ "$status" -eq 0 ]
    [ -f "$TO/gitconfig/.gitconfig.template" ]
    [ ! -e "$FROM" ]
}

@test "a second run changes nothing and exits 0 (R10)" {
    _full_fixture
    _move --yes
    [ "$status" -eq 0 ]
    tree="$(_snapshot "$HOME")"
    cron="$(cat "$SANDBOX/crontab.txt")"
    rm -f "$SANDBOX/crontab.log" "$SANDBOX/launchctl.log"
    TOOL="$TO/gitconfig/scripts/unix/move-scripts-root.sh" _move --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"already moved; resuming repairs"* ]]
    [[ "$output" == *"Nothing to do"* ]]
    [ "$(_snapshot "$HOME")" = "$tree" ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$cron" ]
    [ ! -e "$SANDBOX/crontab.log" ]
    [ ! -e "$SANDBOX/launchctl.log" ]
}

@test "after a manual move it resumes and finishes the repairs (R10)" {
    _make_clone
    _install_state
    mv "$FROM" "$TO"
    TOOL="$TO/gitconfig/scripts/unix/move-scripts-root.sh" _move --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"already moved; resuming repairs"* ]]
    grep -qF "$TO/gitconfig/gitconfig_helper.py" "$HOME/.gitconfig"
    run ! grep -qF "$FROM" "$HOME/.gitconfig"
    run ! grep -qF "$FROM" "$SANDBOX/crontab.txt"
}

# ---------------------------------------------------------------------------
# Repairs (R11-R17)
# ---------------------------------------------------------------------------

@test "worktrees inside the repo and beside it work after the move (R11)" {
    _make_clone
    _git -C "$CLONE" worktree add -q -b wt-in "$CLONE/.claude/worktrees/wt-in"
    _git -C "$CLONE" worktree add -q -b wt-out "$FROM/gitconfig-wt"
    _move --yes
    [ "$status" -eq 0 ]
    git -C "$TO/gitconfig/.claude/worktrees/wt-in" status --short
    git -C "$TO/gitconfig-wt" status --short
    list="$(git -C "$TO/gitconfig" worktree list --porcelain)"
    [[ "$list" != *prunable* ]]
    [[ "$list" != *"$FROM"* ]]
    [[ "$list" == *"worktree $TO/gitconfig-wt"* ]]
}

@test "this repo's generators re-run from the new clone (R12)" {
    _full_fixture
    _move --yes
    [ "$status" -eq 0 ]
    grep -qF "$TO/gitconfig/gitconfig_helper.py" "$HOME/.gitconfig"
    run ! grep -qF "$FROM" "$HOME/.gitconfig"
    [ "$(readlink "$HOME/.gitignore_global")" = "$TO/gitconfig/.gitignore_global" ]
    [ "$(readlink "$HOME/gitconfig_helper.py")" = "$TO/gitconfig/gitconfig_helper.py" ]
    grep -qF "\"$TO/gitconfig/scripts/shared/update-gitconfig.sh\" \"$TO/gitconfig\"" "$SANDBOX/crontab.txt"
    run ! grep -qF "$FROM" "$SANDBOX/crontab.txt"
    grep -qF "source \"$TO/gitconfig/scripts/shell/git-alias-widget.bash\"" "$HOME/.bashrc"
    run ! grep -qF "$FROM" "$HOME/.bashrc"
}

@test "with a user manager, the systemd timer is re-registered for the new clone (R12)" {
    _make_clone
    mkdir -p "$HOME/.config/systemd/user"
    printf '[Service]\nExecStart=/bin/bash "%s/gitconfig/scripts/shared/update-gitconfig.sh" "%s/gitconfig"\n' "$FROM" "$FROM" \
        > "$HOME/.config/systemd/user/gitconfig-update.service"
    printf '[Timer]\nOnCalendar=daily\n' > "$HOME/.config/systemd/user/gitconfig-update.timer"
    run env USER_MANAGER=1 GITCONFIG_PLATFORM=linux bash "$CLONE/scripts/unix/move-scripts-root.sh" --from "$FROM" --to "$TO" --yes < /dev/null
    [ "$status" -eq 0 ]
    grep -qF "\"$TO/gitconfig/scripts/shared/update-gitconfig.sh\" \"$TO/gitconfig\"" "$HOME/.config/systemd/user/gitconfig-update.service"
    run ! grep -qF "$FROM" "$HOME/.config/systemd/user/gitconfig-update.service"
    grep -qxF -- "--user enable --now gitconfig-update.timer" "$SANDBOX/systemctl.log"
}

@test "on macOS the launchd agent is re-registered for the new clone (R12)" {
    _make_clone
    mkdir -p "$HOME/Library/LaunchAgents"
    printf '<plist><dict><key>Label</key><string>com.gitconfig.update</string><string>%s/gitconfig/scripts/shared/update-gitconfig.sh</string></dict></plist>\n' "$FROM" \
        > "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    MOVE_OS=macos
    _move --yes
    [ "$status" -eq 0 ]
    grep -qF "<string>$TO/gitconfig/scripts/shared/update-gitconfig.sh</string>" "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    run ! grep -qF "$FROM" "$HOME/Library/LaunchAgents/com.gitconfig.update.plist"
    grep -qxF "bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/com.gitconfig.update.plist" "$SANDBOX/launchctl.log"
}

@test "links keep their kind and point under To; a relative link stays relative (R13)" {
    _full_fixture
    _move --yes
    [ "$status" -eq 0 ]
    [ -L "$HOME/.claude/skills" ]
    [ "$(readlink "$HOME/.claude/skills")" = "$TO/agent-skills" ]
    [ -L "$HOME/.config/acme/tools" ]
    [ "$(readlink "$HOME/.config/acme/tools")" = "../../Scripts/tools" ]
    [ -d "$HOME/.config/acme/tools" ]
    [ -L "$HOME/.local/bin/tool" ]
    [ "$(readlink "$HOME/.local/bin/tool")" = "$TO/tools/tool" ]
    [ ! -e "$FROM" ] && [ ! -L "$FROM" ]
}

# R14 fixture: FILE gets BEFORE, and AFTER is what it must become, byte for byte.
_fixture() {
    mkdir -p "$(dirname "$HOME/$1")"
    printf '%b' "$2" > "$HOME/$1"
    mkdir -p "$SANDBOX/expected/$(dirname "$1")"
    printf '%b' "$3" > "$SANDBOX/expected/$1"
    printf '%b' "$2" > "$SANDBOX/expected/$1.before"
    FIXTURES="${FIXTURES:-} $1"
}

_text_fixtures() {
    local up
    up="$(printf '%s' "$FROM" | tr '[:lower:]' '[:upper:]')"
    FIXTURES=""
    _fixture .gitconfig.local "[gitconfig]\n\ttemplateKeysMigrated = true\n[safe]\n\tdirectory = $FROM/gitconfig\n" \
        "[gitconfig]\n\ttemplateKeysMigrated = true\n[safe]\n\tdirectory = $TO/gitconfig\n"
    _fixture .config/gitconfig/safe-directories "# trusted\n$FROM/shared\n" "# trusted\n$TO/shared\n"
    # CRLF line endings, the end of a line and a quote as boundaries, a decoy.
    _fixture .bash_profile "export A=\"$FROM\"\r\nexport B=$FROM\r\nexport C=${FROM}Old/x\r\n" \
        "export A=\"$TO\"\r\nexport B=$TO\r\nexport C=${FROM}Old/x\r\n"
    # No final newline; ~ and \$HOME spellings.
    _fixture .zprofile "cd ~/Documents/Scripts/x && . \$HOME/Documents/Scripts/y" "cd ~/Scripts/x && . \$HOME/Scripts/y"
    _fixture .config/fish/config.fish "set -x P \${HOME}/Documents/Scripts/bin\nset -x Q /mnt$FROM/bin\n" \
        "set -x P \${HOME}/Scripts/bin\nset -x Q /mnt$FROM/bin\n"
    # A UTF-8 BOM is kept.
    _fixture .claude/settings.json "\0357\0273\0277{\"a\": \"$FROM/x\", \"b\": \"${FROM}Old\"}\n" \
        "\0357\0273\0277{\"a\": \"$TO/x\", \"b\": \"${FROM}Old\"}\n"
    _fixture .claude/scheduled-tasks/nightly/SKILL.md "Run \`$FROM/tool/run.sh\` in '$FROM'\n" "Run \`$TO/tool/run.sh\` in '$TO'\n"
    _fixture .vscode/workspaces/work.code-workspace \
        "{\r\n  \"folders\": [{\"path\": \"../../Documents/Scripts/gitconfig\"}, {\"path\": \"../../Documents/ScriptsOld\"}]\r\n}\r\n" \
        "{\r\n  \"folders\": [{\"path\": \"../../Scripts/gitconfig\"}, {\"path\": \"../../Documents/ScriptsOld\"}]\r\n}\r\n"
    _fixture .vscode/agent-plugins/acme/nested/.mcp.json "{\"command\": \"$FROM/mcp/server\"}\n" "{\"command\": \"$TO/mcp/server\"}\n"
    _fixture Documents/PowerShell/Microsoft.PowerShell_profile.ps1 "Set-Location '$FROM'\n" "Set-Location '$TO'\n"
    # Case: rewritten only where paths are case-insensitive (macOS).
    if [ "$MOVE_OS" = macos ]; then
        _fixture .profile "export U=\"$up/u\"\n" "export U=\"$TO/u\"\n"
    else
        _fixture .profile "export U=\"$up/u\"\n" "export U=\"$up/u\"\n"
    fi
}

@test "every path form is rewritten, decoys stay, bytes and line endings are kept (R14)" {
    _make_clone
    _text_fixtures
    _move --yes
    [ "$status" -eq 0 ]
    for f in $FIXTURES; do
        cmp "$HOME/$f" "$SANDBOX/expected/$f" || { echo "differs: $f"; cat -v "$HOME/$f"; false; }
    done
}

@test "on macOS a differently cased old root is rewritten too (R14)" {
    _make_clone
    MOVE_OS=macos
    _text_fixtures
    _move --yes
    [ "$status" -eq 0 ]
    cmp "$HOME/.profile" "$SANDBOX/expected/.profile"
}

@test "crontab, systemd units and launchd agents are rewritten and reloaded as needed (R17)" {
    _full_fixture
    run env GITCONFIG_PLATFORM=linux STUB_ACTIVE_UNITS=mine-a.service bash "$CLONE/scripts/unix/move-scripts-root.sh" \
        --from "$FROM" --to "$TO" --yes < /dev/null
    [ "$status" -eq 0 ]
    # The user's own line, rewritten; nothing left with the old root.
    grep -qF "0 * * * * \"$TO/tools/backup.sh\" >/dev/null # mine" "$SANDBOX/crontab.txt"
    run ! grep -qF "$FROM" "$SANDBOX/crontab.txt"
    # One install for the user's lines (the other replaced the auto-sync line).
    [ "$(grep -c install "$SANDBOX/crontab.log")" -le 3 ]
    grep -qxF "ExecStart=$TO/tools/a" "$HOME/.config/systemd/user/mine-a.service"
    grep -qxF "ExecStart=$TO/tools/b" "$HOME/.config/systemd/user/mine-b.service"
    grep -qxF -- "--user daemon-reload" "$SANDBOX/systemctl.log"
    grep -qxF -- "--user restart mine-a.service" "$SANDBOX/systemctl.log"
    run ! grep -qF -- "restart mine-b.service" "$SANDBOX/systemctl.log"
    grep -qF "<string>$TO/tools/tool</string>" "$HOME/Library/LaunchAgents/com.me.tool.plist"
    grep -qxF "bootout gui/$(id -u)/com.me.tool" "$SANDBOX/launchctl.log"
    grep -qxF "bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/com.me.tool.plist" "$SANDBOX/launchctl.log"
}

@test "the user crontab is rewritten in one install (R17)" {
    _make_clone
    printf '%s\n' "0 * * * * \"$FROM/a.sh\"" "5 * * * * $FROM/b.sh # $FROM" "10 * * * * ${FROM}Old/c.sh" > "$SANDBOX/crontab.txt"
    _move --yes
    [ "$status" -eq 0 ]
    [ "$(grep -c install "$SANDBOX/crontab.log")" -eq 1 ]
    [ "$(cat "$SANDBOX/crontab.txt")" = "$(printf '%s\n' "0 * * * * \"$TO/a.sh\"" "5 * * * * $TO/b.sh # $TO" "10 * * * * ${FROM}Old/c.sh")" ]
}

@test "only the Claude project folders of the old root are renamed (R17)" {
    _full_fixture
    _move --yes
    [ "$status" -eq 0 ]
    [ -d "$HOME/.claude/projects/$ENC_TO" ]
    [ -d "$HOME/.claude/projects/$ENC_TO-gitconfig" ]
    [ ! -e "$HOME/.claude/projects/$ENC_FROM" ]
    [ ! -e "$HOME/.claude/projects/$ENC_FROM-gitconfig" ]
    [ -d "$HOME/.claude/projects/${ENC_FROM}Old" ]
}

@test "a project folder whose new name is taken is left alone, reported, and fails the run (R17, R18)" {
    _make_clone
    enc_from="$(printf '%s' "$FROM" | sed 's/[^A-Za-z0-9]/-/g')"
    enc_to="$(printf '%s' "$TO" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$HOME/.claude/projects/$enc_from-dup" "$HOME/.claude/projects/$enc_to-dup"
    _move --yes
    [ "$status" -eq 1 ]
    [ -d "$HOME/.claude/projects/$enc_from-dup" ]
    grep -qF "already exists, merge them by hand" "$(_run_dir)/report.txt"
}

# ---------------------------------------------------------------------------
# Report, backups, untouchables (R18-R20)
# ---------------------------------------------------------------------------

@test "the report has sections (a)-(d); report-only items don't fail the run (R18)" {
    _full_fixture
    _move --yes
    [ "$status" -eq 0 ]
    report="$(_run_dir)/report.txt"
    [[ "$(basename "$(_run_dir)")" =~ ^\.scripts-move-[0-9]{8}-[0-9]{6}$ ]]
    grep -qxF "(a) Changes made:" "$report"
    grep -qxF "(b) Failures:" "$report"
    grep -qxF "(c) Remaining references to the old root (counted as failures):" "$report"
    grep -qxF "(d) Report only (not changed, not counted as failures):" "$report"
    grep -qxF "  Python venv to recreate: $TO/pyproj/.venv" "$report"
    grep -qxF "  App state that mentions the old root: $HOME/.claude.json" "$report"
    grep -qxF "  System scope: $SANDBOX/sysroot/etc/systemd/system/rooty.service" "$report"
    grep -qxF "Result: OK" "$report"
    [[ "$output" == *"(a) Changes made:"* ]]
}

@test "every rewritten file has a byte-identical backup; links and jobs are recorded (R19)" {
    _full_fixture
    _text_fixtures
    _move --yes
    [ "$status" -eq 0 ]
    backup="$(_run_dir)/backup"
    for f in $FIXTURES; do
        [ "$f" = .profile ] && continue   # not rewritten under Linux rules
        cmp "$backup/$f" "$SANDBOX/expected/$f.before"
    done
    [ -f "$backup/.config/systemd/user/mine-a.service" ]
    [ -f "$backup/Library/LaunchAgents/com.me.tool.plist" ]
    grep -qF "\"$FROM/tools/backup.sh\"" "$backup/crontab.txt"
    grep -qxF "link $HOME/.claude/skills was -> $FROM/agent-skills" "$backup/links-and-tasks.txt"
    grep -qF "cron line was: 0 * * * * \"$FROM/tools/backup.sh\"" "$backup/links-and-tasks.txt"
}

@test "files inside repos and app state are never edited (R20)" {
    _full_fixture
    mkdir -p "$FROM/other-repo" "$FROM/dotfiles"
    printf 'Lives in %s/other-repo\n' "$FROM" > "$FROM/other-repo/notes.txt"
    _git -C "$FROM/other-repo" init -q
    _git -C "$FROM/other-repo" add -A
    _git -C "$FROM/other-repo" commit -q -m notes
    notes="$(cksum < "$FROM/other-repo/notes.txt")"
    claude_json="$(cksum < "$HOME/.claude.json")"
    # A dotfile linked into a repo: the link is re-pointed, the file isn't edited.
    printf 'source %s/dotfiles/aliases\n' "$FROM" > "$FROM/dotfiles/zshrc"
    ln -s "$FROM/dotfiles/zshrc" "$HOME/.zshrc"
    _move --yes
    [ "$status" -eq 0 ]
    [ "$(cksum < "$TO/other-repo/notes.txt")" = "$notes" ]
    [ "$(cksum < "$HOME/.claude.json")" = "$claude_json" ]
    [ "$(cat "$TO/dotfiles/zshrc")" = "source $FROM/dotfiles/aliases" ]
    [ "$(readlink "$HOME/.zshrc")" = "$TO/dotfiles/zshrc" ]
    grep -qxF "  Link into a repo (not edited): $HOME/.zshrc" "$(_run_dir)/report.txt"
}
