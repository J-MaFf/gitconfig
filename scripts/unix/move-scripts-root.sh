#!/bin/bash

# Move the Scripts root out of ~/Documents - macOS and Linux (#304).
#
# Moves the folder that holds every clone (the Scripts root, by default the
# Scripts folder in ~/Documents) to ~/dev/repos with one same-filesystem rename
# (#311), creating the folders above it that don't exist yet, then re-points
# what depends on the old path: linked git worktrees, this repo's generated
# files (~/.gitconfig, the home links, the auto-sync job, the Ctrl-G rc
# block), symlinks in the home folder, paths in a fixed set of config files,
# the user crontab, systemd user units, launchd agents and Claude Code's
# per-project folders. No link is left at the old path: on a machine where a
# cloud client backs up Documents, one would bring the repos back into it.
# scripts/windows version/Move-ScriptsRoot.ps1 is the Windows twin; the
# runbook is docs/MOVE-SCRIPTS-ROOT.md.
#
# Runs under the stock macOS /bin/bash 3.2: no associative arrays, no ${var,,}.
# No set -e: every repair step runs even when an earlier one failed, and the
# failures are collected for the report.

FROM="$HOME/Documents/Scripts"
TO="$HOME/dev/repos"
DRY_RUN=false
YES=false
ALLOW_SYNCED=false

usage() {
    cat << 'HELP'
Move the Scripts root out of ~/Documents - macOS and Linux

USAGE: scripts/unix/move-scripts-root.sh [OPTIONS]

OPTIONS:
    --from PATH              The Scripts root to move (default: $HOME/Documents/Scripts)
    --to PATH                Where it goes (default: $HOME/dev/repos); missing
                             parent folders are created
    --dry-run                Print the plan and exit 0 without changing anything
    -y, --yes                Answer yes to every confirmation
    --allow-synced-target    Allow a --to inside a synced folder (Documents,
                             Desktop, Pictures, OneDrive, ~/Library/CloudStorage,
                             Google Drive, Dropbox); for a rollback
    -h, --help               Display this help message

DESCRIPTION:
    Renames FROM to TO (one rename on one filesystem, never a copy),
    creating TO's missing parent folders first (removed again if the rename
    fails; never in a dry run), then repairs what used the old path: linked
    git worktrees, ~/.gitconfig and the other files this repo generates,
    symlinks in the home folder, paths in shell rc files and Claude/VS Code
    config files, the user crontab, systemd user units, launchd agents and
    Claude Code project folders. No link is
    left at the old path. The plan is printed and confirmed first; files are
    backed up to ~/.scripts-move-<timestamp>/backup/ before they are changed,
    and the report is written to ~/.scripts-move-<timestamp>/report.txt.
    Run it again after a partial run: it skips the move and resumes the
    repairs. Runbook: docs/MOVE-SCRIPTS-ROOT.md.

EXIT STATUS:
    0  moved and repaired, or nothing to do
    1  a preflight check stopped the run (nothing was changed), or a repair
       failed or left a reference to the old root (see the report)
    2  a confirmation was declined or had no input (pass --yes when unattended)
HELP
}

while [ $# -gt 0 ]; do
    case $1 in
        --from)    [ $# -ge 2 ] || { echo "[ERROR] --from needs a path"; exit 1; }; FROM="$2"; shift 2 ;;
        --from=*)  FROM="${1#*=}"; shift ;;
        --to)      [ $# -ge 2 ] || { echo "[ERROR] --to needs a path"; exit 1; }; TO="$2"; shift 2 ;;
        --to=*)    TO="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -y|--yes)  YES=true; shift ;;
        --allow-synced-target) ALLOW_SYNCED=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/functions.sh
source "$REPO_ROOT/scripts/shared/functions.sh"
# shellcheck source=../shared/platform.sh
source "$REPO_ROOT/scripts/shared/platform.sh"

TARGET_OS="$(resolve_target_os script move-scripts-root.sh)" || exit 1
# Paths compare case-insensitively on macOS (its default filesystem is) and
# case-sensitively on Linux.
CI_PATHS=0
[ "$TARGET_OS" = macos ] && CI_PATHS=1

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# An absolute path with ., .. and repeated / resolved as text. Symlinks are
# not resolved: config files spell paths the way the user typed them (on
# macOS /var and /private/var are the same folder but not the same text).
# Usage: _norm_path PATH
_norm_path() {
    local p="$1" seg out
    local -a parts stack
    case "$p" in
        "~")  p="$HOME" ;;
        "~/"*) p="$HOME/${p#"~/"}" ;;
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    stack=()
    IFS=/ read -r -a parts <<< "$p"
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|.) ;;
            ..) [ "${#stack[@]}" -gt 0 ] && unset "stack[$((${#stack[@]} - 1))]" ;;
            *) stack+=("$seg") ;;
        esac
    done
    out=""
    for seg in "${stack[@]}"; do out="$out/$seg"; done
    printf '%s\n' "${out:-/}"
}

# Lower-case for comparison where paths are case-insensitive.
_fold() {
    if [ "$CI_PATHS" = 1 ]; then printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; else printf '%s' "$1"; fi
}

