#Requires -Version 5.1
<#
.SYNOPSIS
Makes a checkout ready to run on Windows. Cheap enough to sit in front of every
launch.

.DESCRIPTION
The Windows twin of tool/setup_macos.sh, with the same contract. Does the
minimum needed, in order:

  1. initialises the audio.cpp submodule if it is empty
  2. runs `flutter pub get` where it has never been run
  3. rebuilds audiocpp_ffi.dll only when it is missing or stale

The common case -- nothing changed since the last launch -- exits in well under
a second. Pass -Force to rebuild regardless.

Needs a Visual Studio Developer PowerShell for step 3.
#>

[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PackageDir   = Split-Path -Parent $PSScriptRoot
$RepoRoot     = Split-Path -Parent (Split-Path -Parent $PackageDir)
$SubmoduleDir = Join-Path $RepoRoot 'third_party\audio.cpp'
$AppDir       = Join-Path $RepoRoot 'audiocpp_flutter'
$Dll          = Join-Path $PackageDir 'windows\Libs\audiocpp_ffi.dll'
$Stamp        = Join-Path $PackageDir 'windows\Libs\.build-stamp'
$BuildScript  = Join-Path $PackageDir 'tool\build_windows.ps1'

function Write-Log([string] $Message) { Write-Host "[setup] $Message" }

# --- 1. submodule ------------------------------------------------------------

if (-not (Test-Path (Join-Path $SubmoduleDir 'CMakeLists.txt'))) {
    Write-Log 'audio.cpp submodule is empty, initialising (this fetches ~200 MB)'
    & git -C $RepoRoot submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw 'submodule init failed' }
}

$submoduleSha = (& git -C $SubmoduleDir rev-parse HEAD).Trim()

# --- 2. dart dependencies ----------------------------------------------------

foreach ($dir in @($PackageDir, $AppDir)) {
    if (-not (Test-Path (Join-Path $dir '.dart_tool\package_config.json'))) {
        Write-Log "flutter pub get in $(Split-Path -Leaf $dir)"
        Push-Location $dir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed in $dir" }
        } finally { Pop-Location }
    }
}

# --- 3. native library -------------------------------------------------------

function Get-RebuildReason {
    if ($Force) { return 'Force' }
    if (-not (Test-Path $Dll)) { return 'dll missing' }

    # A submodule bump changes the engine the shim compiles against, and
    # timestamps alone would not notice it.
    $stamped = if (Test-Path $Stamp) { (Get-Content -Raw $Stamp) } else { $null }
    if ([string]::IsNullOrWhiteSpace($stamped) -or $stamped.Trim() -ne $submoduleSha) {
        return 'audio.cpp revision changed'
    }

    $dllTime = (Get-Item $Dll).LastWriteTimeUtc

    # Any shim source, header or CMake change newer than the binary.
    $newer = Get-ChildItem -Path (Join-Path $PackageDir 'src') -Recurse -File |
             Where-Object { $_.LastWriteTimeUtc -gt $dllTime } |
             Select-Object -First 1
    if ($newer) { return 'shim sources changed' }

    if ((Get-Item $BuildScript).LastWriteTimeUtc -gt $dllTime) {
        return 'build script changed'
    }

    return $null
}

$reason = Get-RebuildReason
if ($reason) {
    Write-Log "rebuilding native library ($reason)"
    # build_windows.ps1 throws on any failure and $ErrorActionPreference is
    # Stop, so the exception is the error path. Do not add a $LASTEXITCODE
    # check: it would be reading whatever native command ran last, not this.
    & $BuildScript
    Set-Content -Path $Stamp -Value $submoduleSha -NoNewline
} else {
    Write-Log 'native library is up to date'
}
