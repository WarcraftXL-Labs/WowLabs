# Builds WowLabs and packages it into a folder you can hand to someone.
#
#   .\tools\package.ps1
#   .\tools\package.ps1 -SkipBuild        # package what is already in dist\
#
# The result is build\WowLabs\WowLabs.exe, which runs with nothing installed:
# no LuaJIT on the machine, no Lua path to set, no working directory to be in.
# That is the thing to test each addition against, because it is the thing
# anybody else will run.
#
# The packaging itself is Neutrino's - this only says what belongs in it.

param(
    # Package what dist\ already holds instead of building first.
    [switch]$SkipBuild,

    # Where to put the result. Defaults to build\WowLabs.
    [string]$OutDir = "",

    # Open the folder when it is done.
    [switch]$Show
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DistDir = Join-Path $RootDir "dist"
$Neutrino = Join-Path $RootDir "vendor\neutrino"

if (-not $OutDir) { $OutDir = Join-Path $RootDir "build\WowLabs" }

# --- Build ------------------------------------------------------------------
#
# Always, unless told otherwise. A package built from a stale dist\ is the kind
# of thing that is only noticed after it has been sent to someone.

if (-not $SkipBuild) {
    & (Join-Path $RootDir "tools\build.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Build failed." }
    Write-Host ""
}

$StaticDist = Join-Path $DistDir "static"
if (-not (Test-Path (Join-Path $StaticDist "app.css"))) {
    Write-Host "dist\static\app.css is missing. Build first." -ForegroundColor Red
    exit 1
}

# --- Package ----------------------------------------------------------------
#
# The compiled stylesheet comes from dist\ rather than from static\, because it
# is generated at build time and static\ holds the source it is generated from.

& (Join-Path $Neutrino "tools\package.ps1") `
    -Name "WowLabs" `
    -Entry (Join-Path $RootDir "src\main.moon") `
    -AppSrc @(
        (Join-Path $RootDir "src"),
        (Join-Path $RootDir "vendor\lua-dbc\src")
    ) `
    -Include @($StaticDist) `
    -OutDir $OutDir

if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }

# --- Check it is whole ------------------------------------------------------
#
# Named files rather than a size: a package that is missing one of these starts
# and then fails in a message box, which is the worst way to find out.

$required = @(
    "WowLabs.exe",
    "lua51.dll",
    "app\main.lua",
    "app\neutrino.lua",
    "app\shell\window.lua",
    "app\shell\settings.lua",
    "app\settings.lua",
    "app\workspace.lua",
    "app\dbc\init.lua",
    "static\app.css",
    "bin\neutrinocef.dll",
    "bin\neutrinocef_helper.exe"
)

$missing = @()
foreach ($item in $required) {
    if (-not (Test-Path (Join-Path $OutDir $item))) { $missing += $item }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "The package is incomplete:" -ForegroundColor Red
    foreach ($item in $missing) { Write-Host "  missing $item" -ForegroundColor Red }
    exit 1
}

$size = (Get-ChildItem -Path $OutDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum

Write-Host ""
Write-Host "[wowlabs] Packaged to $OutDir ($([math]::Round($size / 1mb)) MB)" -ForegroundColor Green
Write-Host "          Run it with `"$OutDir\WowLabs.exe`"" -ForegroundColor Green

if ($Show) { Start-Process explorer.exe $OutDir }
