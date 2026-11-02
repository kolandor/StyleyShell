<#
  styley - colour themes for Windows PowerShell and CMD (classic console host).

  Run `styley help` for usage. This file is the whole tool; bin\styley.cmd runs it with
  -ExecutionPolicy Bypass so it works from CMD and from PowerShell alike.

  Dot-sourcing the file (`. .\styley.ps1`) only defines the functions; tools\Build-ThemeIndex.ps1
  uses that.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Version = '0.2.0'
$script:Root = Split-Path -Parent $PSScriptRoot          # repo or install root
$script:DataDir = Join-Path $env:LOCALAPPDATA 'styley'   # user data: imported themes, backups, state
$script:E = [char]27

# ANSI order used by theme files -> Windows console table order.
# Console index:  0     1     2      3     4    5       6       7
#                 black blue  green  cyan  red  purple  yellow  white   (+8 = bright)
$script:AnsiNames = @('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
    'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')
$script:ConsoleFromAnsi = @(0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15)

$script:ShellExes = @('powershell.exe', 'pwsh.exe', 'cmd.exe')
$script:ConsoleColorValues = @('ScreenColors', 'PopupColors') + (0..15 | ForEach-Object { 'ColorTable{0:D2}' -f $_ })

# --------------------------------------------------------------------------------------------
# Native helpers
# --------------------------------------------------------------------------------------------

function Initialize-Native {
    if ('Styley.Console' -as [type]) { return }
    $src = Join-Path $PSScriptRoot 'StyleyNative.cs'
    $code = [IO.File]::ReadAllText($src)
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($code))[0..5] | ForEach-Object { $_.ToString('x2') })
    $cache = Join-Path $script:DataDir 'cache'
    $dll = Join-Path $cache "StyleyNative-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        Get-ChildItem -LiteralPath $cache -Filter 'StyleyNative-*.dll' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        try {
            Add-Type -TypeDefinition $code -OutputAssembly $dll -OutputType Library
        } catch {
            # Cache not writable or locked: compile in memory instead.
            if (-not ('Styley.Console' -as [type])) { Add-Type -TypeDefinition $code }
            return
        }
    }
    if (-not ('Styley.Console' -as [type])) { Add-Type -Path $dll }
}

# --------------------------------------------------------------------------------------------
# Colour helpers
# --------------------------------------------------------------------------------------------

function ConvertFrom-Hex([string]$Hex) {
    $h = $Hex.TrimStart('#')
    if ($h.Length -eq 3) { $h = -join ($h.ToCharArray() | ForEach-Object { "$_$_" }) }
    if ($h -notmatch '^[0-9a-fA-F]{6}$') { throw "Bad colour '$Hex'" }
    , @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function ConvertTo-Hex([int]$R, [int]$G, [int]$B) { '#{0:x2}{1:x2}{2:x2}' -f $R, $G, $B }

# COLORREF is 0x00BBGGRR.
function ConvertTo-ColorRef([string]$Hex) {
    $c = ConvertFrom-Hex $Hex
    [uint32]($c[0] + ($c[1] -shl 8) + ($c[2] -shl 16))
}

function ConvertFrom-ColorRef([uint32]$Ref) {
    ConvertTo-Hex ($Ref -band 0xFF) (($Ref -shr 8) -band 0xFF) (($Ref -shr 16) -band 0xFF)
}

function Get-Luminance([string]$Hex) {
    $c = ConvertFrom-Hex $Hex
    (0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]) / 255
}

# --------------------------------------------------------------------------------------------
# Terminal output (24-bit colour through VT sequences; plain text when redirected or NO_COLOR)
# --------------------------------------------------------------------------------------------

$script:Color = $false
$script:SavedMode = -1L

function Enable-Color {
    $script:Color = $false
    if ($env:NO_COLOR) { return }
    try { if ([Console]::IsOutputRedirected) { return } } catch { return }
    try {
        Initialize-Native
        $script:SavedMode = [Styley.Console]::EnableVirtualTerminal()
        $script:Color = ($script:SavedMode -ge 0)
    } catch { $script:Color = $false }
}

function Restore-ConsoleMode {
    if ($script:SavedMode -ge 0) { [Styley.Console]::RestoreMode($script:SavedMode); $script:SavedMode = -1L }
}

function Out([string]$Text = '') { [Console]::Out.WriteLine($Text) }

function Fg([string]$Hex) {
    if (-not $script:Color) { return '' }
    $c = ConvertFrom-Hex $Hex; "$($script:E)[38;2;$($c[0]);$($c[1]);$($c[2])m"
}
function Bg([string]$Hex) {
    if (-not $script:Color) { return '' }
    $c = ConvertFrom-Hex $Hex; "$($script:E)[48;2;$($c[0]);$($c[1]);$($c[2])m"
}
function Sgr([string]$Codes) { if ($script:Color) { "$($script:E)[$($Codes)m" } else { '' } }
function Rst { Sgr '0' }
function Bold([string]$Text) { "$(Sgr '1')$Text$(Rst)" }
function Dim([string]$Text) { "$(Sgr '2')$Text$(Rst)" }

function Format-Swatch($Theme, [int]$CellWidth = 2) {
    if (-not $script:Color) { return '' }
    $cell = ' ' * $CellWidth
    $s = ''
    foreach ($hex in $Theme.Ansi) { $s += "$(Bg $hex)$cell" }
    "$s$(Rst)"
}

function Format-Sample($Theme) {
    # Theme background with foreground text: shows the "real" look of the theme.
    if (-not $script:Color) { return '' }
    "$(Bg $Theme.Background)$(Fg $Theme.Foreground) Aa $(Fg $Theme.Ansi[1])Er $(Fg $Theme.Ansi[2])Ok $(Fg $Theme.Ansi[4])Fn $(Rst)"
}

# --------------------------------------------------------------------------------------------
# Themes
# --------------------------------------------------------------------------------------------

# '+' is spelled out so 'Dracula' and 'Dracula+' get different slugs.
function Get-Slug([string]$Name) { ($Name.ToLowerInvariant().Replace('+', ' plus ') -replace '[^a-z0-9]+', '-').Trim('-') }

function New-Theme {
    param([string]$Name, [string[]]$Ansi, [string]$Background, [string]$Foreground,
        [string]$Cursor, [string]$Selection, [string]$License = '', [string]$Origin = '')
    if ($Ansi.Count -ne 16) { throw "Theme '$Name' must have 16 ANSI colours" }
    $norm = { param($h) if ($h) { $c = ConvertFrom-Hex $h; ConvertTo-Hex $c[0] $c[1] $c[2] } else { $null } }
    $a = @($Ansi | ForEach-Object { & $norm $_ })
    $bgHex = & $norm $Background
    if (-not $bgHex) { $bgHex = $a[0] }
    $fgHex = & $norm $Foreground
    if (-not $fgHex) { $fgHex = $a[7] }
    New-ThemeRecord $Name $a $bgHex $fgHex (& $norm $Cursor) (& $norm $Selection) $License $Origin
}

