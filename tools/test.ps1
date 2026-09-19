# Runs the test suites and reports one verdict.
#
#   .\tools\test.ps1
#   .\tools\test.ps1 -Only shell
#
# They drive a real window, because what is being tested is a real window.
# Nobody needs to be present.

param(
    [ValidateSet("all", "shell", "settings", "dbc")]
    [string]$Only = "all"
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DistDir = Join-Path $RootDir "dist"
$DepsDir = Join-Path $RootDir "vendor\neutrino\deps"
$RocksDir = Join-Path $DepsDir "rocks"
$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"

if (-not (Test-Path $DistDir)) {
    Write-Host "dist\ is missing. Run .\tools\build.ps1 first." -ForegroundColor Red
    exit 1
}

# Set explicitly: a machine-wide LuaRocks installation otherwise shadows the
# vendored tree, and the failure reads as a missing module rather than as the
# wrong copy of a present one. dist\tests is on the path for the harness; the
# working directory stays dist\ so the application resolves its own paths.
$env:LUA_PATH = "$DistDir\?.lua;$DistDir\?\init.lua;$DistDir\tests\?.lua;$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;"

$suites = @("shell", "settings", "dbc")
if ($Only -ne "all") { $suites = @($Only) }

$failed = @()

Push-Location $DistDir
try {
    foreach ($suite in $suites) {
        $script = "tests\$suite.lua"
        if (-not (Test-Path $script)) {
            Write-Host "Missing $script - was it built?" -ForegroundColor Red
            $failed += $suite
            continue
        }

        Write-Host ""
        Write-Host "=== $suite ===" -ForegroundColor Cyan

        # Chromium writes a great deal to stderr that has nothing to do with
        # the tests; the suites report through stdout.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { & $LuaExe $script 2>$null } finally { $ErrorActionPreference = $previous }

        if ($LASTEXITCODE -ne 0) { $failed += $suite }
    }
} finally {
    Pop-Location
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "All suites passed." -ForegroundColor Green
