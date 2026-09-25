<#
.SYNOPSIS
  Copy an addon from this repo into the WoW Forever beta AddOns folder.

.DESCRIPTION
  Syntax-gates the copy first. A Lua parse error means the addon never loads and
  /amb is simply not there in game, which is a slow and confusing way to find out.

  Zones.lua is where the editor's Save to file text is pasted, in the GAME folder.
  A Zones.lua there that differs from the repo's is therefore someone's work, not
  a stale copy: it is left alone, loudly, unless -OverwriteZones is passed. An
  identical one, or none, is copied as usual.

.EXAMPLE
  .\scripts\install-addon.ps1
  .\scripts\install-addon.ps1 -WowRoot "D:\Games\World of Warcraft" -Flavor _beta_
  .\scripts\install-addon.ps1 -OverwriteZones
#>
[CmdletBinding()]
param(
    [string]$WowRoot,
    [string]$Flavor = "_classic_beta_",
    [string]$Addon  = "DynamicAmbiance",
    [switch]$OverwriteZones
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

if (-not $WowRoot) {
    $candidates = @(
        "C:\Program Files (x86)\World of Warcraft",
        "C:\Program Files\World of Warcraft",
        "D:\World of Warcraft",
        "D:\Games\World of Warcraft",
        "E:\World of Warcraft",
        "F:\World of Warcraft",
        "F:\Games\World of Warcraft"
    )
    $WowRoot = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $WowRoot -or -not (Test-Path $WowRoot)) {
    Write-Error "Could not find the WoW install. Pass -WowRoot explicitly."
}

$flavorPath = Join-Path $WowRoot $Flavor
if (-not (Test-Path $flavorPath)) {
    Write-Host "Flavor folder '$Flavor' not found under $WowRoot. Available:" -ForegroundColor Yellow
    Get-ChildItem $WowRoot -Directory | Where-Object { $_.Name -like "_*_" } | ForEach-Object { "  $($_.Name)" }
    Write-Error "Pass the right one with -Flavor"
}

$src = Join-Path $repo "addons\$Addon"
if (-not (Test-Path $src)) { Write-Error "Addon source not found: $src" }

# LuaJIT is preferred: it parses Lua 5.1, which is what this client runs. luac
# 5.4 is a usable second choice - it accepts everything 5.1 does and a little more.
$luajit = Get-Command luajit -ErrorAction SilentlyContinue
$luac   = Get-Command luac   -ErrorAction SilentlyContinue
if ($luajit -or $luac) {
    $checker = if ($luajit) { "luajit (5.1)" } else { "luac (5.4)" }
    foreach ($file in Get-ChildItem $src -Filter *.lua -Recurse) {
        if ($luajit) { & $luajit.Source -bl $file.FullName | Out-Null }
        else         { & $luac.Source -p $file.FullName }
        if ($LASTEXITCODE -ne 0) { Write-Error "Lua syntax error in $($file.Name) - not installing." }
    }
    Write-Host "Lua syntax OK ($checker)" -ForegroundColor Green
} else {
    Write-Host "No lua/luajit on PATH - skipping the syntax check. Install with: winget install DEVCOM.LuaJIT" -ForegroundColor Yellow
}

$dest = Join-Path $flavorPath "Interface\AddOns\$Addon"

# A game-folder Zones.lua that differs from the repo's holds pasted zones.
$zonesSrc  = Join-Path $src  "Zones.lua"
$zonesDest = Join-Path $dest "Zones.lua"
$keepZones = $false
if ((Test-Path $zonesSrc) -and (Test-Path $zonesDest) -and -not $OverwriteZones) {
    $repoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zonesSrc).Hash
    $gameHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zonesDest).Hash
    $keepZones = $repoHash -ne $gameHash
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
if ($keepZones) {
    Get-ChildItem -LiteralPath $src | Where-Object { $_.Name -ne "Zones.lua" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    }
    Write-Host ""
    Write-Host "!!! Zones.lua in the game folder differs from the repo's - NOT overwritten. !!!" -ForegroundColor Red
    Write-Host "    It probably holds zones pasted from the editor's Save to file:" -ForegroundColor Red
    Write-Host "      $zonesDest" -ForegroundColor Red
    Write-Host "    Copy it back into the repo first, so it is not lost:" -ForegroundColor Yellow
    Write-Host "      Copy-Item '$zonesDest' '$zonesSrc'" -ForegroundColor Yellow
    Write-Host "    To replace it with the repo's copy anyway, re-run with -OverwriteZones." -ForegroundColor Yellow
    Write-Host ""
} else {
    Copy-Item -Path (Join-Path $src "*") -Destination $dest -Recurse -Force
}

Write-Host "Installed $Addon -> $dest" -ForegroundColor Green
Get-ChildItem $dest | ForEach-Object { "  $($_.Name)" }
Write-Host ""
Write-Host "In game: /reload, then /amb" -ForegroundColor Cyan
