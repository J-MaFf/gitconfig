#!/bin/bash
# Shared bash utilities sourced by mac and linux gitconfig scripts.
# Source this file from a script that has already set REPO_ROOT and HOME_DIR.

# Generate ~/.gitconfig from .gitconfig.template
# Usage: generate_gitconfig REPO_ROOT HOME_DIR FORCE
generate_gitconfig() {
    local repo_root="$1"
    local home_dir="$2"
    local force="${3:-false}"
    local template_path="$repo_root/.gitconfig.template"
    local output_path="$home_dir/.gitconfig"

    echo "Git Configuration Generator"
    echo "====================================="
    echo "Repository: $repo_root"
    echo "Home Directory: $home_dir"
    echo "Template: $template_path"
    echo "Output: $output_path"
    echo ""

    if [ ! -f "$template_path" ]; then
        echo "[ERROR] Template not found: $template_path"
        return 1
    fi

    local generated_content
    generated_content=$(cat "$template_path")
    generated_content="${generated_content//\{\{REPO_PATH\}\}/$repo_root}"
    generated_content="${generated_content//\{\{HOME_DIR\}\}/$home_dir}"

    # Idempotent: if ~/.gitconfig already matches the rendered template, do nothing
    # (no prompt, no backup, no write). This makes the auto-update convergent and
    # safe to run on every login regardless of whether a pull happened.
    if [ -f "$output_path" ] && [ "$(cat "$output_path")" = "$generated_content" ]; then
        echo "[OK] .gitconfig already up to date (matches template)"
        return 0
    fi

    # A ~/.gitconfig that is a symlink into this repo is a leftover from an old
    # install that linked it instead of generating it. Writing through it would
    # clobber a file inside the repo, and backing it up would only save a link,
    # so drop the link and write a real file in its place.
    if _link_points_into "$output_path" "$repo_root"; then
        rm -f "$output_path"
        echo "[INFO] Replaced the old ~/.gitconfig symlink into the repo with a generated file"
    fi

    if [ -f "$output_path" ] && [ "$force" = "false" ]; then
        echo ".gitconfig already exists at: $output_path"
        read -p "Overwrite? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    if [ -f "$output_path" ]; then
        warn_dropped_gitconfig_keys "$output_path" "$generated_content"
        backup_copy "$output_path"
    fi

    echo "$generated_content" > "$output_path"
    echo "[OK] Generated .gitconfig"
    echo ""

    if git config --file "$output_path" --list > /dev/null 2>&1; then
        echo "[OK] Git configuration verified!"
    else
        echo "[WARN] Git may have issues reading the configuration"
    fi

    echo ""
    echo "Configuration generated successfully!"
    echo "====================================="
    echo ""
    echo "Generated values:"
    echo "  Repository Path: $repo_root"
    echo "  Home Directory: $home_dir"
    echo ""
    echo "To customize, edit the template ($template_path) and re-run,"
    echo "or add overrides to ~/.gitconfig.local"
    echo ""
}

# Warn about settings in EXISTING_PATH that regenerating ~/.gitconfig drops
# (e.g. ones `gh auth setup-git`, `git lfs install` or `git config --global`
# wrote). A setting counts as dropped when its key is missing from the new
# content, or, for a multi-valued key such as safe.directory, when that exact
# value is missing. A single-valued key the template simply changes (an alias
# edited upstream) is not reported. Only key names are printed, never values;
# the backup taken right after keeps the values.
# Usage: warn_dropped_gitconfig_keys EXISTING_PATH NEW_CONTENT
warn_dropped_gitconfig_keys() {
    local existing="$1" new_content="$2" tmp dropped
    command -v git >/dev/null 2>&1 || return 0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitconfig-keys.XXXXXX")" || return 0
    printf '%s\n' "$new_content" > "$tmp/new.cfg"
    git config --file "$tmp/new.cfg" --list > "$tmp/new.list" 2>/dev/null
    git config --file "$existing" --list > "$tmp/old.list" 2>/dev/null
    dropped="$(awk '
        FILENAME == ARGV[1] { k = $0; sub(/=.*/, "", k); have[$0] = 1; newn[k]++; next }
        { k = $0; sub(/=.*/, "", k); oldn[k]++; line[++n] = $0; key[n] = k }
        END {
            for (i = 1; i <= n; i++) {
                k = key[i]
                if (!(k in newn)) { print k; continue }
                if ((oldn[k] > 1 || newn[k] > 1) && !(line[i] in have)) print k
            }
        }' "$tmp/new.list" "$tmp/old.list" | LC_ALL=C sort -u)"
    rm -rf "$tmp"
    [ -n "$dropped" ] || return 0
    echo "[WARN] ~/.gitconfig has settings the template doesn't; regenerating drops them:"
    printf '%s\n' "$dropped" | sed 's/^/         /'
    echo "       They are kept in the backup below. To keep a setting, put it in"
    echo "       ~/.gitconfig.local (git config --file ~/.gitconfig.local <key> <value>)."
}