# Succeed if PATH is ROOT or inside it.
# Usage: _at_or_under PATH ROOT
_at_or_under() {
    local p="${1%/}" r="${2%/}"
    [ -n "$1" ] && [ -n "$2" ] || return 1
    if [ "$CI_PATHS" = 1 ]; then p="$(_fold "$p")"; r="$(_fold "$r")"; fi
    [ "$p" = "$r" ] && return 0
    case "$p" in "$r"/*) return 0 ;; esac
    return 1
}

# The old root as given, or its physical path (FROM_REAL, set when a symlink
# is on the way to it): git records worktree paths with symlinks resolved.
_under_old() { _at_or_under "$1" "$FROM" || { [ -n "$FROM_REAL" ] && _at_or_under "$1" "$FROM_REAL"; }; }

# PATH with the old root swapped for the new one; a path outside the old root
# is printed as it is.
# Usage: _to_new PATH
_to_new() {
    if _at_or_under "$1" "$FROM"; then printf '%s\n' "$TO${1:${#FROM}}"
    elif [ -n "$FROM_REAL" ] && _at_or_under "$1" "$FROM_REAL"; then printf '%s\n' "$TO${1:${#FROM_REAL}}"
    else printf '%s\n' "$1"; fi
}

# Relative path from the folder FROM_DIR to TO_PATH, as text.
# Usage: _relpath FROM_DIR TO_PATH
_relpath() {
    local -a a b
    local i=0 j out="" sep=""
    IFS=/ read -r -a a <<< "${1#/}"
    IFS=/ read -r -a b <<< "${2#/}"
    while [ "$i" -lt "${#a[@]}" ] && [ "$i" -lt "${#b[@]}" ] && [ "$(_fold "${a[$i]}")" = "$(_fold "${b[$i]}")" ]; do
        i=$((i + 1))
    done
    j=$i
    while [ "$j" -lt "${#a[@]}" ]; do out="$out$sep.."; sep=/; j=$((j + 1)); done
    j=$i
    while [ "$j" -lt "${#b[@]}" ]; do out="$out$sep${b[$j]}"; sep=/; j=$((j + 1)); done
    printf '%s\n' "${out:-.}"
}

# A symlink's target as an absolute path.
# Usage: _link_abs LINK
_link_abs() {
    local t
    t="$(readlink "$1")" || return 1
    case "$t" in
        /*) _norm_path "$t" ;;
        *)  _norm_path "$(dirname "$1")/$t" ;;
    esac
}

# Claude Code names a project's folder under ~/.claude/projects after its
# path, with every character that isn't a letter or digit replaced by "-".
_claude_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# Device id of the nearest existing folder at or above PATH (GNU stat first,
# as in file_owner_uid: BSD-style `stat -f` means something else on Linux).
_device_of() {
    local p="$1"
    while [ ! -e "$p" ] && [ "$p" != / ]; do p="$(dirname "$p")"; done
    stat -c %d "$p" 2>/dev/null || stat -f %d "$p" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Path forms (R14): how a text file can spell the old root, and the new
# spelling of each, in the arrays FORM_OLD / FORM_NEW.
# ---------------------------------------------------------------------------

# Usage: _build_forms [FILE_DIR]
# With FILE_DIR (a .code-workspace file's folder), relative spellings of the
# old root from that folder (../../<old root>/repo) are added, rewritten to the
# path from that folder to the new root.
_build_forms() {
    local file_dir="${1:-}" rel newrel prefix base b k dots i tail newrelpath
    FORM_OLD=("$FROM")
    FORM_NEW=("$TO")
    if [ -n "$FROM_REAL" ]; then FORM_OLD+=("$FROM_REAL"); FORM_NEW+=("$TO"); fi
    if _at_or_under "$FROM" "$HOME_N" && [ "${#FROM}" -gt "${#HOME_N}" ]; then
        rel="${FROM:$((${#HOME_N} + 1))}"
        newrel=""
        if _at_or_under "$TO" "$HOME_N" && [ "${#TO}" -gt "${#HOME_N}" ]; then newrel="${TO:$((${#HOME_N} + 1))}"; fi
        # shellcheck disable=SC2016  # literal spellings, not expansions
        for prefix in '~' '$HOME' '${HOME}'; do
            FORM_OLD+=("$prefix/$rel")
            if [ -n "$newrel" ]; then FORM_NEW+=("$prefix/$newrel"); else FORM_NEW+=("$TO"); fi
        done
    fi
    [ -n "$file_dir" ] || return 0
    newrelpath="$(_relpath "$file_dir" "$TO")"
    base="$file_dir"
    k=0
    while [ "$base" != / ]; do
        base="$(dirname "$base")"
        k=$((k + 1))
        b="${base%/}"
        if [ -z "$b" ]; then
            tail="${FROM#/}"
        elif _at_or_under "$FROM" "$b" && [ "${#FROM}" -gt "${#b}" ]; then
            tail="${FROM:$((${#b} + 1))}"
        else
            continue
        fi
        dots=""
        i=0
        while [ "$i" -lt "$k" ]; do dots="$dots../"; i=$((i + 1)); done
        FORM_OLD+=("$dots$tail")
        FORM_NEW+=("$newrelpath")
    done
}

# The rewrite engine, in awk so it runs on any macOS or Linux. Each old
# spelling counts only at a path boundary: not right after a path character
# (so a longer path that merely ends the same way isn't matched), and followed
# by "/", "\", a quote, whitespace or the end of the line (so .../ScriptsOld
# isn't). The longest spelling wins at a position. It works on bytes
# (LC_ALL=C) and keeps every other byte, CRs and a missing final newline
# included. Modes: count (print the number of matches), lines (print the
# lines with a match), rewrite (print the rewritten text).
_REWRITE_AWK='
function hit(i, start,    s, p, c1, c2) {
    while (1) {
        s = substr(low, start)
        p = index(s, key[i])
        if (p == 0) return 0
        p = start + p - 1
        c1 = (p > 1) ? substr(line, p - 1, 1) : ""
        c2 = substr(line, p + len[i], 1)
        if ((c1 == "" || index(BEFORE, c1) == 0) && (c2 == "" || index(AFTER, c2) > 0)) return p
        start = p + 1
    }
}
BEGIN {
    n = ENVIRON["MSR_N"] + 0
    for (i = 1; i <= n; i++) {
        old[i] = ENVIRON["MSR_O" i]
        rep[i] = ENVIRON["MSR_R" i]
        key[i] = ci ? tolower(old[i]) : old[i]
        len[i] = length(old[i])
    }
    BEFORE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-/\\"
    AFTER = "/\\\"\047 \t\r"
    total = 0
}
{
    line = $0
    low = ci ? tolower(line) : line
    out = ""
    pos = 1
    found = 0
    while (n > 0) {
        best = 0
        bestp = 0
        for (i = 1; i <= n; i++) {
            if (len[i] == 0) continue
            p = hit(i, pos)
            if (p > 0 && (bestp == 0 || p < bestp || (p == bestp && len[i] > len[best]))) { bestp = p; best = i }
        }
        if (best == 0) break
        out = out substr(line, pos, bestp - pos) rep[best]
        pos = bestp + len[best]
        found++
    }
    out = out substr(line, pos)
    total += found
    if (mode == "rewrite") { if (NR > 1) printf "\n"; printf "%s", out }
    else if (mode == "lines" && found) print line
}
END {
    if (mode == "count") print total
    else if (mode == "rewrite" && NR > 0 && !nonl) printf "\n"
}'

# Run the engine on FILE ("-" for stdin) with the current FORM_OLD/FORM_NEW.
# Usage: _rewrite MODE FILE
_rewrite() {
    local mode="$1" file="$2" nonl=0 i
    local -a envargs
    envargs=("MSR_N=${#FORM_OLD[@]}")
    for i in "${!FORM_OLD[@]}"; do
        envargs+=("MSR_O$((i + 1))=${FORM_OLD[$i]}" "MSR_R$((i + 1))=${FORM_NEW[$i]}")
    done
    if [ "$file" != - ] && [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then nonl=1; fi
    # BINMODE=3: a gawk built for Windows (Git Bash) would otherwise drop the
    # CRs; other awks ignore it.
    env "${envargs[@]}" LC_ALL=C awk -v BINMODE=3 -v mode="$mode" -v ci="$CI_PATHS" -v nonl="$nonl" "$_REWRITE_AWK" "$file"
}

# Old-root matches in FILE (forms chosen for the file).
_count_file() {
    case "$1" in *.code-workspace) _build_forms "$(dirname "$1")" ;; *) _build_forms ;; esac
    _rewrite count "$1" 2>/dev/null || echo 0
}

# Rewrite FILE in place (through a symlink, like the rc edits elsewhere here),
# keeping its permissions. Prints the number of matches rewritten.
_rewrite_file() {
    local f="$1" tmp n
    case "$f" in *.code-workspace) _build_forms "$(dirname "$f")" ;; *) _build_forms ;; esac
    n="$(_rewrite count "$f")" || return 1
    tmp="$(mktemp "${TMPDIR:-/tmp}/scripts-move.XXXXXX")" || return 1
    if _rewrite rewrite "$f" > "$tmp" && cat "$tmp" > "$f"; then
        rm -f "$tmp"
        printf '%s\n' "$n"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ---------------------------------------------------------------------------
# Scans. Each one works before the move (on FROM) and after it (on TO), so the
# same code builds the plan and rescans for leftovers.
# ---------------------------------------------------------------------------

# Folders up to 3 levels below ROOT (ROOT included) holding a .git folder or
# file, skipping node_modules and .venv; find never follows a link.
_repo_dirs() {
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 3 \( -name node_modules -o -name .venv -o -name .git \) -prune -o -type d -print 2>/dev/null |
        while IFS= read -r d; do
            if [ -e "$d/.git" ]; then printf '%s\n' "$d"; fi
        done
}

# The path in a "gitdir: <path>" file, or in a plain path file.
_read_gitpath() {
    [ -f "$1" ] || return 1
    sed -n '1{s/^gitdir: *//;p;}' "$1" | tr -d '\r'
}