# Builds the theme object from already normalised '#rrggbb' values. Kept free of nested function
# calls: PowerShell 5.1 function calls are slow and this runs for every theme on every start.
function New-ThemeRecord($Name, $Ansi, $Background, $Foreground, $Cursor, $Selection, $License, $Origin) {
    $r = [Convert]::ToInt32($Background.Substring(1, 2), 16)
    $g = [Convert]::ToInt32($Background.Substring(3, 2), 16)
    $b = [Convert]::ToInt32($Background.Substring(5, 2), 16)
    [pscustomobject]@{
        Name       = $Name
        Slug       = ($Name.ToLowerInvariant().Replace('+', ' plus ') -replace '[^a-z0-9]+', '-').Trim('-')
        Ansi       = $Ansi
        Background = $Background
        Foreground = $Foreground
        Cursor     = $Cursor
        Selection  = $Selection
        License    = $License
        Origin     = $Origin
        IsDark     = ((0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255 -lt 0.5)
    }
}

function Get-BuiltinThemes {
    $campbell = @('#0c0c0c', '#c50f1f', '#13a10e', '#c19c00', '#0037da', '#881798', '#3a96dd', '#cccccc',
        '#767676', '#e74856', '#16c60c', '#f9f1a5', '#3b78ff', '#b4009e', '#61d6d6', '#f2f2f2')
    New-Theme -Name 'Campbell' -Ansi $campbell -Background '#0c0c0c' -Foreground '#cccccc' -Cursor '#ffffff' -Selection '#ffffff' -License 'MIT' -Origin 'builtin'
    New-Theme -Name 'Campbell Powershell' -Ansi $campbell -Background '#012456' -Foreground '#cccccc' -Cursor '#ffffff' -Selection '#ffffff' -License 'MIT' -Origin 'builtin'
}

# Property value or $null (StrictMode-safe).
function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

# Windows Terminal scheme object (as in iTerm2-Color-Schemes/windowsterminal/*.json) -> theme.
function ConvertFrom-WtScheme($Obj, [string]$License = '', [string]$Origin = '') {
    $name = Get-Prop $Obj 'name'
    if (-not $name) { throw 'Scheme has no name' }
    $ansi = foreach ($n in $script:AnsiNames) {
        $v = Get-Prop $Obj $n
        if (-not $v) { throw "Scheme '$name' has no '$n'" }
        $v
    }
    New-Theme -Name $name -Ansi $ansi -Background (Get-Prop $Obj 'background') -Foreground (Get-Prop $Obj 'foreground') `
        -Cursor (Get-Prop $Obj 'cursorColor') -Selection (Get-Prop $Obj 'selectionBackground') -License $License -Origin $Origin
}

function ConvertTo-WtScheme($Theme) {
    $o = [ordered]@{ name = $Theme.Name }
    for ($i = 0; $i -lt 16; $i++) { $o[$script:AnsiNames[$i]] = $Theme.Ansi[$i] }
    $o.background = $Theme.Background
    $o.foreground = $Theme.Foreground
    if ($Theme.Cursor) { $o.cursorColor = $Theme.Cursor }
    if ($Theme.Selection) { $o.selectionBackground = $Theme.Selection }
    [pscustomobject]$o
}

# .itermcolors (Apple plist XML) -> theme.
function ConvertFrom-ItermColors([string]$Path, [string]$License = '', [string]$Origin = '') {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore     # files carry <!DOCTYPE plist ...>
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try { $x = New-Object Xml.XmlDocument; $x.Load($reader) } finally { $reader.Dispose() }
    # Not $x.plist: with a DOCTYPE named "plist" PowerShell may return the doctype node.
    $dict = $x.DocumentElement.SelectSingleNode('dict')
    if (-not $dict) { throw "'$Path' is not an .itermcolors plist" }
    $colors = @{}
    $nodes = @($dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
    for ($i = 0; $i -lt $nodes.Count - 1; $i++) {
        if ($nodes[$i].LocalName -ne 'key' -or $nodes[$i + 1].LocalName -ne 'dict') { continue }
        $comp = @{}
        $inner = @($nodes[$i + 1].ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        for ($j = 0; $j -lt $inner.Count - 1; $j += 2) {
            $comp[$inner[$j].InnerText] = $inner[$j + 1].InnerText
        }
        $ch = foreach ($k in 'Red Component', 'Green Component', 'Blue Component') {
            $v = 0.0
            if ($comp.ContainsKey($k)) { $v = [double]::Parse($comp[$k], [Globalization.CultureInfo]::InvariantCulture) }
            # Double literals: with [Math]::Max(0, $v) PowerShell picks the Int32 overload and truncates.
            [int][Math]::Round([Math]::Min([double]1.0, [Math]::Max([double]0.0, [double]$v)) * 255)
        }
        $colors[$nodes[$i].InnerText] = ConvertTo-Hex $ch[0] $ch[1] $ch[2]
    }
    $ansi = foreach ($n in 0..15) {
        $k = "Ansi $n Color"
        if (-not $colors.ContainsKey($k)) { throw "'$Path' has no '$k'" }
        $colors[$k]
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    New-Theme -Name $name -Ansi $ansi -Background $colors['Background Color'] -Foreground $colors['Foreground Color'] `
        -Cursor $colors['Cursor Color'] -Selection $colors['Selection Color'] -License $License -Origin $Origin
}

# licenses.yml of iTerm2-Color-Schemes: "Name:\n  license: X" -> @{ Name = X }
function Read-LicenseFile([string]$Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $cur = $null
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match '^([^#\s].*):\s*$') { $cur = $Matches[1].Trim().Trim("'").Trim('"') }
        elseif ($cur -and $l -match '^\s+license:\s*(.+?)\s*$') { $map[$cur] = $Matches[1].Trim("'").Trim('"') }
    }
    $map
}

function Test-Redistributable([string]$License) { $License -and ($License -notin @('unknown', 'nonfree')) }

<#
  Reads themes from:
    - an iTerm2-Color-Schemes checkout or extracted zip (uses windowsterminal\*.json + licenses.yml)
    - a folder with *.json (Windows Terminal schemes) and/or *.itermcolors files
    - a single .json or .itermcolors file
#>
function Read-ThemeSource([string]$Path, [switch]$RedistributableOnly, [string]$Origin = 'imported') {
    $item = Get-Item -LiteralPath $Path
    $licenses = @{}
    $files = @()
    if ($item.PSIsContainer) {
        $wt = Join-Path $item.FullName 'windowsterminal'
        if (Test-Path -LiteralPath $wt) {
            $licenses = Read-LicenseFile (Join-Path $item.FullName 'licenses.yml')
            $files = @(Get-ChildItem -LiteralPath $wt -Filter '*.json' -File)
        } else {
            $files = @(Get-ChildItem -LiteralPath $item.FullName -File | Where-Object { $_.Extension -in '.json', '.itermcolors' })
        }
    } else {
        $files = @($item)
    }
    foreach ($f in $files) {
        try {
            if ($f.Extension -eq '.itermcolors') {
                $name = $f.BaseName
                $lic = ''; if ($licenses.ContainsKey($name)) { $lic = $licenses[$name] }
                if ($RedistributableOnly -and -not (Test-Redistributable $lic)) { continue }
                ConvertFrom-ItermColors -Path $f.FullName -License $lic -Origin $Origin
            } else {
                $obj = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                foreach ($s in @($obj)) {
                    if ($s.PSObject.Properties['schemes']) { $list = @($s.schemes) } else { $list = @($s) }
                    foreach ($one in $list) {
                        $lic = [string](Get-Prop $one 'license')
                        $nm = [string](Get-Prop $one 'name')
                        if (-not $lic -and $nm -and $licenses.ContainsKey($nm)) { $lic = $licenses[$nm] }
                        if ($RedistributableOnly -and -not (Test-Redistributable $lic)) { continue }
                        ConvertFrom-WtScheme -Obj $one -License $lic -Origin $Origin
                    }
                }
            }
        } catch {
            Write-Warning "Skipped '$($f.Name)': $($_.Exception.Message)"
        }
    }
}

