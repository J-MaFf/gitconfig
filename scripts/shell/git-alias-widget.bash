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

# Bind only in interactive shells. Change \C-g to rebind.
# The widget edits READLINE_LINE/READLINE_POINT, which bash only has since 4.0.
# Under the stock macOS /bin/bash 3.2, `bind -x` succeeds but Ctrl-G would do
# nothing, so skip the binding there and say why (issue #234). On a Mac, zsh
# (the default shell) or Homebrew's bash (brew install bash) gets Ctrl-G.
case $- in
    *i*)
        if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
            bind -x '"\C-g": __git_alias_insert' 2>/dev/null
        else
            echo "git-alias widget: Ctrl-G needs bash 4+ (this is bash ${BASH_VERSION}); use zsh or Homebrew bash. 'git alias' still works." >&2
        fi
        ;;
esac
