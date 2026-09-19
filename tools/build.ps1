# Builds WowLabs into dist\.
#
#   .\tools\build.ps1
#   .\tools\build.ps1 -Runtime      # also refresh the CEF runtime in dist\bin
#
# The framework is built by its own script and copied in, rather than compiled
# again here. One build of Neutrino, and a change in the submodule reaches the
# application on the next build with nothing to remember.

param(
    # Copy the CEF runtime again. It is 400 MB and never changes between
    # builds, so it is skipped once dist\bin exists.
    [switch]$Runtime
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")

# Invoke-Native comes from the framework rather than being written again:
# a native program writing to stderr is not a failure, and with
# ErrorActionPreference set to Stop PowerShell insists that it is.
. (Join-Path $RootDir "vendor\neutrino\tools\vcenv.ps1")
$SrcDir = Join-Path $RootDir "src"
$DistDir = Join-Path $RootDir "dist"
$StaticSrc = Join-Path $RootDir "static"

$Neutrino = Join-Path $RootDir "vendor\neutrino"
$NeutrinoDist = Join-Path $Neutrino "dist"
$DbcRoot = Join-Path $RootDir "vendor\lua-dbc"
$DbcSrc = Join-Path $DbcRoot "src"

# The one build this tool targets. Named here because the definitions are
# trimmed to it; workspace.moon defaults to the same string.
$Build = "3.3.5.12340"

$DepsDir = Join-Path $Neutrino "deps"
$RocksDir = Join-Path $DepsDir "rocks"
$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"
$MooncFile = Join-Path $RocksDir "lib\luarocks\rocks-5.1\moonscript\0.7.0-1\bin\moonc"
$TailwindExe = Join-Path $RootDir "tools\bin\tailwindcss.exe"

function Step($message) { Write-Host "  $message" -ForegroundColor Yellow }

foreach ($required in @($LuaExe, $TailwindExe)) {
    if (-not (Test-Path $required)) {
        Write-Host "Missing $required" -ForegroundColor Red
        Write-Host "Run .\tools\get-deps.ps1 first." -ForegroundColor Red
        exit 1
    }
}

Write-Host "[wowlabs] Building..." -ForegroundColor Cyan

# --- The framework ----------------------------------------------------------

Step "Neutrino"
& (Join-Path $Neutrino "tools\build.ps1") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Neutrino's build failed." }

$hadRuntime = Test-Path (Join-Path $DistDir "bin")
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# The framework's Lua, and its native layer beside it. Everything except the
# framework's own test suites, which are its business and not ours.
foreach ($item in Get-ChildItem -Path $NeutrinoDist) {
    if ($item.Name -eq "tests") { continue }
    if ($item.Name -eq "bin" -and $hadRuntime -and -not $Runtime) { continue }
    Copy-Item -Recurse -Force -Path $item.FullName -Destination $DistDir
}

# Its test harness, though. Counting, sections, and waiting for a page to say
# something are the same problem here as there, and a second copy would be a
# second copy to fix.
$TestsOut = Join-Path $DistDir "tests"
New-Item -ItemType Directory -Path $TestsOut -Force | Out-Null
Copy-Item -Force -Destination $TestsOut `
          -Path (Join-Path $NeutrinoDist "tests\harness.lua")

# --- lua-dbc ----------------------------------------------------------------
#
# Plain Lua, so it is copied rather than compiled. It arrives as a submodule and
# ships as part of the application.

Step "lua-dbc"
Copy-Item -Recurse -Force -Path (Join-Path $DbcSrc "dbc") -Destination $DistDir

$env:LUA_PATH = "$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;;;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;;;"

# --- Definitions ------------------------------------------------------------
#
# lua-dbc's definitions/ is every version of every table WoWDBDefs knows about:
# 193 MB, of which this application reads the 3.3.5.12340 layout and nothing
# else. The subset is generated rather than committed, because it is derived
# from the submodule and would otherwise be a copy to keep in step by hand.
#
# Under a second for the whole set, so it runs on every build - and the only
# thing that could make it stale is exactly the thing a build is for.

Step "Definitions: 3.3.5.12340"
$DefsOut = Join-Path $DistDir "definitions"
if (Test-Path $DefsOut) { Remove-Item -Recurse -Force $DefsOut }

Push-Location $DbcRoot
& $LuaExe (Join-Path $DbcRoot "tools\slim_definitions.lua") `
    (Join-Path $DbcRoot "definitions") $DefsOut $Build
$definitionsFailed = $LASTEXITCODE -ne 0
Pop-Location
if ($definitionsFailed) { Write-Host "Definitions failed." -ForegroundColor Red; exit 1 }

# Named rather than counted: a table whose definition went missing is a table
# the editor silently refuses to open, which is not how anyone wants to find
# out. Spell and Item are the two nothing works without.
foreach ($table in @("Spell", "Item", "AreaTable", "Map")) {
    if (-not (Test-Path (Join-Path $DefsOut "$table.json"))) {
        Write-Host "definitions\$table.json was not produced." -ForegroundColor Red
        exit 1
    }
}

# --- The application --------------------------------------------------------

Step "MoonScript: src/"
Push-Location $SrcDir
& $LuaExe $MooncFile -t "$DistDir" .
$compileFailed = $LASTEXITCODE -ne 0
Pop-Location
if ($compileFailed) { Write-Host "MoonScript compilation failed." -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $DistDir "main.lua"))) {
    Write-Host "src\main.moon did not produce dist\main.lua" -ForegroundColor Red
    exit 1
}