# ---------------------------------------------------------------------------
# Backups
#
# Every backup is timestamped (<file>.bak.YYYYMMDD-HHMMSS) so a second install
# or the login auto-update can never overwrite the backup of the user's
# original file. Only the newest GITCONFIG_BACKUP_KEEP backups of each file are
# kept (default 5; 0 keeps them all). Older single-slot backups from previous
# versions (Existing.<file>.bak, .gitconfig.bak) are never touched.
# ---------------------------------------------------------------------------

# Print a not-yet-used timestamped backup path for TARGET.
# The timestamp goes last so the names sort oldest-first; a same-second
# collision gets a zero-padded counter, which still sorts after the bare stamp.
# Usage: _backup_path TARGET
_backup_path() {
    local target="$1" stamp candidate n=1
    stamp="$(date '+%Y%m%d-%H%M%S')"
    candidate="$target.bak.$stamp"
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do
        candidate="$target.bak.$stamp-$(printf '%02d' "$n")"
        n=$((n + 1))
    done
    printf '%s\n' "$candidate"
}

# Delete all but the newest KEEP timestamped backups of TARGET.
# KEEP defaults to $GITCONFIG_BACKUP_KEEP, then 5. 0 disables pruning.
# Only names this file's _backup_path produces are considered.
# Usage: prune_backups TARGET [KEEP]
prune_backups() {
    local target="$1" keep="${2:-${GITCONFIG_BACKUP_KEEP:-5}}" list count f
    case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
    if [ "$keep" -eq 0 ]; then return 0; fi
    list="$(
        for f in "$target".bak.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*; do
            if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "$f"; fi
        done | LC_ALL=C sort
    )"
    [ -n "$list" ] || return 0
    count="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
    [ "$count" -gt "$keep" ] || return 0
    printf '%s\n' "$list" | head -n "$((count - keep))" | while IFS= read -r f; do
        rm -f -- "$f"
    done
}

