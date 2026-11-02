<#
.SYNOPSIS
  Installs styley for the current user (no admin rights needed).

.DESCRIPTION
  Copies bin\, src\ and themes\ to %LOCALAPPDATA%\Programs\styley and adds its bin folder to the
  user PATH, so `styley` works in new PowerShell and CMD windows.

  -Dev puts this repository's bin folder on PATH instead of copying (edits take effect at once).
  -Uninstall (or uninstall.cmd) first restores the console colours saved before styley's first change
  (registry + shortcuts, same as `styley restore`), then removes the PATH entry and the installed copy.
  Both shells are restored, PowerShell and CMD, whether their themes were shared or set separately
  with --only. -KeepColors leaves both themes in place; -KeepColorsFor powershell|cmd keeps the theme
  of that shell and restores the other one. User data in %LOCALAPPDATA%\styley (imported themes,
  backup) is kept unless -Purge is given.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dev
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -Purge
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -KeepColorsFor cmd
#>
param(
    [switch]$Dev,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$KeepColors,
    [ValidateSet('powershell', 'cmd')][string]$KeepColorsFor,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\styley')
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

Add-Type -Namespace StyleyInstall -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@

function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}

function Set-UserPath([string]$Value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        # Keep the existing value kind; new values are REG_EXPAND_SZ so %VARS% keep working.
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }
        $key.SetValue('Path', $Value, $kind)
    }
    finally { $key.Close() }
    # Tell Explorer so windows started from it get the new PATH.
    $r = [UIntPtr]::Zero
    [void][StyleyInstall.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

function Remove-FromPath([string]$Dir) {
    $all = @((Get-UserPath) -split ';' | Where-Object { $_ })
    $parts = @($all | Where-Object { $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
    if ($parts.Count -ne $all.Count) { Set-UserPath ($parts -join ';') }
}

function Add-ToPath([string]$Dir) {
    $parts = @((Get-UserPath) -split ';' | Where-Object { $_ })
    if ($parts | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }) { return $false }
    Set-UserPath ((@($parts) + $Dir) -join ';')
    $true
}

$installedBin = Join-Path $Destination 'bin'
$devBin = Join-Path $repo 'bin'

if ($Uninstall) {
    $dataDir = Join-Path $env:LOCALAPPDATA 'styley'
    $hasBackup = Test-Path -LiteralPath (Join-Path $dataDir 'backup\original\manifest.json')

    # 1. Original console colours back (registry + shortcuts) for both shells, or for the one not kept.
    $kept = @()
    if ($KeepColors) { $kept = @('powershell', 'cmd') } elseif ($KeepColorsFor) { $kept = @($KeepColorsFor) }
    if ($hasBackup -and $kept.Count -lt 2) {
        $tool = Join-Path $Destination 'src\styley.ps1'
        if (-not (Test-Path -LiteralPath $tool)) { $tool = Join-Path $repo 'src\styley.ps1' }
        $restoreArgs = @('restore')
        if ($kept -contains 'powershell') { $restoreArgs += '--only', 'cmd' }
        elseif ($kept -contains 'cmd') { $restoreArgs += '--only', 'powershell' }
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool @restoreArgs
        if ($LASTEXITCODE -ne 0) { throw "styley restore failed ($LASTEXITCODE); nothing was removed. Use -KeepColors to uninstall anyway." }
    }

    # 2. PATH entries and program files.
    Remove-FromPath $installedBin
    Remove-FromPath $devBin
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }

    # 3. User data (imported themes, backup, cache, state).
    if ($Purge -and $hasBackup -and $kept.Count) {
        Write-Warning "Keeping $dataDir : with -KeepColors/-KeepColorsFor, -Purge would delete the only backup of your original colours."
    } elseif ($Purge) {
        Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'styley removed from PATH and disk.'
    if ($hasBackup -and $kept.Count) {
        $names = ($kept | ForEach-Object { if ($_ -eq 'cmd') { 'CMD' } else { 'PowerShell' } }) -join ' and '
        Write-Host "Theme kept for: $names."
    }
    if (Test-Path -LiteralPath $dataDir) { Write-Host "User data kept in $dataDir (delete it or run uninstall with -Purge)." }
    return
}

if ($Dev) {
    Remove-FromPath $installedBin
    $bin = $devBin
} else {
    Remove-FromPath $devBin
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($d in 'bin', 'src', 'themes') {
        $target = Join-Path $Destination $d
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $target -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $Destination -Force
    $bin = $installedBin
}

$added = Add-ToPath $bin
if (($env:Path -split ';') -notcontains $bin) { $env:Path = "$env:Path;$bin" }   # this window too

Write-Host "styley installed: $bin"
if ($added) { Write-Host 'Added to the user PATH. Open a new PowerShell or CMD window, then run:  styley help' }
else { Write-Host 'Already on the user PATH. Run:  styley help' }
Write-Host ''
Write-Host 'Quick start:'
Write-Host '  styley pick                    choose one theme for PowerShell and CMD'
Write-Host '  styley pick --only cmd         choose a theme for CMD only (also: --only powershell)'
Write-Host '  styley current                 theme of each shell'
Write-Host '  styley restore                 original colours (restore --only cmd: one shell)'
