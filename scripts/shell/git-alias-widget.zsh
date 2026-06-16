# git-alias browser keybinding for zsh (Ctrl-G).
#
# Opens the interactive `git alias` browser; the alias you select (Enter or
# click) is inserted onto the current command line, ready to run or edit.
# A program launched by `git alias` runs in a subprocess and cannot type at the
# prompt itself, so this ZLE widget does the insertion. Modeled on fzf.
#
# Enable by sourcing this file from ~/.zshrc:
#   [ -f /path/to/gitconfig/scripts/shell/git-alias-widget.zsh ] && \
#     source /path/to/gitconfig/scripts/shell/git-alias-widget.zsh

__git_alias_insert() {
    command -v git >/dev/null 2>&1 || return 0
    local tmp selection
    tmp=$(mktemp) || return 0
    # UI renders on the terminal; the chosen "git <alias>" lands in $tmp.
    git alias --out "$tmp" </dev/tty >/dev/tty 2>/dev/tty
    selection=$(cat "$tmp" 2>/dev/null)
    command rm -f "$tmp"
    if [[ -n "$selection" ]]; then
        # Insert at the cursor (LBUFFER is the text left of the cursor).
        LBUFFER+="$selection"
    fi
    # Repaint the prompt after the full-screen UI exits.
    zle reset-prompt
}

zle -N __git_alias_insert
bindkey '^g' __git_alias_insert  # Ctrl-G; change to rebind.
