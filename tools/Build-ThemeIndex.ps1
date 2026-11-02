<#
.SYNOPSIS
  Builds themes\themes.json (the themes shipped with styley) from an iTerm2-Color-Schemes checkout.

.DESCRIPTION
  By default only schemes whose licence in licenses.yml allows redistribution are included
  (anything except `unknown` and `nonfree`). Users get the full collection on their own machine
  with `styley update` or `styley import`.

  Also writes themes\LICENSES.md with the licence and source of every bundled scheme.

.EXAMPLE
  .\tools\Build-ThemeIndex.ps1 -Source .\SNAP\iTerm2-Color-Schemes-master
#>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'themes'),
    [switch]$All
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\styley.ps1')

$src = (Resolve-Path -LiteralPath $Source).Path
$themes = @(Read-ThemeSource -Path $src -RedistributableOnly:(-not $All) -Origin 'bundled')
if (-not $themes) { throw "No themes found in $src" }

Write-ThemeIndex -Themes $themes -Path (Join-Path $OutDir 'themes.json') -Source 'https://github.com/mbadolato/iTerm2-Color-Schemes'

# Licence table for the bundled schemes.
$sources = @{}
$cur = $null
$licFile = Join-Path $src 'licenses.yml'
if (Test-Path -LiteralPath $licFile) {
    foreach ($l in [IO.File]::ReadAllLines($licFile)) {
        if ($l -match '^([^#\s].*):\s*$') { $cur = $Matches[1].Trim().Trim("'").Trim('"') }
        elseif ($cur -and $l -match '^\s+source:\s*(.*?)\s*$') { $sources[$cur] = $Matches[1].Trim("'").Trim('"') }
    }
}
$md = New-Object Text.StringBuilder
[void]$md.AppendLine('# Bundled colour schemes')
[void]$md.AppendLine('')
[void]$md.AppendLine('The schemes in `themes.json` come from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)')
[void]$md.AppendLine('(collection: MIT, Copyright (c) 2011 to Present Mark Badolato). Each scheme belongs to its author and keeps')
[void]$md.AppendLine('its own licence, listed below as recorded in the upstream `licenses.yml`. Only schemes with a known')
[void]$md.AppendLine('licence that allows redistribution are bundled; `styley update` downloads the rest on your machine.')
[void]$md.AppendLine('')
[void]$md.AppendLine("Schemes: $($themes.Count)")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Scheme | Licence | Source |')
[void]$md.AppendLine('|---|---|---|')
foreach ($t in ($themes | Sort-Object Name)) {
    $s = ''; if ($sources.ContainsKey($t.Name)) { $s = $sources[$t.Name] }
    [void]$md.AppendLine("| $($t.Name.Replace('|', '\|')) | $($t.License) | $s |")
}
[IO.File]::WriteAllText((Join-Path $OutDir 'LICENSES.md'), $md.ToString(), (New-Object Text.UTF8Encoding($false)))

Write-Host "Wrote $($themes.Count) themes to $OutDir"