# Succeed if PATH is a symlink whose target lies inside DIR (e.g. a link this
# tool created into the repo). Such a link holds no user data, so it is
# replaced or removed without a backup.
# Usage: _link_points_into PATH DIR
_link_points_into() {
    local link="$1" dir="$2" target target_dir real_dir
    [ -n "$dir" ] && [ -L "$link" ] || return 1
    target="$(readlink "$link")" || return 1
    case "$target" in /*) ;; *) target="$(dirname "$link")/$target" ;; esac
    real_dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || real_dir="$dir"
    target_dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd -P)" || target_dir="$(dirname "$target")"
    case "$target_dir/" in "$real_dir"/*) return 0 ;; esac
    case "$target" in "$dir"/*) return 0 ;; esac
    return 1
}

# Copy TARGET to a timestamped backup (TARGET stays in place), then prune.
# Use before overwriting a file in place.
# Usage: backup_copy TARGET
backup_copy() {
    local target="$1" backup
    [ -f "$target" ] || return 1
    backup="$(_backup_path "$target")"
    cp -p "$target" "$backup"
    echo "[INFO] Backed up existing $(basename "$target") to $(basename "$backup")"
    prune_backups "$target"
    return 0
}

# Move TARGET out of the way to a timestamped backup, then prune.
# If REPO_ROOT is given and TARGET is a symlink into it, the link is just
# removed: it is ours and holds nothing worth keeping, and backing it up would
# push a real backup out of the retention window.
# Returns 0 if TARGET was backed up or removed, 1 if it was not found.
# Usage: backup_file TARGET [REPO_ROOT]
backup_file() {
    local target="$1" repo_root="${2:-}" filename backup
    filename="$(basename "$target")"

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        echo "[SKIP] $filename not found"
        return 1
    fi

    if [ -n "$repo_root" ] && _link_points_into "$target" "$repo_root"; then
        rm -f "$target"
        echo "[OK] Removed $filename (symlink into the repo; no backup needed)"
        return 0
    fi

    backup="$(_backup_path "$target")"
    mv "$target" "$backup"
    echo "[OK] Backed up $filename to $(basename "$backup")"
    prune_backups "$target"
    return 0
}

# Create a symlink from SOURCE to LINK. An existing LINK that is already the
# right symlink is left alone; a symlink into REPO_ROOT (default: the directory
# holding SOURCE) is replaced without a backup; anything else is moved to a
# timestamped backup first.
# Usage: create_symlink SOURCE LINK FORCE [REPO_ROOT]
# Returns 0 on success or skip, 1 on error
create_symlink() {
    local source_file="$1"
    local link_path="$2"
    local force="${3:-false}"
    local repo_root="${4:-$(dirname "$1")}"
    local file
    file="$(basename "$link_path")"

    if [ ! -f "$source_file" ]; then
        echo "[ERROR] Source not found: $source_file"
        return 1
    fi

    if [ -L "$link_path" ] && [ "$link_path" -ef "$source_file" ]; then
        echo "[OK] $file already linked"
        return 0
    fi

    if _link_points_into "$link_path" "$repo_root"; then
        rm -f "$link_path"
    elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
        if [ "$force" = "false" ]; then
            read -p "$file exists. Overwrite? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: $file"
                return 0
            fi
        fi
        backup_file "$link_path"
    fi

    if ln -s "$source_file" "$link_path" 2>/dev/null; then
        echo "[OK] Linked $file"
        return 0
    else
        echo "[FAIL] Could not create symlink for $file"
        return 1
    fi
}

# Print the numeric uid that owns a path. BSD stat (macOS) and GNU stat (Linux)
# disagree on flags, so try both.
# GNU form (-c) MUST come first: on Linux `stat -f` means --file-system, so
# `stat -f %u` dumps a filesystem-info block to stdout and only then exits
# non-zero — the `2>/dev/null` hides the stderr but the garbage is on stdout, so
# a BSD-first order returns "<filesystem block>\n<uid>" on Linux. `stat -c` fails
# cleanly on macOS (no stdout, error to stderr), so GNU-first is safe both ways
# and preserves the non-zero exit for a missing path (issue #195).
# Usage: file_owner_uid PATH
file_owner_uid() {
    stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null
}

# Upsert the current signing identity into an allowed_signers file so git can
# verify SSH commit signatures locally. Without it, `git log --show-signature`
# and `git verify-commit` report "No signature" even though commits are signed.
# Reads the signing key and email from git config. Idempotent: re-running does not
# duplicate the line, and entries for other identities are preserved.
# Usage: update_allowed_signers ALLOWED_SIGNERS_PATH
update_allowed_signers() {
    local allowed_signers_path="$1"
    local signing_key signer_email raw_key pub_key candidate ssh_dir line

    # `|| true` keeps `set -e` from aborting when a key is unset (git config
    # --get exits non-zero); the empty-check below handles it gracefully.
    signing_key="$(git config --get user.signingkey 2>/dev/null || true)"
    signer_email="$(git config --get user.email 2>/dev/null || true)"

    if [ -z "$signing_key" ] || [ -z "$signer_email" ]; then
        echo "[WARN] No user.signingkey/user.email configured; skipped allowed_signers"
        return 0
    fi

    # Resolve the public key: either the literal key (1Password) or a *.pub file
    # (file-based signing key path).
    case "$signing_key" in
        ssh-*|sk-ssh-*|ecdsa-*)
            raw_key="$signing_key"
            ;;
        *)
            candidate="$signing_key"
            case "$candidate" in
                *.pub) ;;
                *) candidate="$candidate.pub" ;;
            esac
            [ -f "$candidate" ] && raw_key="$(cat "$candidate")"
            ;;
    esac

    if [ -z "$raw_key" ]; then
        echo "[WARN] Could not resolve signing public key; skipped allowed_signers"
        return 0
    fi

    # Normalize to "<keytype> <base64>" — drop any trailing comment.
    pub_key="$(printf '%s' "$raw_key" | awk '{print $1" "$2}')"

    ssh_dir="$(dirname "$allowed_signers_path")"
    [ -d "$ssh_dir" ] || mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir" 2>/dev/null || true

    line="$signer_email namespaces=\"git\" $pub_key"
    if [ -f "$allowed_signers_path" ] && grep -qF -- "$line" "$allowed_signers_path"; then
        echo "[OK] allowed_signers already up to date"
    else
        printf '%s\n' "$line" >> "$allowed_signers_path"
        echo "[OK] Updated $allowed_signers_path"
    fi
}

# Markers delimiting the git-alias browser keybinding block in a shell rc file.
# Kept in one place so enable/disable stay in sync.
GIT_ALIAS_WIDGET_BEGIN="# >>> gitconfig git-alias browser (Ctrl-G) >>>"
GIT_ALIAS_WIDGET_END="# <<< gitconfig git-alias browser <<<"

# Source the interactive git-alias browser keybinding (Ctrl-G) from the user's
# shell rc files (~/.zshrc, ~/.bashrc). Idempotent: a guarded marker block is
# added once per rc file. A non-existent rc is only created when it matches the
# login shell, so we never spawn rc files for shells the user does not use.
# Args: repo_root, home_dir
enable_git_alias_widget() {
    local repo_root="$1" home_dir="$2"
    local current_shell; current_shell="$(basename "${SHELL:-}")"
    local rc widget kind
    for kind in zsh bash; do
        rc="$home_dir/.${kind}rc"
        widget="$repo_root/scripts/shell/git-alias-widget.$kind"
        if [ ! -f "$rc" ]; then
            [ "$current_shell" = "$kind" ] || continue
            : > "$rc"
        fi
        if grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$rc" 2>/dev/null; then
            echo "[OK] git-alias keybinding already enabled in $rc"
            continue
        fi
        {
            echo ""
            echo "$GIT_ALIAS_WIDGET_BEGIN"
            echo "[ -f \"$widget\" ] && source \"$widget\""
            echo "$GIT_ALIAS_WIDGET_END"
        } >> "$rc"
        echo "[OK] Enabled git-alias keybinding (Ctrl-G) in $rc"
    done
}

# Remove the git-alias browser keybinding block from the user's shell rc files.
# Args: home_dir
disable_git_alias_widget() {
    local home_dir="$1"
    local rc tmp
    for rc in "$home_dir/.zshrc" "$home_dir/.bashrc"; do
        [ -f "$rc" ] || continue
        grep -qF "$GIT_ALIAS_WIDGET_BEGIN" "$rc" 2>/dev/null || continue
        tmp="$(mktemp)" || continue
        awk -v b="$GIT_ALIAS_WIDGET_BEGIN" -v e="$GIT_ALIAS_WIDGET_END" '
            $0 == b { skip = 1 }
            skip && $0 == e { skip = 0; next }
            !skip { print }
        ' "$rc" > "$tmp" && cat "$tmp" > "$rc"
        rm -f "$tmp"
        echo "[OK] Disabled git-alias keybinding in $rc"
    done
}

# pip install helper: quiet, normal then a --break-system-packages retry for PEP
# 668 "externally-managed" environments (Homebrew/Debian system Python).
# Usage: _pip_install PYTHON_BIN PKG...
_pip_install() {
    local py="$1"; shift
    "$py" -m pip install --quiet "$@" >/dev/null 2>&1 \
        || "$py" -m pip install --quiet --break-system-packages "$@" >/dev/null 2>&1
}

# Install the Python dependencies declared in pyproject.toml (read via
# scripts/shared/deps.py): the required deps (rich) plus the optional 'tui' group
# (textual). Single source of truth for what gets installed — the mac/linux
# installers and the login auto-update all call this instead of duplicating pip
# logic. Idempotent (only installs what is not already importable), resolves the
# interpreter py -> python3 -> python like the git aliases, and treats a failed
# *optional* install as a warning (the helper falls back to a static table).
# Every fallible step is guarded so this is safe under `set -e`.
# Usage: install_python_deps REPO_ROOT
install_python_deps() {
    local repo_root="$1"
    local deps_py="$repo_root/scripts/shared/deps.py"
    local py="" p spec name
    local -a required=() optional=() need_required=() need_optional=()

    for p in py python3 python; do
        if command -v "$p" >/dev/null 2>&1 && "$p" -c '' >/dev/null 2>&1; then
            py="$p"; break
        fi
    done
    if [ -z "$py" ]; then
        echo "[WARN] No Python interpreter found; skipping rich/textual (install Python 3, then re-run)"
        return 0
    fi
    if [ ! -f "$deps_py" ]; then
        echo "[WARN] $deps_py not found; skipping Python dependency install"
        return 0
    fi
    if ! "$py" -m pip --version >/dev/null 2>&1; then
        echo "[WARN] pip unavailable for $py; install rich (and optionally textual) manually"
        return 0
    fi

    # Declared specs, one per line, into arrays (avoids word-splitting on '>=').
    while IFS= read -r spec; do [ -n "$spec" ] && required+=("$spec"); done < <("$py" "$deps_py" required)
    while IFS= read -r spec; do [ -n "$spec" ] && optional+=("$spec"); done < <("$py" "$deps_py" optional)

    # Only install what is not already importable (import name = spec minus any
    # version operator: "rich>=13" -> "rich").
    for spec in "${required[@]}"; do
        name="${spec%%[<>=!~ ]*}"
        "$py" -c "import ${name}" >/dev/null 2>&1 || need_required+=("$spec")
    done
    for spec in "${optional[@]}"; do
        name="${spec%%[<>=!~ ]*}"
        "$py" -c "import ${name}" >/dev/null 2>&1 || need_optional+=("$spec")
    done

    if [ "${#need_required[@]}" -eq 0 ] && [ "${#need_optional[@]}" -eq 0 ]; then
        echo "[OK] Python dependencies already present (rich + textual)"
        return 0
    fi

    if [ "${#need_required[@]}" -gt 0 ]; then
        # Try required + optional together; if that fails, make sure the required
        # land even when an optional dep is unavailable on this platform.
        if [ "${#need_optional[@]}" -gt 0 ] && _pip_install "$py" "${need_required[@]}" "${need_optional[@]}"; then
            echo "[OK] Installed Python deps: ${need_required[*]} ${need_optional[*]}"
        elif _pip_install "$py" "${need_required[@]}"; then
            if [ "${#need_optional[@]}" -gt 0 ]; then
                echo "[OK] Installed required Python deps: ${need_required[*]} (optional unavailable; 'git alias' uses the static table)"
            else
                echo "[OK] Installed required Python deps: ${need_required[*]}"
            fi
        else
            echo "[WARN] Could not install required Python deps (${need_required[*]}) — run: $py -m pip install ${need_required[*]}"
        fi
    elif [ "${#need_optional[@]}" -gt 0 ]; then
        if _pip_install "$py" "${need_optional[@]}"; then
            echo "[OK] Installed optional Python deps: ${need_optional[*]}"
        else
            echo "[WARN] Optional Python deps unavailable (${need_optional[*]}); 'git alias' uses the static table"
        fi
    fi
    return 0
}