# What a module ships beside its code: etlua markup and the JavaScript the
# page is driven with. Files of their own kind rather than Lua strings, so
# moonc walks past them - they are copied at the path the module asks for.
Step "Module resources"
$resources = Get-ChildItem -Path $SrcDir -Recurse -Include "*.etlua", "*.js"

foreach ($item in $resources) {
    $relative = $item.FullName.Substring("$SrcDir".Length + 1)
    $target = Join-Path $DistDir $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -Force -Path $item.FullName -Destination $target
}

# Named rather than counted, for the same reason the definitions are: a
# template that did not arrive is a region that renders empty, and the place
# to find that out is here.
foreach ($required in @("modules\dbc\views\grid.etlua",
                        "modules\dbc\scripts\grid.js")) {
    if (-not (Test-Path (Join-Path $DistDir $required))) {
        Write-Host "$required was not copied into dist\." -ForegroundColor Red
        exit 1
    }
}

# Suites compile beside the harness rather than into dist\ itself, where a
# suite named after a package would shadow it.
$TestsSrc = Join-Path $RootDir "tests"
if (Test-Path $TestsSrc) {
    Step "MoonScript: tests/"
    Get-ChildItem -Path $TestsSrc -Filter "*.moon" | ForEach-Object {
        $produced = Join-Path $TestsSrc ($_.BaseName + ".lua")
        & $LuaExe $MooncFile $_.FullName
        if (Test-Path $produced) {
            Move-Item $produced (Join-Path $TestsOut ($_.BaseName + ".lua")) -Force
        } else {
            Write-Host "  $($_.Name) failed to compile." -ForegroundColor Red
            exit 1
        }
    }
}

# --- Styles -----------------------------------------------------------------
#
# Tailwind reads the class names out of the sources, so the input list has to
# name every file that can produce markup - the MoonScript, and the templates
# inside it. It scans text, so the language does not matter.

Step "Tailwind"
$StaticOut = Join-Path $DistDir "static"
New-Item -ItemType Directory -Path $StaticOut -Force | Out-Null

$tailwindInput = Join-Path $StaticSrc "tailwind.css"
$tailwindOutput = Join-Path $StaticOut "app.css"

Invoke-Native "Tailwind" {
    & $TailwindExe --input $tailwindInput --output $tailwindOutput --minify
}

if (-not (Test-Path (Join-Path $StaticOut "app.css"))) {
    Write-Host "Tailwind produced no stylesheet." -ForegroundColor Red
    exit 1
}

# The libraries the interface draws with, from vendor/ rather than from
# static/: they are fetched by get-deps like every other dependency, and a copy
# committed under static/ would be a second place they could drift from.
$VendorJs = Join-Path $RootDir "vendor\js"
$Wanted = @("cytoscape.min.js", "tabulator.min.js", "tabulator.min.css")

foreach ($file in $Wanted) {
    $from = Join-Path $VendorJs $file
    if (Test-Path $from) {
        Copy-Item -Force -Path $from -Destination (Join-Path $StaticOut $file)
    } else {
        Write-Host "  vendor\js\$file is missing. Run:" -ForegroundColor Red
        Write-Host "  .\tools\get-deps.ps1" -ForegroundColor Red
        exit 1
    }
}

# Everything else in static/ as it is: fonts, icons, anything not generated.
foreach ($item in Get-ChildItem -Path $StaticSrc) {
    if ($item.Name -in @("tailwind.css", "app.css")) { continue }
    Copy-Item -Recurse -Force -Path $item.FullName -Destination $StaticOut
}

$css = (Get-Item (Join-Path $StaticOut "app.css")).Length
Write-Host ""
Write-Host "[wowlabs] Build complete ($([math]::Round($css / 1kb)) KB of CSS)." -ForegroundColor Green
Write-Host "          Run it with .\tools\run.ps1" -ForegroundColor Green
