# git-alias browser keybinding for bash (Ctrl-G).
#
# Opens the interactive `git alias` browser; the alias you select (Enter or
# click) is inserted onto the current command line, ready to run or edit.
# A program launched by `git alias` runs in a subprocess and cannot type at the
# prompt itself, so this readline widget does the insertion. Modeled on fzf.
#
# Enable by sourcing this file from ~/.bashrc:
#   [ -f /path/to/gitconfig/scripts/shell/git-alias-widget.bash ] && \
#     source /path/to/gitconfig/scripts/shell/git-alias-widget.bash

__git_alias_insert() {
    command -v git >/dev/null 2>&1 || return 0
    local tmp selection
    tmp=$(mktemp) || return 0
    # UI renders on the terminal; the chosen "git <alias>" lands in $tmp.
    git alias --out "$tmp" </dev/tty >/dev/tty 2>/dev/tty
    selection=$(cat "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ -n "$selection" ] || return 0
    # Insert at the cursor, then advance the cursor past the inserted text.
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${selection}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT + ${#selection}))
}

# Bind only in interactive shells that support `bind -x`. Change \C-g to rebind.
case $- in
    *i*) bind -x '"\C-g": __git_alias_insert' 2>/dev/null ;;
esac
