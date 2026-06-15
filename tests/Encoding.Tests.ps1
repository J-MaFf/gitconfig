BeforeDiscovery {
    # Discover every Windows PowerShell script so each gets its own test case.
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $windowsScriptDir = Join-Path $repoRoot "scripts\windows version"
    $scriptFiles = Get-ChildItem -Path $windowsScriptDir -Filter *.ps1 -File |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
}

Describe "Windows script encoding" -Tag 'Unit' {

    # Windows PowerShell 5.1 reads BOM-less files as the system ANSI codepage.
    # Any non-ASCII character (e.g. an em dash) is then decoded into garbage
    # bytes, one of which can be treated as a smart-quote and break parsing.
    # Keeping these scripts ASCII-only guarantees they parse under 5.1.
    Context "<Name>" -ForEach $scriptFiles {

        It "contains only ASCII characters" {
            $text = [System.IO.File]::ReadAllText($Path)
            $nonAscii = [regex]::Matches($text, '[^\x00-\x7F]')
            $detail = ($nonAscii |
                ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } |
                Select-Object -Unique) -join ', '
            $nonAscii.Count | Should -Be 0 -Because "non-ASCII chars break Windows PowerShell 5.1 parsing (found: $detail)"
        }

        It "parses without syntax errors" {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0 -Because "the script must be syntactically valid"
        }
    }
}