# Theme index file: { "styley": 1, "themes": [ { name, license, colors[16], background, foreground, cursor, selection } ] }
function Write-ThemeIndex([object[]]$Themes, [string]$Path, [string]$Source = '') {
    $items = foreach ($t in ($Themes | Sort-Object Name)) {
        [ordered]@{
            name = $t.Name; license = $t.License; colors = $t.Ansi
            background = $t.Background; foreground = $t.Foreground
            cursor = $t.Cursor; selection = $t.Selection
        }
    }
    $doc = [ordered]@{ styley = 1; source = $Source; generated = (Get-Date).ToString('yyyy-MM-dd'); themes = @($items) }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $doc | ConvertTo-Json -Depth 5 -Compress
    # One theme per line keeps diffs readable without making the file huge.
    $json = $json -replace '\},\{"name"', "},`n{`"name`"" -replace '"themes":\[\{', "`"themes`":[`n{"
    [IO.File]::WriteAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Read-ThemeIndex([string]$Path, [string]$Origin) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $hex = '^#[0-9a-f]{6}$'
    foreach ($t in $doc.themes) {
        $colors = @($t.colors)
        $bgc = Get-Prop $t 'background'; $fgc = Get-Prop $t 'foreground'
        $cur = Get-Prop $t 'cursor'; $selc = Get-Prop $t 'selection'; $lic = [string](Get-Prop $t 'license')
        # Index files are written normalised; anything else (hand-edited) goes through full validation.
        if ($colors.Count -eq 16 -and @($colors -cnotmatch $hex).Count -eq 0 -and $bgc -cmatch $hex -and $fgc -cmatch $hex) {
            New-ThemeRecord $t.name $colors $bgc $fgc $cur $selc $lic $Origin
        } else {
            try {
                New-Theme -Name $t.name -Ansi $colors -Background $bgc -Foreground $fgc -Cursor $cur -Selection $selc -License $lic -Origin $Origin
            } catch { Write-Warning "Skipped theme '$($t.name)' in ${Path}: $($_.Exception.Message)" }
        }
    }
}

$script:ThemeCache = $null
function Get-Themes {
    if ($script:ThemeCache) { return $script:ThemeCache }
    $byName = [ordered]@{}
    $sources = @(
        @(Get-BuiltinThemes),
        @(Read-ThemeIndex (Join-Path $script:Root 'themes\themes.json') 'bundled'),
        @(Read-ThemeIndex (Join-Path $script:DataDir 'themes.json') 'imported')
    )
    $custom = Join-Path $script:DataDir 'custom'
    if (Test-Path -LiteralPath $custom) { $sources += , @(Read-ThemeSource -Path $custom -Origin 'custom') }
    # Later sources win: imported/custom themes override bundled ones with the same name.
    foreach ($list in $sources) { foreach ($t in $list) { if ($t) { $byName[$t.Name.ToLowerInvariant()] = $t } } }
    $script:ThemeCache = @($byName.Values | Sort-Object Name)
    $script:ThemeCache
}

function Select-Themes([string]$Filter, [string]$Mode = 'all') {
    $all = Get-Themes
    $r = $all
    if ($Mode -eq 'dark') { $r = @($r | Where-Object IsDark) }
    elseif ($Mode -eq 'light') { $r = @($r | Where-Object { -not $_.IsDark }) }
    if ($Filter) {
        $f = $Filter.ToLowerInvariant(); $fs = Get-Slug $Filter
        $r = @($r | Where-Object { $_.Name.ToLowerInvariant().Contains($f) -or ($fs -and $_.Slug.Contains($fs)) })
    }
    , @($r)
}

function Find-Theme([string]$Query) {
    if (-not $Query) { throw (New-StyleyError 'No theme name given. See: styley list') }
    $all = Get-Themes
    $q = $Query.ToLowerInvariant(); $qs = Get-Slug $Query
    $hit = @($all | Where-Object { $_.Name.ToLowerInvariant() -eq $q })
    if (-not $hit) { $hit = @($all | Where-Object { $_.Slug -eq $qs }) }
    if (-not $hit) { $hit = @($all | Where-Object { $_.Slug.StartsWith($qs) }) }
    if (-not $hit) { $hit = @($all | Where-Object { $_.Slug.Contains($qs) }) }
    if ($hit.Count -eq 1) { return $hit[0] }
    if ($hit.Count -eq 0) { throw (New-StyleyError "Theme '$Query' not found. Try: styley list $Query") }
    $names = ($hit | Select-Object -First 12 | ForEach-Object { "  $($_.Name)" }) -join "`n"
    $more = ''; if ($hit.Count -gt 12) { $more = "`n  ... and $($hit.Count - 12) more" }
    throw (New-StyleyError "'$Query' matches $($hit.Count) themes:`n$names$more")
}

# --------------------------------------------------------------------------------------------
# Applying: live window, registry, shortcuts
# --------------------------------------------------------------------------------------------

<#
  The classic console has 16 colour slots and no separate background/foreground colour.
  By default slot 0 (black) becomes the theme background and slot 7 (white) the foreground,
  and the default attribute is 0x07 (white on black), so the window looks like the theme.
  -KeepAnsi keeps the ANSI black/white of the theme instead.
#>
function ConvertTo-ConsolePalette($Theme, [switch]$KeepAnsi) {
    $table = New-Object 'uint32[]' 16
    for ($ci = 0; $ci -lt 16; $ci++) {
        $ai = [array]::IndexOf($script:ConsoleFromAnsi, $ci)
        $table[$ci] = ConvertTo-ColorRef $Theme.Ansi[$ai]
    }
    if (-not $KeepAnsi) {
        $table[0] = ConvertTo-ColorRef $Theme.Background
        $table[7] = ConvertTo-ColorRef $Theme.Foreground
    }
    # Ansi/Background/Foreground/Cursor: the theme's own colours, used for Windows Terminal (see Set-TerminalPalette).
    [pscustomobject]@{
        Table = $table; Attr = [uint16]0x07; Popup = [uint16]0xF5
        Ansi = @($Theme.Ansi); Background = $Theme.Background; Foreground = $Theme.Foreground; Cursor = $Theme.Cursor
    }
}

# Windows Terminal (or another ConPTY host). WT_SESSION alone misses windows that conhost handed over
# to Windows Terminal as the default terminal, such as ones started from the Start menu shortcut.
function Test-WtSession {
    if ($env:WT_SESSION) { return $true }
    try { Initialize-Native; return [Styley.Console]::IsPseudoConsole() } catch { return $false }
}

<#
  Windows Terminal ignores the console palette API, but it understands the xterm colour sequences:
  OSC 4 (16 ANSI colours), OSC 10/11/12 (foreground, background, cursor). They recolour the current tab only.
  A palette without theme colours (one read back from the console) resets the tab to its profile's scheme.
#>
function Set-TerminalPalette($Palette) {
    if (-not $script:Color) { return }  # VT processing is off: the sequences would be printed as text
    $E = $script:E; $bel = [char]7
    $rgb = { param($Hex) $c = ConvertFrom-Hex $Hex; 'rgb:{0:x2}/{1:x2}/{2:x2}' -f $c[0], $c[1], $c[2] }
    $sb = New-Object Text.StringBuilder
    if ($Palette.PSObject.Properties['Background'] -and $Palette.Background -and @($Palette.Ansi).Count -eq 16) {
        for ($i = 0; $i -lt 16; $i++) { [void]$sb.Append("$E]4;$i;$(& $rgb $Palette.Ansi[$i])$bel") }
        [void]$sb.Append("$E]10;$(& $rgb $Palette.Foreground)$bel$E]11;$(& $rgb $Palette.Background)$bel")
        if ($Palette.Cursor) { [void]$sb.Append("$E]12;$(& $rgb $Palette.Cursor)$bel") }
    } else {
        [void]$sb.Append("$E]104$bel$E]110$bel$E]111$bel$E]112$bel")
    }
    [Console]::Out.Write($sb.ToString())
    [Console]::Out.Flush()
}

function Set-LivePalette($Palette, [switch]$Remap) {
    if (Test-WtSession) { Set-TerminalPalette $Palette }
    Initialize-Native
    [Styley.Console]::SetPalette($Palette.Table, $Palette.Attr, $Palette.Popup, [bool]$Remap)
}

function Get-LivePalette {
    Initialize-Native
    $p = [Styley.Console]::GetPalette()
    [pscustomobject]@{ Table = [uint32[]]$p[0..15]; Attr = [uint16]$p[16]; Popup = [uint16]$p[17] }
}

# Shells styley knows: key, label and the executables each one covers.
$script:Shells = [ordered]@{
    powershell = @{ Label = 'PowerShell'; Exes = @('powershell.exe', 'pwsh.exe') }
    cmd        = @{ Label = 'CMD'; Exes = @('cmd.exe') }
}

function Get-ShellOfExe([string]$Exe) {
    if (-not $Exe) { return $null }
    $leaf = [IO.Path]::GetFileName($Exe).ToLowerInvariant()
    foreach ($k in $script:Shells.Keys) { if ($script:Shells[$k].Exes -contains $leaf) { return $k } }
    $null
}

function Get-ShellLabel([string]$Shell) {
    if ($Shell -and $script:Shells.Contains($Shell)) { return $script:Shells[$Shell].Label }
    if ($Shell) { return $Shell }
    'PowerShell + CMD'
}

# --only <shell> | --powershell | --cmd  ->  'powershell' | 'cmd' | $null (both shells)
function Get-TargetShell([string[]]$Flags) {
    $v = Get-FlagValue $Flags '--only'
    if (-not $v) {
        if (Test-Flag $Flags '--cmd', '-cmd') { $v = 'cmd' }
        elseif (Test-Flag $Flags '--powershell', '-powershell', '--ps', '--pwsh') { $v = 'powershell' }
    }
    if (-not $v) { return $null }
    switch -Regex ($v.ToLowerInvariant()) {
        '^(powershell|ps|pwsh|posh)$' { return 'powershell' }
        '^(cmd|command|cmd\.exe)$' { return 'cmd' }
        '^(all|both)$' { return $null }
    }
    throw (New-StyleyError "Unknown shell '$v'. Use: --only powershell  or  --only cmd")
}

# Shell that owns this console window: the earliest process attached to it.
function Get-WindowShell {
    try {
        Initialize-Native
        $procs = foreach ($id in [Styley.Console]::GetProcesses()) {
            if ($id -eq $PID) { continue }
            try { Get-Process -Id $id -ErrorAction Stop } catch { }
        }
        $first = $procs | Where-Object { try { $null = $_.StartTime; $true } catch { $false } } |
            Sort-Object StartTime | Select-Object -First 1
        if ($first) { return (Get-ShellOfExe ($first.ProcessName + '.exe')) }
    } catch { }
    $null
}

# Registry key name conhost uses for a program: %SystemRoot% folded, '\' -> '_'.
function ConvertTo-ConsoleKeyName([string]$ExePath) {
    $p = $ExePath
    $root = $env:SystemRoot.TrimEnd('\')
    if ($p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $p = '%SystemRoot%' + $p.Substring($root.Length) }
    $p.Replace('\', '_')
}

# Registry access goes through .NET: key names such as "C:_Program Files_PowerShell_7_pwsh.exe"
# confuse the PowerShell registry provider.
function Get-ConsoleSubKeyNames {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Console')
    if (-not $k) { return }
    try { $k.GetSubKeyNames() } finally { $k.Close() }
}

function Get-ConsoleValues([string]$SubKey) {
    $h = @{}
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($k) { try { foreach ($n in $k.GetValueNames()) { $h[$n] = $k.GetValue($n) } } finally { $k.Close() } }
    $h
}

# Existing HKCU\Console subkeys (names) of one shell, or of all shells.
function Get-ShellConsoleKeys([string]$Shell = $null) {
    foreach ($n in Get-ConsoleSubKeyNames) {
        $sh = Get-ShellOfExe ($n -replace '^.*_', '')
        if ($sh -and (-not $Shell -or $sh -eq $Shell)) { $n }
    }
}

# Keys (relative to HKCU) a shell starts with: the standard ones, created when missing, plus existing ones.
function Get-ShellKeyPaths([string]$Shell) {
    $names = @()
    if ($Shell -eq 'powershell') {
        $names += '%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe', '%SystemRoot%_SysWOW64_WindowsPowerShell_v1.0_powershell.exe'
        $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwsh) { $names += ConvertTo-ConsoleKeyName $pwsh.Source }
    } elseif ($Shell -eq 'cmd') {
        $names += '%SystemRoot%_system32_cmd.exe', '%SystemRoot%_SysWOW64_cmd.exe'
    }
    $names += @(Get-ShellConsoleKeys $Shell)
    $seen = @{}
    foreach ($n in $names) {
        if (-not $seen.ContainsKey($n.ToLowerInvariant())) { $seen[$n.ToLowerInvariant()] = 1; "Console\$n" }
    }
}

function Write-ConsoleColors([string]$SubKey, $Palette) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    try {
        for ($i = 0; $i -lt 16; $i++) { $k.SetValue(('ColorTable{0:D2}' -f $i), [int]$Palette.Table[$i], [Microsoft.Win32.RegistryValueKind]::DWord) }
        $k.SetValue('ScreenColors', [int]$Palette.Attr, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('PopupColors', [int]$Palette.Popup, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally { $k.Close() }
}

<#
  Both shells ($Shell empty): HKCU\Console (shared defaults) + every existing shell key.
  One shell: only that shell's keys, created when missing; the shared defaults stay as they are.
  Returns the keys written.
#>
function Set-RegistryPalette($Palette, [string]$Shell = $null) {
    if ($Shell) { $keys = @(Get-ShellKeyPaths $Shell) }
    else { $keys = @('Console') + @(Get-ShellConsoleKeys | ForEach-Object { "Console\$_" }) }
    foreach ($k in $keys) { Write-ConsoleColors $k $Palette }
    $keys
}

function Get-ShortcutRoots {
    $roots = @(
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch')
    )
    $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

# Shortcuts that start powershell.exe / pwsh.exe / cmd.exe: objects { Path, Shell }.
# WinX menu links are hashed and left alone.
function Get-ConsoleShortcuts([string]$Shell = $null) {
    $ws = New-Object -ComObject WScript.Shell
    try {
        foreach ($root in Get-ShortcutRoots) {
            foreach ($f in Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue) {
                try { $target = $ws.CreateShortcut($f.FullName).TargetPath } catch { continue }
                $sh = Get-ShellOfExe $target
                if ($sh -and (-not $Shell -or $sh -eq $Shell)) { [pscustomobject]@{ Path = $f.FullName; Shell = $sh } }
            }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws) }
}

function Test-Writable([string]$Path) {
    try { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'ReadWrite').Dispose(); $true } catch { $false }
}

<#
  NT_CONSOLE_PROPS block (204 bytes) for a shortcut that has none: window, font and editing
  settings from the registry ($SubKey over HKCU\Console), colours from the palette.
#>
function New-ConsoleBlock($Palette, [string]$SubKey = $null) {
    $v = Get-ConsoleValues 'Console'
    if ($SubKey) { $o = Get-ConsoleValues $SubKey; foreach ($n in $o.Keys) { $v[$n] = $o[$n] } }
    $b = New-Object byte[] 204
    $int = { param([int]$Off, $Val) [BitConverter]::GetBytes([int]$Val).CopyTo($b, $Off) }
    $reg = { param([string]$Name, [int]$Default) if ($v.ContainsKey($Name) -and $v[$Name] -is [int]) { $v[$Name] } else { $Default } }
    & $int 0 204
    [BitConverter]::GetBytes([uint32]2684354562).CopyTo($b, 4)                 # 0xA0000002 NT_CONSOLE_PROPS_SIG
    [BitConverter]::GetBytes([uint16]$Palette.Attr).CopyTo($b, 8)
    [BitConverter]::GetBytes([uint16]$Palette.Popup).CopyTo($b, 10)
    & $int 12 (& $reg 'ScreenBufferSize' 0x23290078)                           # 120 x 9001
    & $int 16 (& $reg 'WindowSize' 0x001E0078)                                 # 120 x 30
    $hasPos = $v.ContainsKey('WindowPosition')
    & $int 20 (& $reg 'WindowPosition' 0)
    & $int 32 (& $reg 'FontSize' 0x00100000)
    & $int 36 (& $reg 'FontFamily' 0x36)
    & $int 40 (& $reg 'FontWeight' 400)
    $face = 'Consolas'; if ($v.ContainsKey('FaceName') -and $v['FaceName']) { $face = [string]$v['FaceName'] }
    if ($face.Length -gt 31) { $face = $face.Substring(0, 31) }
    [Text.Encoding]::Unicode.GetBytes($face).CopyTo($b, 44)
    & $int 108 (& $reg 'CursorSize' 25)
    & $int 112 (& $reg 'FullScreen' 0)
    & $int 116 (& $reg 'QuickEdit' 1)
    & $int 120 (& $reg 'InsertMode' 1)
    & $int 124 ([int](-not $hasPos))
    & $int 128 (& $reg 'HistoryBufferSize' 50)
    & $int 132 (& $reg 'NumberOfHistoryBuffers' 4)
    & $int 136 (& $reg 'HistoryNoDup' 0)
    for ($i = 0; $i -lt 16; $i++) { [BitConverter]::GetBytes([uint32]$Palette.Table[$i]).CopyTo($b, 140 + 4 * $i) }
    , $b
}

<#
  Writes the palette into shortcuts ($Links: objects { Path, Shell }).
  -CreateBlock (theme for one shell): a shortcut without its own colours takes them from HKCU\Console,
  not from the shell's key, so it gets a console block of its own.
#>
function Set-ShortcutPalette($Palette, $Links, [switch]$CreateBlock) {
    Initialize-Native
    foreach ($l in $Links) {
        $p = $l.Path; $r = $null
        if (-not (Test-Writable $p)) { $r = 'no-access' }   # e.g. ProgramData shortcuts without admin rights
        if (-not $r) {
            try {
                $r = [Styley.Shortcut]::SetPalette($p, $Palette.Table, $Palette.Attr, $Palette.Popup)
                if ($r -eq 'no-console-block' -and $CreateBlock) {
                    $sub = @(Get-ShellKeyPaths $l.Shell)[0]
                    $r = [Styley.Shortcut]::SetConsoleBlock($p, (New-ConsoleBlock $Palette $sub))
                }
            } catch { $r = 'error: ' + $_.Exception.GetBaseException().Message }
        }
        [pscustomobject]@{ Path = $p; Shell = $l.Shell; Result = $r }
    }
}

# --------------------------------------------------------------------------------------------
# Backup / restore / state
# --------------------------------------------------------------------------------------------

function Get-BackupDir { Join-Path $script:DataDir 'backup\original' }

# reg.exe reports success on stderr; run it through cmd so PowerShell 5.1 does not turn that into an error.
function Invoke-Reg([string]$Arguments) {
    $out = & cmd.exe /d /c "reg.exe $Arguments 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "reg.exe $Arguments failed: $out" }
}

# Taken once, before styley changes anything for the first time.
function Save-OriginalBackup($Shortcuts) {
    $dir = Get-BackupDir
    if (Test-Path -LiteralPath (Join-Path $dir 'manifest.json')) { return $false }
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lnk') | Out-Null
    $reg = Join-Path $dir 'console.reg'
    Invoke-Reg "export ""HKCU\Console"" ""$reg"" /y"
    $i = 0
    # Only shortcuts styley can change; the rest (e.g. ProgramData without admin) are never touched.
    $links = foreach ($s in ($Shortcuts | Where-Object { Test-Writable $_.Path })) {
        $i++
        $copy = Join-Path $dir ('lnk\{0:D3}.lnk' -f $i)
        Copy-Item -LiteralPath $s.Path -Destination $copy -Force
        [ordered]@{ original = $s.Path; shell = $s.Shell; copy = (Split-Path -Leaf $copy) }
    }
    $manifest = [ordered]@{ created = (Get-Date).ToString('s'); registry = 'console.reg'; shortcuts = @($links) }
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $true
}

function Get-State {
    $p = Join-Path $script:DataDir 'state.json'
    if (Test-Path -LiteralPath $p) { try { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } catch { } }
    $null
}

# state.json: { "shells": { "powershell": { theme, keepAnsi, applied }, "cmd": { ... } } }
# Returns @{ <shell> = entry } for shells that have a theme set by styley.
function Get-ShellThemes {
    $r = @{}
    $s = Get-State
    if (-not $s) { return $r }
    $shells = Get-Prop $s 'shells'
    if ($shells) {
        foreach ($k in $script:Shells.Keys) { $e = Get-Prop $shells $k; if ($e -and (Get-Prop $e 'theme')) { $r[$k] = $e } }
    } elseif (Get-Prop $s 'theme') {
        foreach ($k in $script:Shells.Keys) { $r[$k] = $s }   # 0.1.0 format: one theme for both shells
    }
    $r
}

function Save-ShellThemes([hashtable]$Map) {
    $p = Join-Path $script:DataDir 'state.json'
    if (-not $Map.Count) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return }
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    $o = [ordered]@{}
    foreach ($k in $script:Shells.Keys) {
        if (-not $Map.ContainsKey($k)) { continue }
        $e = $Map[$k]
        $o[$k] = [ordered]@{ theme = [string](Get-Prop $e 'theme'); keepAnsi = [bool](Get-Prop $e 'keepAnsi'); applied = [string](Get-Prop $e 'applied') }
    }
    [IO.File]::WriteAllText($p, ([ordered]@{ shells = $o } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Save-State([string]$Theme, [bool]$KeepAnsi, [string]$Shell = $null) {
    $map = Get-ShellThemes
    $entry = [pscustomobject]@{ theme = $Theme; keepAnsi = $KeepAnsi; applied = (Get-Date).ToString('s') }
    foreach ($k in $script:Shells.Keys) { if (-not $Shell -or $k -eq $Shell) { $map[$k] = $entry } }
    Save-ShellThemes $map
}

# --------------------------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------------------------

function Format-ThemeLine($Theme, [int]$NameWidth = 34, [string]$Mark = ' ') {
    $name = $Theme.Name
    if ($name.Length -gt $NameWidth) { $name = $name.Substring(0, $NameWidth - 3) + '...' }
    $kind = 'light'; if ($Theme.IsDark) { $kind = 'dark ' }
    if ($script:Color) {
        "$Mark $($name.PadRight($NameWidth)) $(Format-Swatch $Theme 2) $(Format-Sample $Theme) $(Dim $kind)"
    } else {
        "$Mark $($name.PadRight($NameWidth))  $kind  $($Theme.Background)  $($Theme.Slug)"
    }
}

# A mock terminal session drawn in the theme's colours (24-bit, independent of the live palette).
function Format-Mock($Theme, [int]$Width = 64) {
    $a = $Theme.Ansi; $bgc = $Theme.Background; $fgc = $Theme.Foreground
    # Each line: colour, text, colour, text, ...
    $lines = @(
        , @($a[2], 'PS C:\work> ', $a[11], 'git', $fgc, ' status')
        , @($fgc, 'On branch ', $a[6], 'main')
        , @($fgc, 'Changes not staged for commit:')
        , @($a[1], '        modified:   src/styley.ps1')
        , @($a[2], '        new file:   themes/themes.json')
        , @($a[2], 'PS C:\work> ', $a[11], 'Get-ChildItem')
        , @($fgc, 'Mode    LastWriteTime   Name')
        , @($fgc, 'd----   02.11.2026      ', $a[12], 'src')
        , @($fgc, '-a---   02.11.2026      ', $a[10], 'styley.cmd')
        , @($a[2], 'PS C:\work> ', $a[11], 'Get-Item', $a[8], ' -Path', $a[14], ' missing')
        , @($a[9], "Get-Item : Cannot find path 'missing'.")
        , @($a[3], 'WARNING: ', $a[4], 'blue ', $a[5], 'purple ', $a[13], 'pink ', $a[6], 'cyan ', $a[15], 'white')
    )
    foreach ($segs in $lines) {
        $plain = 0; $s = "$(Bg $bgc) "
        for ($i = 0; $i -lt $segs.Count; $i += 2) { $s += "$(Fg $segs[$i])$($segs[$i + 1])"; $plain += $segs[$i + 1].Length }
        $pad = [Math]::Max(0, $Width - 1 - $plain)
        "$s$(' ' * $pad)$(Rst)"
    }
}

function Format-PaletteTable($Theme) {
    $short = @('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white')
    $head = '         '
    for ($i = 0; $i -lt 8; $i++) { $head += $short[$i].PadRight(10) }
    Dim $head
    foreach ($row in 0, 1) {
        $label = 'normal'; if ($row -eq 1) { $label = 'bright' }
        $blocks = "  $($label.PadRight(7))"; $hexes = '         '
        for ($i = 0; $i -lt 8; $i++) {
            $hex = $Theme.Ansi[$row * 8 + $i]
            $blocks += "$(Bg $hex)$(' ' * 9)$(Rst) "
            $hexes += $hex.PadRight(10)
        }
        if ($script:Color) { $blocks; $hexes } else { "  $($label.PadRight(7))$($hexes.Substring(9))" }
    }
    ''
    $bgFg = "  background $($Theme.Background)   foreground $($Theme.Foreground)"
    if ($Theme.Cursor) { $bgFg += "   cursor $($Theme.Cursor)" }
    if ($Theme.Selection) { $bgFg += "   selection $($Theme.Selection)" }
    $bgFg
}

function Show-Preview($Theme) {
    $kind = 'light'; if ($Theme.IsDark) { $kind = 'dark' }
    $lic = $Theme.License; if (-not $lic) { $lic = 'n/a' }
    Out ''
    Out "  $(Bold $Theme.Name)   $(Dim "$kind | slug: $($Theme.Slug) | license: $lic | $($Theme.Origin)")"
    Out ''
    if ($script:Color) { Format-Mock $Theme | ForEach-Object { Out "  $_" }; Out '' }
    Format-PaletteTable $Theme | ForEach-Object { Out $_ }
    Out ''
    Out (Dim "  Apply with:  styley set $($Theme.Slug)")
}

# --------------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------------

function New-StyleyError([string]$Message) {
    $ex = New-Object System.Exception $Message
    $ex.Data['styley'] = $true
    $ex
}

function Test-Flag([string[]]$Flags, [string[]]$Names) {
    foreach ($f in $Flags) { foreach ($n in $Names) { if ($f -ieq $n) { return $true } } }
    $false
}

function Get-FlagValue([string[]]$Flags, [string]$Name) {
    for ($i = 0; $i -lt $Flags.Count; $i++) {
        if ($Flags[$i] -ieq $Name -and $i + 1 -lt $Flags.Count) { return $Flags[$i + 1] }
        if ($Flags[$i] -like "$Name=*") { return $Flags[$i].Substring($Name.Length + 1) }
    }
    $null
}

function Get-ModeFromFlags([string[]]$Flags) {
    if (Test-Flag $Flags '--dark', '-dark') { return 'dark' }
    if (Test-Flag $Flags '--light', '-light') { return 'light' }
    'all'
}

function Test-WindowsTerminal {
    if (Test-WtSession) {
        Out "$(Fg '#e5c07b')note:$(Rst) Windows Terminal detected. Only this tab is recoloured; new tabs use the colour scheme"
        Out '      of the Windows Terminal profile. To make it permanent:  styley export <theme> --format wt'
        return $true
    }
    $false
}

function Invoke-Set([string]$Query, [string[]]$Flags, $Theme = $null) {
    if (-not $Theme) { $Theme = Find-Theme $Query }
    $keepAnsi = Test-Flag $Flags '--keep-ansi', '-keep-ansi'
    $sessionOnly = Test-Flag $Flags '--session', '-session', '-s'
    $noLinks = Test-Flag $Flags '--no-shortcuts', '-no-shortcuts'
    $shell = Get-TargetShell $Flags
    $pal = ConvertTo-ConsolePalette $Theme -KeepAnsi:$keepAnsi
    $ok = "$(Fg '#98c379')ok$(Rst)"

    [void](Test-WindowsTerminal)
    # This window changes with --session, for both shells, or when it belongs to the target shell.
    $windowShell = Get-WindowShell
    $applyLive = $sessionOnly -or (-not $shell) -or (-not $windowShell) -or ($windowShell -eq $shell)
    $live = $false
    if ($applyLive) {
        try { Set-LivePalette $pal -Remap; $live = $true } catch { Write-Warning "Current window not changed: $($_.Exception.Message)" }
    }

    if ($sessionOnly) {
        Out "$ok  '$($Theme.Name)' applied to this window only (--session)."
        return
    }

    # The backup covers every shell shortcut, so a later restore works for either shell.
    $allLinks = @(); if (-not $noLinks) { $allLinks = @(Get-ConsoleShortcuts) }
    if (Save-OriginalBackup -Shortcuts $allLinks) {
        Out (Dim "      Original console settings saved to $(Get-BackupDir)  (undo: styley restore)")
    }
    $links = @($allLinks | Where-Object { -not $shell -or $_.Shell -eq $shell })
    $keys = @(Set-RegistryPalette $pal $shell)
    $results = @(); if ($links) { $results = @(Set-ShortcutPalette $pal $links -CreateBlock:([bool]$shell)) }
    Save-State $Theme.Name $keepAnsi $shell

    Out "$ok  $(Bold $Theme.Name)  $(Dim "-> $(Get-ShellLabel $shell)")"
    if ($live) { Out '      window     : applied' }
    elseif (-not $applyLive) { Out "      window     : unchanged (this is a $(Get-ShellLabel $windowShell) window; open a new $(Get-ShellLabel $shell) window)" }
    if ($shell) { Out "      registry   : $($keys.Count) $(Get-ShellLabel $shell) key(s)" }
    else { Out "      registry   : HKCU\Console + $($keys.Count - 1) shell key(s)" }
    $upd = @($results | Where-Object Result -eq 'updated')
    $new = @($results | Where-Object Result -eq 'created')
    $own = @($results | Where-Object Result -eq 'no-console-block')
    $deny = @($results | Where-Object Result -eq 'no-access')
    $bad = @($results | Where-Object { $_.Result -notin 'updated', 'created', 'no-console-block', 'no-access' })
    if ($noLinks) { Out '      shortcuts  : skipped (--no-shortcuts)' }
    else {
        $line = "      shortcuts  : $($upd.Count) updated"
        if ($new) { $line += ", $($new.Count) given own colours" }
        if ($own) { $line += ", $($own.Count) use registry" }
        if ($deny) { $line += ", $($deny.Count) need admin (skipped)" }
        if ($bad) { $line += ", $($bad.Count) failed" }
        Out $line
        foreach ($b in $bad) { Out (Dim "        $($b.Path): $($b.Result)") }
    }
    if ($shell) { Out (Dim "      Only $(Get-ShellLabel $shell) changed. Undo: styley restore --only $shell") }
    else { Out (Dim '      New windows open with the theme. Undo everything: styley restore') }
}

function Invoke-List([string]$Filter, [string[]]$Flags) {
    $mode = Get-ModeFromFlags $Flags
    $themes = Select-Themes $Filter $mode
    $map = Get-ShellThemes
    $ps = ''; $cm = ''
    if ($map.ContainsKey('powershell')) { $ps = [string]$map['powershell'].theme }
    if ($map.ContainsKey('cmd')) { $cm = [string]$map['cmd'].theme }
    foreach ($t in $themes) {
        $mark = ' '
        if ($t.Name -eq $ps -and $t.Name -eq $cm) { $mark = '*' }
        elseif ($t.Name -eq $ps) { $mark = 'P' }
        elseif ($t.Name -eq $cm) { $mark = 'C' }
        Out (Format-ThemeLine $t -Mark $mark)
    }
    $all = (Get-Themes).Count
    if ($ps -or $cm) { Out (Dim "* PowerShell + CMD   P PowerShell   C CMD") }
    Out (Dim "$($themes.Count) of $all themes. Preview: styley show <name>   Apply: styley set <name>   Browse: styley pick")
}

function Invoke-Current {
    $map = Get-ShellThemes
    foreach ($k in $script:Shells.Keys) {
        $label = (Get-ShellLabel $k).PadRight(11)
        if ($map.ContainsKey($k)) { Out "${label}: $(Bold $map[$k].theme)  $(Dim "(set $($map[$k].applied))")" }
        else { Out "${label}: $(Dim 'not set by styley')" }
    }
    try {
        $live = Get-LivePalette
        $ansi = foreach ($ai in 0..15) { ConvertFrom-ColorRef $live.Table[$script:ConsoleFromAnsi[$ai]] }
        $fake = [pscustomobject]@{ Ansi = $ansi }
        $ws = Get-WindowShell
        $label = 'This window'; if ($ws) { $label += " ($(Get-ShellLabel $ws))" }
        if ($script:Color) { Out "${label}: $(Format-Swatch $fake 2)  $(Dim ('attr 0x{0:X2}' -f $live.Attr))" }
        else { Out ("{0}: {1}  attr 0x{2:X2}" -f $label, ($ansi -join ' '), $live.Attr) }
    } catch { }
}

function Invoke-Export([string]$Query, [string[]]$Flags) {
    $t = Find-Theme $Query
    $format = Get-FlagValue $Flags '--format'; if (-not $format) { $format = 'wt' }
    switch ($format.ToLowerInvariant()) {
        'wt' { Out ((ConvertTo-WtScheme $t) | ConvertTo-Json) }
        'reg' {
            $pal = ConvertTo-ConsolePalette $t -KeepAnsi:(Test-Flag $Flags '--keep-ansi')
            Out 'Windows Registry Editor Version 5.00'
            Out ''
            Out "; styley theme: $($t.Name)"
            Out '[HKEY_CURRENT_USER\Console]'
            for ($i = 0; $i -lt 16; $i++) { Out ('"ColorTable{0:D2}"=dword:{1:x8}' -f $i, $pal.Table[$i]) }
            Out ('"ScreenColors"=dword:{0:x8}' -f $pal.Attr)
            Out ('"PopupColors"=dword:{0:x8}' -f $pal.Popup)
        }
        default { throw (New-StyleyError "Unknown format '$format'. Use: wt, reg") }
    }
}

function Invoke-Import([string]$Path, [switch]$Replace) {
    if (-not $Path) { throw (New-StyleyError 'Usage: styley import <folder|file>') }
    if (-not (Test-Path -LiteralPath $Path)) { throw (New-StyleyError "Path not found: $Path") }
    $new = @(Read-ThemeSource -Path $Path -Origin 'imported')
    if (-not $new) { throw (New-StyleyError "No themes found in '$Path'") }
    $index = Join-Path $script:DataDir 'themes.json'
    $byName = [ordered]@{}
    if (-not $Replace) { foreach ($t in Read-ThemeIndex $index 'imported') { $byName[$t.Name.ToLowerInvariant()] = $t } }
    foreach ($t in $new) { $byName[$t.Name.ToLowerInvariant()] = $t }
    Write-ThemeIndex -Themes @($byName.Values) -Path $index -Source $Path
    $script:ThemeCache = $null
    Out "Imported $($new.Count) theme(s) from $Path. Now available: $((Get-Themes).Count). Stored in $index"
}

function Invoke-Update([string[]]$Flags) {
    $url = Get-FlagValue $Flags '--url'
    if (-not $url) { $url = 'https://codeload.github.com/mbadolato/iTerm2-Color-Schemes/zip/refs/heads/master' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('styley-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'schemes.zip'
        Out "Downloading $url ..."
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }
        Out ('Downloaded {0:N1} MB, extracting schemes ...' -f ((Get-Item $zip).Length / 1MB))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $out = Join-Path $tmp 'src'
        New-Item -ItemType Directory -Force -Path (Join-Path $out 'windowsterminal') | Out-Null
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($e in $archive.Entries) {
                $p = $e.FullName -replace '^[^/]+/', ''
                if ($p -match '^windowsterminal/[^/]+\.json$') {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $out ('windowsterminal\' + $e.Name)), $true)
                } elseif ($p -eq 'licenses.yml') {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $out 'licenses.yml'), $true)
                }
            }
        } finally { $archive.Dispose() }
        Invoke-Import -Path $out -Replace
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# reg export file -> @{ '<subkey lowercase>' = @{ Name = 'Console\...'; Values = @{ ColorTable00 = ...; ... } } }
function Read-RegColors([string]$Path) {
    $r = @{}; $cur = $null
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -match '^\[HKEY_CURRENT_USER\\(.+)\]$') {
            $cur = $Matches[1]; $r[$cur.ToLowerInvariant()] = @{ Name = $cur; Values = @{} }; continue
        }
        if ($cur -and $l -match '^"(ColorTable\d\d|ScreenColors|PopupColors)"=dword:([0-9a-fA-F]{8})$') {
            $r[$cur.ToLowerInvariant()].Values[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
        }
    }
    $r
}

function Get-PaletteFromValues([hashtable]$Values, [hashtable]$Fallback) {
    $t = New-Object 'uint32[]' 16
    $pick = { param($n, $d) if ($Values.ContainsKey($n)) { [int]$Values[$n] } elseif ($Fallback.ContainsKey($n) -and $Fallback[$n] -is [int]) { [int]$Fallback[$n] } else { $d } }
    for ($i = 0; $i -lt 16; $i++) { $t[$i] = [uint32](& $pick ('ColorTable{0:D2}' -f $i) 0) }
    [pscustomobject]@{ Table = $t; Attr = [uint16](& $pick 'ScreenColors' 7); Popup = [uint16](& $pick 'PopupColors' 0xF5) }
}

<#
  Restores one shell. Its registry keys and shortcuts get their original values back. When the shared
  defaults (HKCU\Console) are no longer the original ones, because a theme was set for both shells, the original
  defaults are written into the shell's own keys, and shortcuts without their own colours get a console
  block, so the shell looks as it did before and the other shell keeps its theme.
#>
function Restore-Shell([string]$Shell, [string]$Dir, $Manifest) {
    Initialize-Native
    $orig = Read-RegColors (Join-Path $Dir $Manifest.registry)
    $origDef = @{}; if ($orig.ContainsKey('console')) { $origDef = $orig['console'].Values }
    $curDef = Get-ConsoleValues 'Console'
    $same = $true
    foreach ($n in $script:ConsoleColorValues) {
        $a = $null; if ($origDef.ContainsKey($n)) { $a = [int]$origDef[$n] }
        $b = $null; if ($curDef.ContainsKey($n) -and $curDef[$n] -is [int]) { $b = [int]$curDef[$n] }
        if ($a -ne $b) { $same = $false; break }
    }

    $subs = @(Get-ShellKeyPaths $Shell)
    foreach ($k in $orig.Keys) {
        if (-not $k.StartsWith('console\')) { continue }
        $nm = $orig[$k].Name
        if ((Get-ShellOfExe ($nm -replace '^.*_', '')) -eq $Shell) { $subs += $nm }
    }
    $keysDone = 0
    foreach ($sub in ($subs | Sort-Object -Unique)) {
        $want = @{}
        if (-not $same) { foreach ($n in $origDef.Keys) { $want[$n] = $origDef[$n] } }
        $wasThere = $orig.ContainsKey($sub.ToLowerInvariant())
        if ($wasThere) { $o = $orig[$sub.ToLowerInvariant()].Values; foreach ($n in $o.Keys) { $want[$n] = $o[$n] } }
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
        if (-not $key -and -not $want.Count) { continue }
        if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub) }
        $empty = $false
        try {
            foreach ($n in $script:ConsoleColorValues) { $key.DeleteValue($n, $false) }
            foreach ($n in $want.Keys) { $key.SetValue($n, [int]$want[$n], [Microsoft.Win32.RegistryValueKind]::DWord) }
            $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
        } finally { $key.Close() }
        # Keys styley created for this shell and that are empty again are removed.
        if ($empty -and -not $wasThere) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($sub, $false) }
        $keysDone++
    }

    $n = 0
    $ws = New-Object -ComObject WScript.Shell
    try {
        foreach ($s in @($Manifest.shortcuts)) {
            if (-not $s) { continue }
            $copy = Join-Path $Dir "lnk\$($s.copy)"
            if (-not (Test-Path -LiteralPath $copy)) { continue }
            $sh = [string](Get-Prop $s 'shell')
            if (-not $sh) { try { $sh = Get-ShellOfExe $ws.CreateShortcut($copy).TargetPath } catch { } }
            if ($sh -ne $Shell) { continue }
            try {
                $changed = (-not (Test-Path -LiteralPath $s.original)) -or
                    ((Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $s.original).Hash)
                if ($changed) { Copy-Item -LiteralPath $copy -Destination $s.original -Force }
                if (-not $same -and -not [Styley.Shortcut]::GetPalette($s.original)) {
                    $pal = Get-PaletteFromValues $origDef $curDef
                    [void][Styley.Shortcut]::SetConsoleBlock($s.original, (New-ConsoleBlock $pal $null))
                    $changed = $true
                }
                if ($changed) { $n++ }
            } catch { Write-Warning "Shortcut not restored: $($s.original): $($_.Exception.Message)" }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws) }

    $map = Get-ShellThemes
    [void]$map.Remove($Shell)
    Save-ShellThemes $map
    Out "Restored $(Get-ShellLabel $Shell) from the backup of $($Manifest.created): $keysDone key(s), $n shortcut(s)."
    Out (Dim "Open a new $(Get-ShellLabel $Shell) window to see the original colours.")
}

function Invoke-Restore([string[]]$Flags = @()) {
    $dir = Get-BackupDir
    $mf = Join-Path $dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { throw (New-StyleyError 'No backup found: styley has not changed anything yet.') }
    $m = [IO.File]::ReadAllText($mf) | ConvertFrom-Json
    $shell = Get-TargetShell $Flags
    if ($shell) { Restore-Shell $shell $dir $m; return }

    # `reg import` only adds values. Values styley added (e.g. ColorTable in per-shell keys that had none)
    # must be removed first, otherwise they keep overriding the restored defaults.
    $orig = Read-RegColors (Join-Path $dir $m.registry)
    $subs = @('Console') + @(Get-ConsoleSubKeyNames | ForEach-Object { "Console\$_" })
    foreach ($sub in $subs) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
        if (-not $key) { continue }
        $empty = $false
        try {
            foreach ($v in $script:ConsoleColorValues) { $key.DeleteValue($v, $false) }
            $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
        } finally { $key.Close() }
        # Shell keys styley created (not in the backup) and now empty are removed.
        if ($empty -and $sub -ne 'Console' -and -not $orig.ContainsKey($sub.ToLowerInvariant())) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($sub, $false)
        }
    }
    $regFile = Join-Path $dir $m.registry
    Invoke-Reg "import ""$regFile"""
    $n = 0
    foreach ($s in @($m.shortcuts)) {
        if (-not $s) { continue }
        $copy = Join-Path $dir "lnk\$($s.copy)"
        if (-not (Test-Path -LiteralPath $copy)) { continue }
        if ((Test-Path -LiteralPath $s.original) -and
            (Get-FileHash -LiteralPath $copy).Hash -eq (Get-FileHash -LiteralPath $s.original).Hash) { continue }
        try { Copy-Item -LiteralPath $copy -Destination $s.original -Force; $n++ }
        catch { Write-Warning "Shortcut not restored: $($s.original): $($_.Exception.Message)" }
    }
    Save-ShellThemes @{}
    Out "Restored console settings from $($m.created): registry + $n shortcut(s)."
    Out (Dim 'Open a new window to see the original colours.')
}

function Invoke-Random([string]$Filter, [string[]]$Flags) {
    $themes = Select-Themes $Filter (Get-ModeFromFlags $Flags)
    if (-not $themes) { throw (New-StyleyError 'No themes match.') }
    $t = $themes | Get-Random
    Invoke-Set -Query $t.Name -Flags $Flags -Theme $t
}

# Interactive browser: the palette of the window changes as you move, like the theme list in iTerm2.
function Invoke-Pick([string]$Filter, [string[]]$Flags, [scriptblock]$ReadKey = $null) {
    # $ReadKey allows feeding keys from a script; interactive use reads the keyboard.
    if (-not $ReadKey) {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { throw (New-StyleyError 'pick needs an interactive console.') }
        if (-not $script:Color) { throw (New-StyleyError 'pick needs a console with VT support (Windows 10 1703+).') }
        $ReadKey = { [Console]::ReadKey($true) }
    }
    $keepAnsi = Test-Flag $Flags '--keep-ansi'
    $mode = Get-ModeFromFlags $Flags
    $modes = @('all', 'dark', 'light')
    $original = Get-LivePalette
    $shell = Get-TargetShell $Flags
    $windowShell = Get-WindowShell
    $map = Get-ShellThemes
    $startName = $null
    foreach ($k in @($shell, $windowShell) + @($script:Shells.Keys)) {
        if ($k -and $map.ContainsKey($k)) { $startName = [string]$map[$k].theme; break }
    }
    $filter = [string]$Filter
    $themes = Select-Themes $filter $mode
    $sel = 0
    if ($startName) {
        for ($i = 0; $i -lt $themes.Count; $i++) { if ($themes[$i].Name -eq $startName) { $sel = $i; break } }
    }
    $top = 0; $applied = $null; $result = $null
    $E = $script:E
    [Console]::Out.Write("$E[?1049h$E[?25l")
    try {
        while ($true) {
            try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { $w = 120; $h = 30 }
            $listW = [Math]::Min(42, $w - 2)
            $rows = [Math]::Max(3, $h - 5)
            if ($themes.Count) { $sel = [Math]::Max(0, [Math]::Min($sel, $themes.Count - 1)) } else { $sel = 0 }
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $rows) { $top = $sel - $rows + 1 }
            $cur = $null; if ($themes.Count) { $cur = $themes[$sel] }
            if ($cur -and $applied -ne $cur.Name) {
                Set-LivePalette (ConvertTo-ConsolePalette $cur -KeepAnsi:$keepAnsi)
                $applied = $cur.Name
            }

            # Right side: drawn with the 16 palette colours, so it shows the live theme.
            $prev = @()
            if ($cur -and $w -ge $listW + 30) {
                $kind = 'light'; if ($cur.IsDark) { $kind = 'dark' }
                $strip0 = ''; $strip1 = ''
                for ($i = 0; $i -lt 8; $i++) { $strip0 += "$E[4$($i)m    "; $strip1 += "$E[10$($i)m    " }
                $prev = @(
                    "$E[1m$($cur.Name)$E[0m  $E[2m$kind, $($cur.License)$E[0m",
                    '',
                    "$strip0$E[0m",
                    "$strip1$E[0m",
                    '',
                    "$E[32mPS C:\work> $E[93mgit$E[0m status",
                    "On branch $E[36mmain$E[0m",
                    "$E[31m        modified:   src/styley.ps1$E[0m",
                    "$E[32m        new file:   themes/themes.json$E[0m",
                    "$E[32mPS C:\work> $E[93mGet-Item$E[90m -Path$E[96m missing$E[0m",
                    "$E[91mGet-Item : Cannot find path 'missing'.$E[0m",
                    "$E[33mWARNING:$E[0m $E[34mblue $E[35mpurple $E[95mpink $E[94mlight-blue$E[0m",
                    '',
                    "$E[2mslug: $($cur.Slug)$E[0m"
                )
            }

            $sb = New-Object Text.StringBuilder
            [void]$sb.Append("$E[H")
            $modeTxt = ($modes | ForEach-Object { if ($_ -eq $mode) { "[$_]" } else { " $_ " } }) -join ''
            [void]$sb.Append("$E[1m styley pick$E[0m -> $(Get-ShellLabel $shell)  $($themes.Count) themes  $E[2mTab:$E[0m$modeTxt$E[K`n")
            [void]$sb.Append(" filter: $E[4m$filter$E[0m_$E[K`n$E[K`n")
            for ($r = 0; $r -lt $rows; $r++) {
                $idx = $top + $r
                $left = ''
                if ($idx -lt $themes.Count) {
                    $n = $themes[$idx].Name
                    if ($n.Length -gt $listW - 3) { $n = $n.Substring(0, $listW - 6) + '...' }
                    if ($idx -eq $sel) { $left = "$E[7m > $($n.PadRight($listW - 3))$E[0m" }
                    else { $left = "   $($n.PadRight($listW - 3))" }
                } else { $left = ' ' * $listW }
                $right = ''; if ($r -lt $prev.Count) { $right = $prev[$r] }
                [void]$sb.Append("$left  $right$E[0m$E[K`n")
            }
            [void]$sb.Append("$E[K`n$E[2m Up/Down PgUp/PgDn Home/End: move   type: filter   Tab: all/dark/light   Enter: apply   Esc: cancel$E[0m$E[K")
            [Console]::Out.Write($sb.ToString())

            $k = & $ReadKey
            switch ($k.Key) {
                'UpArrow' { $sel-- }
                'DownArrow' { $sel++ }
                'PageUp' { $sel -= $rows }
                'PageDown' { $sel += $rows }
                'Home' { $sel = 0 }
                'End' { $sel = $themes.Count - 1 }
                'Escape' { $result = 'cancel' }
                'Enter' { if ($cur) { $result = 'apply' } }
                'Tab' {
                    $mode = $modes[([array]::IndexOf($modes, $mode) + 1) % 3]
                    $themes = Select-Themes $filter $mode; $sel = 0; $top = 0
                }
                'Backspace' {
                    if ($filter.Length) { $filter = $filter.Substring(0, $filter.Length - 1); $themes = Select-Themes $filter $mode; $sel = 0; $top = 0 }
                }
                default {
                    if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) {
                        $filter += $k.KeyChar; $themes = Select-Themes $filter $mode; $sel = 0; $top = 0
                    }
                }
            }
            if ($result) { break }
        }
    } finally {
        [Console]::Out.Write("$E[0m$E[?25h$E[?1049l")
        if ($result -ne 'apply') {
            try { Set-LivePalette $original } catch { }
        }
    }
    if ($result -eq 'apply') {
        Invoke-Set -Query $cur.Name -Flags $Flags -Theme $cur
        # Theme for the other shell: this window goes back to its own colours.
        if ($shell -and $windowShell -and $windowShell -ne $shell -and -not (Test-Flag $Flags '--session', '-s')) {
            try { Set-LivePalette $original } catch { }
        }
    }
    else { Out 'Cancelled, nothing changed.' }
}

