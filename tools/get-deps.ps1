# Fetches everything WowLabs needs to build.
#
# Two halves: whatever Neutrino needs, which its own script knows about, and the
# Tailwind compiler, which is ours.
#
#   .\tools\get-deps.ps1
#   .\tools\get-deps.ps1 -Only tailwind
#
# Run it after cloning, and after `git submodule update` brings a new Neutrino.

param(
    [ValidateSet("all", "neutrino", "tailwind")]
    [string]$Only = "all",

    # Fetch again even when the file is already there.
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$Neutrino = Join-Path $RootDir "vendor\neutrino"
$BinDir = Join-Path $RootDir "tools\bin"

# Pinned, like every other dependency here. The standalone build is the whole
# Tailwind compiler in one executable: no Node, no npm, nothing installed
# system-wide, and it works with no network once it is on disk.
$TailwindVersion = "v4.3.3"
$TailwindExe = Join-Path $BinDir "tailwindcss.exe"

function Step($message) { Write-Host "[wowlabs] $message" -ForegroundColor Cyan }
function Note($message) { Write-Host "          $message" -ForegroundColor DarkGray }

function Want($component) {
    return $Only -eq "all" -or $Only -eq $component
}

# --- Neutrino ---------------------------------------------------------------

if (Want "neutrino") {
    if (-not (Test-Path (Join-Path $Neutrino "tools\get-deps.ps1"))) {
        Write-Host "vendor\neutrino is empty. Run:" -ForegroundColor Red
        Write-Host "  git submodule update --init --recursive" -ForegroundColor Red
        exit 1
    }

    Step "Neutrino dependencies"
    & (Join-Path $Neutrino "tools\get-deps.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Neutrino's get-deps failed." }

    Step "Neutrino native layer"
    & (Join-Path $Neutrino "tools\build-native.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Neutrino's native build failed." }
}

# --- Tailwind ---------------------------------------------------------------

if (Want "tailwind") {
    if ((Test-Path $TailwindExe) -and -not $Force) {
        Note "Tailwind already present"
    } else {
        Step "Tailwind $TailwindVersion"
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

        $url = "https://github.com/tailwindlabs/tailwindcss/releases/download/" +
               "$TailwindVersion/tailwindcss-windows-x64.exe"

        # TLS 1.2 named explicitly: Windows PowerShell 5.1 still defaults to
        # older protocols on some machines, and GitHub refuses those.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $TailwindExe -UseBasicParsing

        Note "tools\bin\tailwindcss.exe"
    }
}

Write-Host ""
Write-Host "[wowlabs] Ready. Next: .\tools\build.ps1" -ForegroundColor Green