# Linked worktrees still pointing at the old root, as "<main repo>\t<worktree>"
# lines, both as paths after the move: the worktrees of each main repo under
# ROOT whose records name the old root, plus worktrees under ROOT whose main
# repo is under TO (found from the worktree's own .git file).
_worktree_pairs() {
    local root="$1" d admin recorded wt wt_new wtfile gitdir admin_new admin_now common main
    _repo_dirs "$root" | while IFS= read -r d; do
        if [ -d "$d/.git" ]; then
            for admin in "$d/.git/worktrees"/*/; do
                [ -f "$admin/gitdir" ] || continue
                recorded="$(_read_gitpath "$admin/gitdir")"
                [ -n "$recorded" ] || continue
                wt="$(dirname "$recorded")"
                wt_new="$(_to_new "$wt")"
                wtfile="$(_read_gitpath "$wt_new/.git" 2>/dev/null || _read_gitpath "$wt/.git" 2>/dev/null)"
                if _under_old "$recorded" || _under_old "$wtfile"; then
                    printf '%s\t%s\n' "$(_to_new "$d")" "$wt_new"
                fi
            done
        else
            gitdir="$(_read_gitpath "$d/.git")"
            _under_old "$gitdir" || continue
            admin_new="$(_to_new "$gitdir")"
            if [ -d "$gitdir" ]; then admin_now="$gitdir"; else admin_now="$admin_new"; fi
            common="$(_read_gitpath "$admin_now/commondir" 2>/dev/null)"
            [ -n "$common" ] || common=../..
            case "$common" in /*) ;; *) common="$(_norm_path "$admin_new/$common")" ;; esac
            common="$(_to_new "$common")"
            if [ "$(basename "$common")" = .git ]; then main="$(dirname "$common")"; else main="$common"; fi
            if _at_or_under "$main" "$TO"; then printf '%s\t%s\n' "$main" "$(_to_new "$d")"; fi
        fi
    done | LC_ALL=C sort -u
}

# Folders (up to 5 levels below ROOT) holding a pyvenv.cfg: venvs embed their
# absolute path and must be recreated. Reported, never changed.
_venvs() {
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 5 \( -name node_modules -o -name .git \) -prune -o -name pyvenv.cfg -type f -print 2>/dev/null |
        while IFS= read -r f; do _to_new "$(dirname "$f")"; done | LC_ALL=C sort -u
}

# The links the tool repairs (R13): $HOME and ~/.claude (depth 1), ~/.config
# (depth 2), ~/.local/bin and ~/bin (depth 1). A scan folder that is itself a
# link is not looked into (its contents belong to whatever it points at).
_home_links() {
    local set dir depth
    for set in "$HOME_N:1" "$HOME_N/.claude:1" "$HOME_N/.config:2" "$HOME_N/.local/bin:1" "$HOME_N/bin:1"; do
        dir="${set%:*}"
        depth="${set##*:}"
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        find "$dir" -mindepth 1 -maxdepth "$depth" -type l 2>/dev/null
    done | LC_ALL=C sort -u
}

# The exact set of text files R14 rewrites (those that exist).
_text_file_set() {
    local docs edition name rel f
    for docs in "$HOME_N/Documents"; do
        for edition in PowerShell WindowsPowerShell; do
            for name in profile.ps1 Microsoft.PowerShell_profile.ps1 Microsoft.VSCode_profile.ps1; do
                printf '%s\n' "$docs/$edition/$name"
            done
        done
    done
    for rel in .gitconfig.local .config/gitconfig/safe-directories .bashrc .bash_profile .profile .zshrc \
        .zprofile .config/fish/config.fish .claude/settings.json; do
        printf '%s\n' "$HOME_N/$rel"
    done
    for f in "$HOME_N"/.claude/scheduled-tasks/*/SKILL.md "$HOME_N"/.vscode/workspaces/*.code-workspace; do
        printf '%s\n' "$f"
    done
    if [ -d "$HOME_N/.vscode/agent-plugins" ]; then
        find "$HOME_N/.vscode/agent-plugins" -name .mcp.json \( -type f -o -type l \) 2>/dev/null
    fi
}

_unit_name() {
    case "$(basename "$(dirname "$1")")" in
        *.d) basename "$(dirname "$1")" .d ;;
        *)   basename "$1" ;;
    esac
}

# The label of a launchd plist (PlistBuddy on macOS, else its file name).
_plist_label() {
    local label=""
    if [ -x /usr/libexec/PlistBuddy ]; then
        label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null)"
    fi
    [ -n "$label" ] || label="$(basename "$1" .plist)"
    printf '%s\n' "$label"
}

# Print the files among PATH... (searched recursively with -r) that mention
# the old root, by fixed string.
# Usage: _grep_old [-r] PATH...
_grep_old() {
    local flags=-lF
    [ "$CI_PATHS" = 1 ] && flags=-liF
    if [ "$1" = -r ]; then flags="${flags}r"; shift; fi
    grep -s "$flags" -- "$FROM" "$@" 2>/dev/null
}

# Fill the PLAN_* variables for the folder SCAN_ROOT (FROM before the move,
# TO after it).
build_plan() {
    local scan_root="$1" f n t abs new link unit name label enc_old enc_new dest target sysroot
    PLAN_WT="$(_worktree_pairs "$scan_root")"
    PLAN_VENVS="$(_venvs "$scan_root")"

    PLAN_LINKS=()
    PLAN_LINK_OLD=()
    PLAN_LINK_NEW=()
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        abs="$(_link_abs "$link")" || continue
        _under_old "$abs" || continue
        t="$(readlink "$link")"
        new="$(_to_new "$abs")"
        # A relative link stays relative.
        case "$t" in /*) ;; *) new="$(_relpath "$(dirname "$link")" "$new")" ;; esac
        PLAN_LINKS+=("$link")
        PLAN_LINK_OLD+=("$t")
        PLAN_LINK_NEW+=("$new")
    done < <(_home_links)

    PLAN_TEXT=()
    PLAN_TEXT_N=()
    PLAN_INREPO=()
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if [ -L "$f" ]; then
            abs="$(_link_abs "$f")"
            if _under_old "$abs" || _at_or_under "$abs" "$TO"; then PLAN_INREPO+=("$f"); continue; fi
        fi
        n="$(_count_file "$f")"
        if [ "${n:-0}" -gt 0 ]; then PLAN_TEXT+=("$f"); PLAN_TEXT_N+=("$n"); fi
    done < <(_text_file_set | awk '!seen[$0]++')

    PLAN_GEN=()
    PLAN_GEN_TEXT=()
    if [ "$CLONE_UNDER_TO" = true ]; then
        if [ -f "$HOME_N/.gitconfig" ] && [ "$(_count_file "$HOME_N/.gitconfig")" -gt 0 ]; then
            PLAN_GEN+=(gitconfig); PLAN_GEN_TEXT+=("generate_gitconfig (regenerates $HOME_N/.gitconfig)")
        fi
        for name in .gitignore_global gitconfig_helper.py; do
            if [ -L "$HOME_N/$name" ] && _under_old "$(_link_abs "$HOME_N/$name")"; then
                PLAN_GEN+=(links); PLAN_GEN_TEXT+=("create_symlink for ~/.gitignore_global and ~/gitconfig_helper.py")
                break
            fi
        done
        if { command -v crontab >/dev/null 2>&1 && [ -n "$CLONE_OLD" ] && _cron_has_entry "$CLONE_OLD"; } ||
           { [ -f "$(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.service" ] && [ "$(_count_file "$(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.service")" -gt 0 ]; } ||
           { [ -f "$(_launchd_plist_path)" ] && [ "$(_count_file "$(_launchd_plist_path)")" -gt 0 ]; }; then
            PLAN_GEN+=(scheduler); PLAN_GEN_TEXT+=("scheduler_install (the $(scheduler_name "$TARGET_OS") for $CLONE_NEW)")
        fi
        for f in "$HOME_N/.bashrc" "$HOME_N/.zshrc"; do
            # A linked rc file belongs to the repo it points at (never edited).
            if [ -f "$f" ] && [ ! -L "$f" ] && grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$f" 2>/dev/null && [ "$(_count_file "$f")" -gt 0 ]; then
                PLAN_GEN+=(widget); PLAN_GEN_TEXT+=("enable_git_alias_widget (the Ctrl-G block; its path is rewritten with the rc file)")
                break
            fi
        done
    fi
    _plan_has_gen scheduler && GEN_SCHEDULER=true || GEN_SCHEDULER=false

    PLAN_CRON=""
    if command -v crontab >/dev/null 2>&1; then
        _build_forms
        PLAN_CRON="$(crontab -l 2>/dev/null | _rewrite lines -)"
    fi

    PLAN_UNITS=()
    if [ -d "$(_systemd_unit_dir)" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            unit="$(_unit_name "$f")"
            # The auto-sync units are rewritten by scheduler_install.
            if [ "$GEN_SCHEDULER" = true ] && [ "${unit%.*}" = "$GITCONFIG_SYSTEMD_UNIT" ]; then continue; fi
            [ "$(_count_file "$f")" -gt 0 ] && PLAN_UNITS+=("$f")
        done < <(find "$(_systemd_unit_dir)" -type f 2>/dev/null | LC_ALL=C sort)
    fi

    PLAN_PLISTS=()
    for f in "$HOME_N"/Library/LaunchAgents/*.plist; do
        [ -f "$f" ] || continue
        if [ "$GEN_SCHEDULER" = true ] && [ "$f" = "$(_launchd_plist_path)" ]; then continue; fi
        if [ "$(head -c 6 "$f" 2>/dev/null)" = bplist ]; then
            # A binary plist can't be searched as text; plutil turns it into XML.
            grep -qF -- "$FROM" "$f" 2>/dev/null && PLAN_PLISTS+=("$f")
        elif [ "$(_count_file "$f")" -gt 0 ]; then
            PLAN_PLISTS+=("$f")
        fi
    done

    PLAN_PROJ=()
    PLAN_PROJ_NEW=()
    PLAN_PROJ_BLOCKED=()
    enc_new="$(_claude_name "$TO")"
    for f in "$HOME_N"/.claude/projects/*/; do
        [ -d "$f" ] || continue
        name="$(basename "$f")"
        # Claude Code may have named it after the physical path.
        target=""
        for enc_old in "$(_claude_name "$FROM")" ${FROM_REAL:+"$(_claude_name "$FROM_REAL")"}; do
            case "$(_fold "$name")" in
                "$(_fold "$enc_old")"|"$(_fold "$enc_old")"-*) target="$enc_new${name:${#enc_old}}"; break ;;
            esac
        done
        [ -n "$target" ] || continue
        dest="$HOME_N/.claude/projects/$target"
        PLAN_PROJ+=("$HOME_N/.claude/projects/$name")
        PLAN_PROJ_NEW+=("$dest")
        if [ -e "$dest" ]; then PLAN_PROJ_BLOCKED+=(true); else PLAN_PROJ_BLOCKED+=(false); fi
    done

    # Report only: system-scope jobs and app state. GITCONFIG_MOVE_SYSROOT is
    # a test seam: a folder that stands in for / so the tests never read the
    # real /etc or /Library.
    PLAN_SYSTEM=()
    sysroot="${GITCONFIG_MOVE_SYSROOT:-}"
    while IFS= read -r f; do
        [ -n "$f" ] && PLAN_SYSTEM+=("$f")
    done < <(
        [ -d "$sysroot/etc/systemd/system" ] && _grep_old -r "$sysroot/etc/systemd/system"
        for f in "$sysroot"/Library/LaunchDaemons/*.plist "$sysroot/etc/crontab" "$sysroot"/etc/cron.d/* \
            "$sysroot/var/spool/cron/crontabs/root" "$sysroot/var/spool/cron/root" "$sysroot/usr/lib/cron/tabs/root"; do
            [ -f "$f" ] && [ -r "$f" ] && _grep_old "$f"
        done
    )
    PLAN_APPSTATE=()
    while IFS= read -r f; do
        [ -n "$f" ] && PLAN_APPSTATE+=("$f")
    done < <(
        for f in "$HOME_N/.claude.json" "$HOME_N/Library/Application Support/Claude"/*.json "$HOME_N/.config/Claude"/*.json \
            "$HOME_N/Library/Application Support/Code/User/globalStorage"/* "$HOME_N/.config/Code/User/globalStorage"/*; do
            [ -f "$f" ] && _grep_old "$f"
        done
    )
}

_plan_has_gen() {
    local g
    for g in "${PLAN_GEN[@]}"; do [ "$g" = "$1" ] && return 0; done
    return 1
}

plan_has_work() {
    [ -n "$PLAN_WT" ] || [ "${#PLAN_GEN[@]}" -gt 0 ] || [ "${#PLAN_LINKS[@]}" -gt 0 ] ||
        [ "${#PLAN_TEXT[@]}" -gt 0 ] || [ -n "$PLAN_CRON" ] || [ "${#PLAN_UNITS[@]}" -gt 0 ] ||
        [ "${#PLAN_PLISTS[@]}" -gt 0 ] || [ "${#PLAN_PROJ[@]}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Plan output (R6)
# ---------------------------------------------------------------------------

# Print TITLE, then each remaining argument indented, or "(none)".
_section() {
    local title="$1" line any=false
    shift
    echo "$title"
    for line in "$@"; do
        [ -n "$line" ] || continue
        echo "  $line"
        any=true
    done
    [ "$any" = true ] || echo "  (none)"
}

print_plan() {
    local i repo wt last="" m
    local -a lines
    lines=()
    echo ""
    echo "Plan"
    echo "===="
    if [ "$MOVE_NEEDED" = true ]; then
        lines=()
        for i in "${!TO_MISSING[@]}"; do lines+=("create ${TO_MISSING[$i]}"); done
        _section "Move:" "${lines[@]}" "$FROM -> $TO (one rename)"
        lines=()
    else _section "Move:" "already moved to $TO; resuming repairs"; fi

    if [ -n "$PLAN_WT" ]; then
        while IFS="$(printf '\t')" read -r repo wt; do
            if [ "$repo" != "$last" ]; then lines+=("$repo: git worktree repair"); last="$repo"; fi
            lines+=("    worktree $wt")
        done <<< "$PLAN_WT"
    fi
    _section "Repos and worktrees to repair:" "${lines[@]}"

    if [ "$CLONE_UNDER_TO" = true ]; then
        _section "This repo's generators to re-run (from $CLONE_NEW):" "${PLAN_GEN_TEXT[@]}"
    else
        _section "This repo's generators to re-run:" "skipped: this gitconfig clone ($REPO_ROOT) is not under $TO"
    fi

    lines=()
    for i in "${!PLAN_TEXT[@]}"; do
        m=matches; [ "${PLAN_TEXT_N[$i]}" = 1 ] && m=match
        lines+=("${PLAN_TEXT[$i]} (${PLAN_TEXT_N[$i]} $m)")
    done
    _section "Files to rewrite:" "${lines[@]}"

    lines=()
    for i in "${!PLAN_LINKS[@]}"; do lines+=("${PLAN_LINKS[$i]} -> ${PLAN_LINK_NEW[$i]}"); done
    _section "Links to re-point:" "${lines[@]}"

    lines=()
    if [ -n "$PLAN_CRON" ]; then
        while IFS= read -r m; do lines+=("crontab: $m"); done <<< "$PLAN_CRON"
    fi
    for i in "${PLAN_UNITS[@]}"; do
        if _unit_was_active "$(_unit_name "$i")"; then lines+=("systemd user unit $i (active: restarted)")
        else lines+=("systemd user unit $i"); fi
    done
    for i in "${PLAN_PLISTS[@]}"; do lines+=("launchd agent $i (reloaded)"); done
    _plan_has_gen scheduler && lines+=("the auto-sync job (re-registered by scheduler_install)")
    _section "Scheduled tasks and jobs to update:" "${lines[@]}"

    lines=()
    for i in "${!PLAN_PROJ[@]}"; do
        if [ "${PLAN_PROJ_BLOCKED[$i]}" = true ]; then
            lines+=("${PLAN_PROJ[$i]} -> ${PLAN_PROJ_NEW[$i]} (left alone: the destination already exists)")
        else
            lines+=("${PLAN_PROJ[$i]} -> ${PLAN_PROJ_NEW[$i]}")
        fi
    done
    _section "Claude project folders to rename:" "${lines[@]}"

    lines=()
    if [ -n "$PLAN_VENVS" ]; then
        while IFS= read -r m; do lines+=("Python venv to recreate: $m"); done <<< "$PLAN_VENVS"
    fi
    for i in "${PLAN_SYSTEM[@]}"; do lines+=("System scope: $i"); done
    for i in "${PLAN_APPSTATE[@]}"; do lines+=("App state that mentions the old root: $i"); done
    for i in "${PLAN_INREPO[@]}"; do lines+=("Link into a repo (not edited): $i"); done
    _section "Report only (not changed):" "${lines[@]}"
    echo ""
}

# ---------------------------------------------------------------------------
# Backups (R19)
# ---------------------------------------------------------------------------

# Copy FILE into backup/, under its path relative to $HOME (the first original
# wins when a file is changed twice in one run).
_save_backup() {
    local f="$1" rel dest
    case "$f" in
        "$HOME_N"/*) rel="${f#"$HOME_N"/}" ;;
        *) rel="_outside-home$f" ;;
    esac
    dest="$BACKUP_DIR/$rel"
    [ -e "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")" && cp -p "$f" "$dest"
}

_record() { printf '%s\n' "$1" >> "$BACKUP_DIR/links-and-tasks.txt"; }

# Files this repo's installers manage (dotfiles directly in $HOME, the
# safe-directories list) also get the usual timestamped copy next to them.
_installer_managed() {
    [ "$(dirname "$1")" = "$HOME_N" ] && return 0
    [ "$1" = "$HOME_N/.config/gitconfig/safe-directories" ]
}

# ---------------------------------------------------------------------------
# Repairs. Each step runs even if an earlier one failed; problems go to
# FAILURES and the step carries on with its next item.
# ---------------------------------------------------------------------------

CHANGES=()
FAILURES=()

_unit_was_active() {
    case "$MOVE_ACTIVE_UNITS" in *"|$1|"*) return 0 ;; esac
    return 1
}

repair_worktrees() {
    local repo wt last=""
    local -a wts
    wts=()
    [ -n "$PLAN_WT" ] || return 0
    # One `git worktree repair` per main repo, with all its worktrees.
    while IFS="$(printf '\t')" read -r repo wt; do
        if [ "$repo" != "$last" ] && [ -n "$last" ]; then _repair_repo "$last" "${wts[@]}"; wts=(); fi
        last="$repo"
        if [ -d "$wt" ]; then wts+=("$wt")
        else FAILURES+=("worktree $wt of $repo is missing; run: git -C \"$repo\" worktree prune"); fi
    done <<< "$PLAN_WT"
    [ -n "$last" ] && _repair_repo "$last" "${wts[@]}"
    return 0
}

_repair_repo() {
    local repo="$1" out
    shift
    [ $# -gt 0 ] || return 0
    if out="$(git -C "$repo" worktree repair "$@" 2>&1)"; then
        CHANGES+=("repaired worktrees of $repo: $*")
    else
        FAILURES+=("git worktree repair in $repo failed: $out")
    fi
}

repair_links() {
    local i link
    for i in "${!PLAN_LINKS[@]}"; do
        link="${PLAN_LINKS[$i]}"
        _record "link $link was -> ${PLAN_LINK_OLD[$i]}"
        # -n: replace the link itself, even when the old one names a folder.
        if ln -sfn "${PLAN_LINK_NEW[$i]}" "$link" 2>/dev/null; then
            CHANGES+=("re-pointed $link -> ${PLAN_LINK_NEW[$i]}")
        else
            FAILURES+=("could not re-point $link -> ${PLAN_LINK_NEW[$i]}")
        fi
    done
}

run_generators() {
    local g f rc widget_ok
    for g in "${PLAN_GEN[@]}"; do
        case "$g" in
            gitconfig)
                for f in "$HOME_N/.gitconfig" "$HOME_N/.gitconfig.local"; do [ -f "$f" ] && _save_backup "$f"; done
                rc=0
                generate_gitconfig "$CLONE_NEW" "$HOME_N" true || rc=$?
                if [ "$rc" -eq 0 ]; then CHANGES+=("regenerated $HOME_N/.gitconfig (generate_gitconfig)")
                else FAILURES+=("generate_gitconfig failed (exit $rc)"); fi
                ;;
            links)
                for f in .gitignore_global gitconfig_helper.py; do
                    if create_symlink "$CLONE_NEW/$f" "$HOME_N/$f" true "$CLONE_NEW"; then
                        CHANGES+=("checked ~/$f (create_symlink)")
                    else
                        FAILURES+=("create_symlink for ~/$f failed")
                    fi
                done
                ;;
            scheduler)
                # The old clone's cron line is matched by its old path, so
                # scheduler_install would leave it behind: remove it first.
                if command -v crontab >/dev/null 2>&1 && _cron_has_entry "$CLONE_OLD"; then
                    crontab -l 2>/dev/null > "$BACKUP_DIR/crontab.txt"
                    _record "crontab (before) saved as backup/crontab.txt"
                    _cron_remove_entries "$CLONE_OLD" || FAILURES+=("could not remove the old cron line for $CLONE_OLD")
                fi
                for f in "$(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.service" "$(_systemd_unit_dir)/$GITCONFIG_SYSTEMD_UNIT.timer" "$(_launchd_plist_path)"; do
                    [ -f "$f" ] && _save_backup "$f"
                done
                if scheduler_install "$TARGET_OS" "$CLONE_NEW" true; then
                    CHANGES+=("re-registered the auto-sync job for $CLONE_NEW (scheduler_install)")
                else
                    FAILURES+=("scheduler_install could not register the auto-sync job for $CLONE_NEW")
                fi
                ;;
            widget)
                # enable_git_alias_widget keeps an existing block as it is (its
                # path is rewritten with the rc file, below) and appends one to
                # an rc file that lacks it, writing through a symlinked rc into
                # whatever repo it points at. So it runs only when every rc
                # file it would visit already has the block, and then just
                # confirms them. SHELL unset: no rc file is created.
                widget_ok=true
                for f in "$HOME_N/.zshrc" "$HOME_N/.bashrc"; do
                    [ -e "$f" ] || [ -L "$f" ] || continue
                    if [ -L "$f" ] || ! grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$f" 2>/dev/null; then widget_ok=false; fi
                done
                if [ "$widget_ok" = true ]; then
                    SHELL='' enable_git_alias_widget "$CLONE_NEW" "$HOME_N"
                else
                    echo "[INFO] Not running enable_git_alias_widget: an rc file without the Ctrl-G block (or a linked one) would be changed; the existing block's path is rewritten with its rc file"
                fi
                ;;
        esac
    done
}

repair_text_files() {
    local f n
    for f in "${PLAN_TEXT[@]}"; do
        # Counted again: a generator may already have rewritten some lines.
        [ "$(_count_file "$f")" -gt 0 ] || continue
        if ! _save_backup "$f"; then FAILURES+=("could not back up $f; left unchanged"); continue; fi
        if _installer_managed "$f"; then backup_copy "$f" >/dev/null; fi
        if n="$(_rewrite_file "$f")"; then CHANGES+=("rewrote $f ($n)")
        else FAILURES+=("could not rewrite $f"); fi
    done
}

repair_crontab() {
    local before
    command -v crontab >/dev/null 2>&1 || return 0
    _build_forms
    before="$(crontab -l 2>/dev/null)" || return 0
    [ -n "$(printf '%s\n' "$before" | _rewrite lines -)" ] || return 0
    [ -f "$BACKUP_DIR/crontab.txt" ] || printf '%s\n' "$before" > "$BACKUP_DIR/crontab.txt"
    printf '%s\n' "$before" | _rewrite lines - | while IFS= read -r line; do _record "cron line was: $line"; done
    # One crontab install.
    if printf '%s\n' "$before" | _rewrite rewrite - | crontab - 2>/dev/null; then
        CHANGES+=("rewrote the user crontab")
    else
        FAILURES+=("could not install the rewritten crontab")
    fi
}

repair_systemd() {
    local f unit changed=false
    for f in "${PLAN_UNITS[@]}"; do
        [ "$(_count_file "$f")" -gt 0 ] || continue
        _save_backup "$f" || { FAILURES+=("could not back up $f; left unchanged"); continue; }
        if _rewrite_file "$f" >/dev/null; then CHANGES+=("rewrote systemd user unit $f"); changed=true
        else FAILURES+=("could not rewrite $f"); fi
    done
    [ "$changed" = true ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user daemon-reload >/dev/null 2>&1 || FAILURES+=("systemctl --user daemon-reload failed")
    for f in "${PLAN_UNITS[@]}"; do
        unit="$(_unit_name "$f")"
        _unit_was_active "$unit" || continue
        if systemctl --user restart "$unit" >/dev/null 2>&1; then CHANGES+=("restarted $unit")
        else FAILURES+=("could not restart $unit"); fi
    done
}

repair_launchd() {
    local f label
    for f in "${PLAN_PLISTS[@]}"; do
        _save_backup "$f" || { FAILURES+=("could not back up $f; left unchanged"); continue; }
        if [ "$(head -c 6 "$f" 2>/dev/null)" = bplist ]; then
            if ! command -v plutil >/dev/null 2>&1 || ! plutil -convert xml1 "$f" 2>/dev/null; then
                FAILURES+=("$f is a binary plist that plutil could not convert; edit it by hand")
                continue
            fi
        fi
        if ! _rewrite_file "$f" >/dev/null; then FAILURES+=("could not rewrite $f"); continue; fi
        CHANGES+=("rewrote launchd agent $f")
        command -v launchctl >/dev/null 2>&1 || continue
        label="$(_plist_label "$f")"
        launchctl bootout "$(_launchd_domain)/$label" >/dev/null 2>&1 || true
        if launchctl bootstrap "$(_launchd_domain)" "$f" 2>/dev/null; then CHANGES+=("reloaded $label")
        else FAILURES+=("could not reload $label (launchctl bootstrap $(_launchd_domain) \"$f\")"); fi
    done
}

rename_projects() {
    local i
    for i in "${!PLAN_PROJ[@]}"; do
        [ "${PLAN_PROJ_BLOCKED[$i]}" = true ] && continue   # reported by the rescan
        if mv "${PLAN_PROJ[$i]}" "${PLAN_PROJ_NEW[$i]}" 2>/dev/null; then
            _record "claude project ${PLAN_PROJ_NEW[$i]} was ${PLAN_PROJ[$i]}"
            CHANGES+=("renamed Claude project folder $(basename "${PLAN_PROJ[$i]}") -> $(basename "${PLAN_PROJ_NEW[$i]}")")
        else
            FAILURES+=("could not rename ${PLAN_PROJ[$i]}")
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

stop_preflight() {
    echo "[ERROR] $1"
    echo "Nothing was changed."
    exit 1
}

HOME_N="$(_norm_path "$HOME")"
FROM="$(_norm_path "$FROM")"
TO="$(_norm_path "$TO")"
# From's parent outlives the move, so its physical path is known on a resume too.
FROM_REAL=""
if from_parent="$(cd -P "$(dirname "$FROM")" 2>/dev/null && pwd)"; then
    FROM_REAL="${from_parent%/}/$(basename "$FROM")"
    [ "$FROM_REAL" = "$FROM" ] && FROM_REAL=""
fi

echo "Move the Scripts root ($(os_display_name "$TARGET_OS"))"
echo "====================================="
echo "From: $FROM"
echo "To:   $TO"
[ "$DRY_RUN" = true ] && echo "Dry run: nothing will be changed."
echo ""

# --- Preflight (R3, R4): any abort leaves the machine untouched ------------
if _at_or_under "$TO" "$FROM" || _at_or_under "$FROM" "$TO"; then
    stop_preflight "From and To are the same folder, or one is inside the other ($FROM, $TO)."
fi
if [ -e "$FROM" ] && [ ! -d "$FROM" ]; then stop_preflight "From ($FROM) is a file, not a folder."; fi
if [ ! -e "$FROM" ] && [ ! -e "$TO" ] && [ ! -L "$TO" ]; then stop_preflight "Neither From ($FROM) nor To ($TO) exists."; fi
TO_EMPTY=false
if [ -d "$FROM" ] && { [ -e "$TO" ] || [ -L "$TO" ]; }; then
    if [ -d "$TO" ] && [ ! -L "$TO" ] && [ -z "$(ls -A "$TO" 2>/dev/null)" ]; then TO_EMPTY=true
    else stop_preflight "Both From and To exist, and To ($TO) is not an empty folder. Move its contents away or pick another --to."; fi
fi
# The folders above To that don't exist yet (outermost first; created just
# before the rename), and the nearest one that does, which the checks inspect.
TO_MISSING=()
TO_ANCHOR=""
if [ -d "$FROM" ]; then
    TO_ANCHOR="$(dirname "$TO")"
    while [ ! -e "$TO_ANCHOR" ] && [ ! -L "$TO_ANCHOR" ]; do
        TO_MISSING=("$TO_ANCHOR" "${TO_MISSING[@]}")
        TO_ANCHOR="$(dirname "$TO_ANCHOR")"
    done
    if [ "$(_device_of "$FROM")" != "$(_device_of "$TO_ANCHOR")" ]; then
        stop_preflight "From ($FROM) and the nearest existing folder above To ($TO_ANCHOR) are on different filesystems. The move is one rename; it never copies across filesystems."
    fi
fi
if [ "$ALLOW_SYNCED" = false ]; then
    for synced in "$HOME_N/Documents" "$HOME_N/Desktop" "$HOME_N/Pictures" "${OneDrive:-}" "${OneDriveCommercial:-}" \
        "$HOME_N/Library/CloudStorage" "$HOME_N/Google Drive" "$HOME_N/Dropbox"; do
        [ -n "$synced" ] || continue
        if _at_or_under "$TO" "$(_norm_path "$synced")"; then
            stop_preflight "To ($TO) is inside $synced, a folder that cloud sync backs up. Pick a folder outside it, or pass --allow-synced-target (for a rollback)."
        fi
    done
fi
if [ -d "$FROM" ] && [ ! -d "$TO_ANCHOR" ]; then stop_preflight "$TO_ANCHOR, above To, is not a folder."; fi

MOVE_NEEDED=false
[ -d "$FROM" ] && MOVE_NEEDED=true
if [ "$MOVE_NEEDED" = false ]; then echo "already moved; resuming repairs"; echo ""; fi

# This repo's clone after the move (the generators run from there) and its
# path before it (the old cron line names it).
CLONE_NEW="$(_to_new "$REPO_ROOT")"
CLONE_UNDER_TO=false
_at_or_under "$CLONE_NEW" "$TO" && CLONE_UNDER_TO=true
CLONE_OLD=""
if _under_old "$REPO_ROOT"; then CLONE_OLD="$REPO_ROOT"
elif _at_or_under "$REPO_ROOT" "$TO"; then CLONE_OLD="$FROM${REPO_ROOT:${#TO}}"; fi

# --- Google Drive (R5) -----------------------------------------------------
if [ "$MOVE_NEEDED" = true ] && [ "$TARGET_OS" = macos ] && command -v pgrep >/dev/null 2>&1 && pgrep -x "Google Drive" >/dev/null 2>&1; then
    echo "[WARN] Google Drive for desktop is running. Pause syncing before the move"
    echo "       (Drive icon in the menu bar > Settings > Pause syncing), so it does"
    echo "       not sync the folder while it moves."
    if [ "$DRY_RUN" = false ] && [ "$YES" = false ]; then
        if ! ask_yes_no "Is Drive syncing paused?" --yes; then
            echo "Cancelled. Nothing was changed."
            exit 2
        fi
    fi
    echo ""
fi

# --- Plan (R6) ---------------------------------------------------------------
if [ "$MOVE_NEEDED" = true ]; then SCAN_ROOT="$FROM"; else SCAN_ROOT="$TO"; fi
# Units running now are restarted after their files are rewritten; the others
# are only reloaded.
MOVE_ACTIVE_UNITS="|"
if [ -d "$(_systemd_unit_dir)" ] && command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        unit="$(_unit_name "$f")"
        if systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then MOVE_ACTIVE_UNITS="$MOVE_ACTIVE_UNITS$unit|"; fi
    done < <(find "$(_systemd_unit_dir)" -type f 2>/dev/null)
fi
build_plan "$SCAN_ROOT"
print_plan

if [ "$MOVE_NEEDED" = false ] && ! plan_has_work; then
    echo "Nothing to do: nothing on this machine still points at $FROM."
    exit 0
fi
if [ "$DRY_RUN" = true ]; then
    echo "Dry run: nothing was changed."
    exit 0
fi
if [ "$YES" = false ]; then
    if [ "$MOVE_NEEDED" = true ]; then question="Move the Scripts root and make these changes?"; else question="Make these changes?"; fi
    if ! ask_yes_no "$question" --yes; then
        echo "Cancelled. Nothing was changed."
        exit 2
    fi
fi

# --- Move (R8, R9) -------------------------------------------------------------
# Leave the old root first, so nothing here runs from inside it.
cd "$HOME_N" || stop_preflight "Could not change to $HOME_N."
# Remove the folders above To that this run created (deepest first; rmdir
# only removes a folder that is still empty), so a failed run leaves the
# machine as it was.
CREATED_PARENTS=()
_remove_created_parents() {
    local i
    for (( i = ${#CREATED_PARENTS[@]} - 1; i >= 0; i-- )); do
        rmdir -- "${CREATED_PARENTS[$i]}" 2>/dev/null ||
            echo "[WARN] Could not remove ${CREATED_PARENTS[$i]}, which this run created (is it still empty?)"
    done
}
if [ "$MOVE_NEEDED" = true ]; then
    for d in "${TO_MISSING[@]}"; do
        [ -e "$d" ] && continue
        if ! mkdir_err="$(mkdir -- "$d" 2>&1)"; then
            _remove_created_parents
            echo "[ERROR] Could not create $d: $mkdir_err"
            echo "Nothing was changed."
            exit 1
        fi
        CREATED_PARENTS+=("$d")
        echo "[OK] Created $d"
    done
    [ "$TO_EMPTY" = true ] && rmdir "$TO" 2>/dev/null
    # One rename(2): the device check above put From and To's nearest existing
    # parent on one filesystem, and mv only falls back to copying across filesystems.
    if ! mv_err="$(mv -- "$FROM" "$TO" 2>&1)"; then
        [ "$TO_EMPTY" = true ] && [ ! -e "$TO" ] && mkdir "$TO"
        _remove_created_parents
        echo "[ERROR] Could not rename $FROM to $TO: $mv_err"
        echo "        Close the programs and terminals that use files under it (editors,"
        echo "        Claude Code, shells whose current folder is inside it), then run this again."
        echo "Nothing was changed."
        exit 1
    fi
    echo "[OK] Moved $FROM -> $TO"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="$HOME_N/.scripts-move-$STAMP"
n=1
while [ -e "$RUN_DIR" ]; do RUN_DIR="$(printf '%s/.scripts-move-%s-%02d' "$HOME_N" "$STAMP" "$n")"; n=$((n + 1)); done
BACKUP_DIR="$RUN_DIR/backup"
mkdir -p "$BACKUP_DIR"
for d in "${CREATED_PARENTS[@]}"; do CHANGES+=("created $d"); done
[ "$MOVE_NEEDED" = true ] && CHANGES+=("moved $FROM -> $TO")

# --- Repairs (R11-R17) -----------------------------------------------------------
echo "[STEP] Repairing worktrees...";       repair_worktrees
# Links before the generators: create_symlink then finds them in place.
echo "[STEP] Repairing links...";           repair_links
echo "[STEP] Re-running generators...";     run_generators
echo "[STEP] Rewriting text files...";      repair_text_files
echo "[STEP] Updating the crontab...";      repair_crontab
echo "[STEP] Updating systemd units...";    repair_systemd
echo "[STEP] Updating launchd agents...";   repair_launchd
echo "[STEP] Renaming Claude projects...";  rename_projects
cd "$HOME_N" || true

# --- Rescan and report (R18) -------------------------------------------------------
MOVE_ACTIVE_UNITS="|"
build_plan "$TO"
REMAINING=()
if [ -n "$PLAN_WT" ]; then
    while IFS="$(printf '\t')" read -r repo wt; do REMAINING+=("worktree $wt of $repo still names the old root"); done <<< "$PLAN_WT"
fi
while IFS= read -r repo; do
    [ -n "$repo" ] && [ -d "$repo/.git/worktrees" ] || continue
    while IFS= read -r line; do
        case "$line" in
            prunable*) REMAINING+=("git worktree list in $repo: $line") ;;
            "worktree "*) _under_old "${line#worktree }" && REMAINING+=("git worktree list in $repo: $line") ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
done < <(_repo_dirs "$TO")
for t in "${PLAN_GEN_TEXT[@]}"; do REMAINING+=("still names the old root: $t"); done
for i in "${!PLAN_LINKS[@]}"; do REMAINING+=("link ${PLAN_LINKS[$i]} -> ${PLAN_LINK_OLD[$i]}"); done
for i in "${!PLAN_TEXT[@]}"; do REMAINING+=("${PLAN_TEXT[$i]} (${PLAN_TEXT_N[$i]})"); done
if [ -n "$PLAN_CRON" ]; then
    while IFS= read -r line; do REMAINING+=("crontab: $line"); done <<< "$PLAN_CRON"
fi
for f in "${PLAN_UNITS[@]}"; do REMAINING+=("systemd user unit $f"); done
for f in "${PLAN_PLISTS[@]}"; do REMAINING+=("launchd agent $f"); done
for i in "${!PLAN_PROJ[@]}"; do
    if [ "${PLAN_PROJ_BLOCKED[$i]}" = true ]; then
        REMAINING+=("Claude project folder ${PLAN_PROJ[$i]}; ${PLAN_PROJ_NEW[$i]} already exists, merge them by hand")
    else
        REMAINING+=("Claude project folder ${PLAN_PROJ[$i]}")
    fi
done

REPORT_ONLY=()
if [ -n "$PLAN_VENVS" ]; then
    while IFS= read -r f; do REPORT_ONLY+=("Python venv to recreate: $f"); done <<< "$PLAN_VENVS"
fi
for f in "${PLAN_SYSTEM[@]}"; do REPORT_ONLY+=("System scope: $f"); done
for f in "${PLAN_APPSTATE[@]}"; do REPORT_ONLY+=("App state that mentions the old root: $f"); done
for f in "${PLAN_INREPO[@]}"; do REPORT_ONLY+=("Link into a repo (not edited): $f"); done
if [ "$CLONE_UNDER_TO" = false ]; then
    REPORT_ONLY+=("This repo's generators were skipped: the clone ($REPO_ROOT) is not under $TO; run its install.sh there")
fi

REPORT="$RUN_DIR/report.txt"
FAIL_COUNT=$((${#FAILURES[@]} + ${#REMAINING[@]}))
{
    echo "Scripts root move report"
    echo "From:    $FROM"
    echo "To:      $TO"
    echo "Date:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Backups: $BACKUP_DIR"
    echo ""
    _section "(a) Changes made:" "${CHANGES[@]}"
    echo ""
    _section "(b) Failures:" "${FAILURES[@]}"
    echo ""
    _section "(c) Remaining references to the old root (counted as failures):" "${REMAINING[@]}"
    echo ""
    _section "(d) Report only (not changed, not counted as failures):" "${REPORT_ONLY[@]}"
    echo ""
    if [ "$FAIL_COUNT" -eq 0 ]; then echo "Result: OK"
    else echo "Result: $FAIL_COUNT failure(s). Fix them, then run this again to finish."; fi
} > "$REPORT"
echo ""
cat "$REPORT"
echo ""
echo "Report: $REPORT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