function Show-Help {
    $c = { param($t) "$(Fg '#61afef')$t$(Rst)" }
    $h = { param($t) "$(Bold $t)" }
    Out ''
    Out "  $(& $h 'styley') $script:Version  $(Dim '- iTerm2-style colour themes for Windows PowerShell and CMD')"
    Out ''
    Out "  $(& $h 'USAGE')"
    Out "    styley $(& $c '<command>') [arguments] [options]"
    Out ''
    Out "  $(& $h 'COMMANDS')"
    Out "    $(& $c 'pick') [filter]          Browse themes interactively; the window recolours as you move"
    Out "    $(& $c 'list') [filter]          List themes with their palettes"
    Out "    $(& $c 'show') <theme>           Preview a theme: mock session + 16-colour palette"
    Out "    $(& $c 'set') <theme>            Apply a theme to this window, new windows and shortcuts (both shells or --only one)"
    Out "    $(& $c 'random') [filter]        Apply a random theme"
    Out "    $(& $c 'current')                Show the theme of each shell and this window's palette"
    Out "    $(& $c 'reset')                  Apply the Windows default palette (Campbell)"
    Out "    $(& $c 'restore')                Undo: bring back the console settings saved before the first change"
    Out "                           (restore --only cmd / --only powershell: undo one shell only)"
    Out "    $(& $c 'import') <path>          Add themes: iTerm2-Color-Schemes folder, *.json (Windows Terminal), *.itermcolors"
    Out "    $(& $c 'update')                 Download all themes from github.com/mbadolato/iTerm2-Color-Schemes"
    Out "    $(& $c 'export') <theme>         Print a theme: --format wt (Windows Terminal JSON) | reg"
    Out "    $(& $c 'help') | $(& $c 'version')"
    Out ''
    Out "  $(& $h 'OPTIONS')"
    Out "    --only <shell>         One shell only: powershell or cmd (set, pick, random, reset, restore)"
    Out "    --powershell, --cmd    Same as --only powershell / --only cmd"
    Out "    --dark, --light        Only dark / light themes (list, pick, random)"
    Out "    --session, -s          Change only the current window (set, random)"
    Out "    --no-shortcuts         Do not touch .lnk shortcuts (set, random, pick)"
    Out "    --keep-ansi            Keep the theme's ANSI black/white instead of using its background/foreground"
    Out ''
    Out "  $(& $h 'SHELLS')"
    Out "    Without --only, PowerShell and CMD share one theme. With --only each shell keeps its own;"
    Out "    a later set without --only makes them share one theme again."
    Out ''
    Out "  $(& $h 'THEME NAMES')"
    Out "    Full name in quotes, its slug, or a unique part of the slug:"
    Out "      styley set ""Gruvbox Dark Hard""   =   styley set gruvbox-dark-hard   =   styley set gruvbox-dark-h"
    Out ''
    Out "  $(& $h 'EXAMPLES')"
    Out "    styley pick --dark                 $(Dim '# browse dark themes, Enter to apply')"
    Out "    styley list gruvbox                $(Dim '# all themes with gruvbox in the name')"
    Out "    styley show catppuccin-mocha       $(Dim '# preview before applying')"
    Out "    styley set ""Atom One Dark""         $(Dim '# apply everywhere')"
    Out "    styley set nord -s                 $(Dim '# try in this window only')"
    Out "    styley set nord --only cmd         $(Dim '# CMD gets Nord, PowerShell keeps its theme')"
    Out "    styley pick --powershell           $(Dim '# choose a theme for PowerShell only')"
    Out "    styley random --light              $(Dim '# feeling lucky')"
    Out "    styley export nord --format wt     $(Dim '# for Windows Terminal settings.json')"
    Out "    styley update                      $(Dim '# all 880+ schemes, incl. ones not bundled (e.g. Dracula)')"
    Out "    styley import C:\src\iTerm2-Color-Schemes"
    Out "    styley restore --only cmd          $(Dim '# undo CMD only')"
    Out "    styley restore                     $(Dim '# undo all changes')"
    Out ''

    $examples = @('Catppuccin Mocha', 'Gruvbox Dark', 'TokyoNight', 'Nord', 'Rose Pine Dawn', 'Atom One Dark', 'Campbell')
    $shown = @()
    foreach ($n in $examples) {
        $t = Get-Themes | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if ($t) { $shown += $t }
        if ($shown.Count -ge 4) { break }
    }
    if ($script:Color -and $shown) {
        Out "  $(& $h 'PALETTE EXAMPLES')   $(Dim 'slots 0-7 normal, 8-15 bright: black red green yellow blue purple cyan white')"
        Out ''
        foreach ($t in $shown) { Out (Format-ThemeLine $t -NameWidth 22 -Mark ' ') }
        Out ''
        $first = $shown[0]
        Out "  $(Dim "How '$($first.Name)' looks:")"
        Format-Mock $first 60 | ForEach-Object { Out "  $_" }
        Out ''
    }
    $count = (Get-Themes).Count
    Out (Dim "  $count themes available. Data: $script:DataDir")
    Out ''
}

