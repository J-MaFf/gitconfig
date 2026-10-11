# git-alias browser keybinding for PowerShell / PSReadLine (Ctrl-G).
#
# Opens the interactive `git alias` browser; the alias you select (Enter or
# click) is inserted onto the current command line, ready to run or edit.
# A program launched by `git alias` runs in a subprocess and cannot type at the
# prompt itself, so this PSReadLine key handler does the insertion.
#
# Enable by dot-sourcing this file from your $PROFILE:
#   . "C:\path\to\gitconfig\scripts\shell\git-alias-widget.ps1"

function Invoke-GitAliasBrowser {
    <#
    .SYNOPSIS
    Runs the `git alias` browser on the console and returns the chosen command.

    .DESCRIPTION
    PSReadLine runs key handlers with native commands' stdout/stderr redirected,
    so a plain `git alias --out $tmp` sees no terminal and the browser never
    opens (#254). Start-Process -NoNewWindow with no -Redirect* switches lets
    git inherit the console instead, like the bash/zsh widgets'
    `</dev/tty >/dev/tty`. The chosen "git <alias>" is written to a temp file.

    .OUTPUTS
    $null if git is not on PATH; otherwise an object with Selection (the chosen
    command, or $null if nothing was picked) and ExitCode (git's exit code).
    #>
    $git = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $git) { return $null }

    $tmp = [System.IO.Path]::GetTempFileName()
    $proc = $null
    $selection = $null
    try {
        # Start-Process joins -ArgumentList with spaces (5.1 and 7), so quote
        # the temp path in case it contains spaces.
        $proc = Start-Process -FilePath $git.Source `
            -ArgumentList @('alias', '--out', ('"{0}"' -f $tmp)) `
            -NoNewWindow -Wait -PassThru
        $selection = Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }

    $exitCode = 0
    if ($proc -and $proc.ExitCode) { $exitCode = $proc.ExitCode }
    if ($selection) { $selection = $selection.Trim() }
    if (-not $selection) { $selection = $null }
    [pscustomobject]@{ Selection = $selection; ExitCode = $exitCode }
}

if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g' `
        -BriefDescription 'GitAliasBrowser' `
        -LongDescription 'Browse git aliases and insert the chosen command' `
        -ScriptBlock {
            $result = Invoke-GitAliasBrowser
            if (-not $result) { return }
            if ($result.ExitCode -ne 0) {
                # `git alias --out` explained the failure on stderr: keep that
                # message on screen and draw a fresh prompt below it.
                [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, [Console]::CursorTop)
            }
            else {
                # Repaint the prompt after the full-screen UI exits.
                [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            }
            if ($result.Selection) {
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result.Selection)
            }
        }
}
