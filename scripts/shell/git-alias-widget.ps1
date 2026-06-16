# git-alias browser keybinding for PowerShell / PSReadLine (Ctrl-G).
#
# Opens the interactive `git alias` browser; the alias you select (Enter or
# click) is inserted onto the current command line, ready to run or edit.
# A program launched by `git alias` runs in a subprocess and cannot type at the
# prompt itself, so this PSReadLine key handler does the insertion.
#
# Enable by dot-sourcing this file from your $PROFILE:
#   . "C:\path\to\gitconfig\scripts\shell\git-alias-widget.ps1"

if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g' `
        -BriefDescription 'GitAliasBrowser' `
        -LongDescription 'Browse git aliases and insert the chosen command' `
        -ScriptBlock {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                # UI renders on the terminal; the chosen "git <alias>" lands in $tmp.
                git alias --out $tmp
                $selection = (Get-Content -Raw -ErrorAction SilentlyContinue $tmp)
            }
            finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
            if ($selection) {
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($selection.Trim())
            }
        }
}
