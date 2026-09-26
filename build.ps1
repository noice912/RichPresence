<#
  Builds dist\RichPresence.exe from src\RichPresence.ps1 using the ps2exe module.
  Run:  powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host 'Installing the ps2exe module (one time, current user only)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

# the version lives in the script ($AppVersion), so the EXE and the updater always agree
$ver = [regex]::Match((Get-Content (Join-Path $root 'src\RichPresence.ps1') -Raw), '\$AppVersion\s*=\s*''([0-9.]+)''').Groups[1].Value
if (-not $ver) { throw 'AppVersion not found in src\RichPresence.ps1' }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

Invoke-ps2exe `
    -inputFile  (Join-Path $root 'src\RichPresence.ps1') `
    -outputFile (Join-Path $dist 'RichPresence.exe') `
    -iconFile   (Join-Path $root 'assets\icon.ico') `
    -noConsole -STA `
    -title 'RichPresence' -product 'RichPresence' `
    -description 'Genshin Impact launcher with Discord Rich Presence' `
    -version "$ver.0"

Write-Host "Built: $(Join-Path $dist 'RichPresence.exe')"
