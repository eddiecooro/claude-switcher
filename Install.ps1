#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeSwitcher'
$commandDirectory = Join-Path $env:USERPROFILE '.local\bin'
$commandPath = Join-Path $commandDirectory 'claude-switcher.cmd'
[IO.Directory]::CreateDirectory($installDirectory) | Out-Null
[IO.Directory]::CreateDirectory($commandDirectory) | Out-Null
foreach ($name in @('ClaudeSwitcher.ps1','ClaudeSwitcher.Core.psm1','DesktopSqlite.cs','README.md')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $installDirectory $name) -Force
}
$entryPoint = Join-Path $installDirectory 'ClaudeSwitcher.ps1'
$launcher = '@echo off' + "`r`n" +
    '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' + $entryPoint + '" %*' + "`r`n" +
    'exit /b %ERRORLEVEL%' + "`r`n"
[IO.File]::WriteAllText($commandPath,$launcher,(New-Object Text.UTF8Encoding($false)))

$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$expandedEntries = @($entries | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
if ($expandedEntries -notcontains $commandDirectory.TrimEnd('\')) {
    $newPath = (@($entries) + @($commandDirectory)) -join ';'
    [Environment]::SetEnvironmentVariable('Path',$newPath,'User')
    Write-Host 'Added the command directory to your user PATH. Open a new terminal to use it.'
}
$currentEntries = @($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') })
if ($currentEntries -notcontains $commandDirectory.TrimEnd('\')) { $env:Path += ';' + $commandDirectory }
Write-Host "Installed: $installDirectory"
Write-Host "Command:   $commandPath"
Write-Host 'Run claude-switcher from any directory. Run this installer again after source updates.'