function Invoke-Styley([string[]]$Arguments) {
    $Arguments = @($Arguments | Where-Object { $_ -ne $null })
    $cmd = 'help'; if ($Arguments.Count) { $cmd = $Arguments[0].ToLowerInvariant() }
    $rest = @(); if ($Arguments.Count -gt 1) { $rest = @($Arguments[1..($Arguments.Count - 1)]) }
    # Options that take a value keep it right after them in $flags (see Get-FlagValue).
    $valueOptions = @('--format', '--url', '--only')
    $flags = @(); $positional = @()
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $a = $rest[$i]
        if ($valueOptions -contains $a.ToLowerInvariant() -and $i + 1 -lt $rest.Count) { $flags += $a, $rest[$i + 1]; $i++ }
        elseif ($a -like '-*') { $flags += $a }
        else { $positional += $a }
    }
    $arg = ($positional -join ' ').Trim()

    Enable-Color
    try {
        $null = switch -Regex ($cmd) {
            '^(help|-h|--help|/\?|-\?)$' { Show-Help; break }
            '^(version|--version|-v)$' { Out "styley $script:Version"; break }
            '^(list|ls)$' { Invoke-List $arg $flags; break }
            '^(show|preview)$' { Show-Preview (Find-Theme $arg); break }
            '^(set|apply|use)$' { Invoke-Set $arg $flags; break }
            '^(pick|browse|select)$' { Invoke-Pick $arg $flags; break }
            '^random$' { Invoke-Random $arg $flags; break }
            '^current$' { Invoke-Current; break }
            '^reset$' { Invoke-Set 'Campbell' $flags; break }
            '^restore$' { Invoke-Restore $flags; break }
            '^import$' { Invoke-Import $arg -Replace:(Test-Flag $flags '--replace'); break }
            '^update$' { Invoke-Update $flags; break }
            '^export$' { Invoke-Export $arg $flags; break }
            default {
                # `styley dracula` is a shortcut for `styley show dracula`.
                Show-Preview (Find-Theme (($Arguments) -join ' '))
            }
        }
        return 0
    } catch {
        $ex = $_.Exception
        if ($ex.Data.Contains('styley')) { [Console]::Error.WriteLine("styley: $($ex.Message)"); return 2 }
        [Console]::Error.WriteLine("styley: $($ex.Message)")
        if ($env:STYLEY_DEBUG) { [Console]::Error.WriteLine($_.ScriptStackTrace) }
        return 1
    } finally {
        Restore-ConsoleMode
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Styley $args)
}
