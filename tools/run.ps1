# Runs the built application from dist\.
#
#   .\tools\run.ps1
#
# LUA_PATH is set explicitly rather than left to the defaults: a machine-wide
# LuaRocks installation otherwise shadows the vendored tree, and the failure
# looks like a missing module rather than the wrong copy of a present one.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DistDir = Join-Path $RootDir "dist"
$DepsDir = Join-Path $RootDir "vendor\neutrino\deps"
$RocksDir = Join-Path $DepsDir "rocks"
$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"

if (-not (Test-Path (Join-Path $DistDir "main.lua"))) {
    Write-Host "dist\main.lua is missing. Run .\tools\build.ps1 first." -ForegroundColor Red
    exit 1
}

$env:LUA_PATH = "$DistDir\?.lua;$DistDir\?\init.lua;$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;"

$Arguments = @("main.lua")
if ($ScriptArgs) { $Arguments += $ScriptArgs }

Push-Location $DistDir
try {
    & $LuaExe $Arguments
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

exit $code
