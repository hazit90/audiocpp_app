#Requires -Version 5.1
<#
.SYNOPSIS
Builds audiocpp_ffi.dll (audio.cpp + the FFI shim) for Windows on the CPU
backend, and drops it where the Flutter Windows plugin expects to bundle it.

.DESCRIPTION
The Windows twin of tool/build_macos.sh. Runs out of band rather than from the
plugin's CMakeLists on purpose: compiling ggml and the engine takes minutes, and
Flutter would otherwise re-run it on every incremental build.

CPU-only by design for now. The tuning targets Intel Core Ultra -- see the
comments on GGML_AVX_VNNI and GGML_AVX512 below, both of which are deliberate.

Must be run from a Visual Studio Developer PowerShell (or after
Launch-VsDevShell.ps1) so that cl.exe is on PATH.

.EXAMPLE
.\tool\build_windows.ps1
.EXAMPLE
.\tool\build_windows.ps1 -BuildType Debug -Clean
.EXAMPLE
.\tool\build_windows.ps1 -Models "minimax_music3;ace_step"
#>

[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo')]
    [string] $BuildType = $(if ($env:BUILD_TYPE) { $env:BUILD_TYPE } else { 'Release' }),

    [string] $Models = $(if ($env:AUDIOCPP_MODELS) { $env:AUDIOCPP_MODELS } else { 'minimax_music3;stable_audio' }),

    [int] $Jobs = $(if ($env:JOBS) { [int]$env:JOBS } else { [Environment]::ProcessorCount }),

    # AVX-VNNI is a large win on the int8 dot products that dominate q4_0
    # matmul, and every Core Ultra part has it. It is NOT part of ggml's
    # INS_ENB default group, so it only turns on if we ask.
    #
    # The cost is a hard floor on the CPU: enabling it bakes VNNI intrinsics
    # into the AVX2 kernels with no runtime check, so the DLL will fault with
    # an illegal instruction on anything older than Intel Alder Lake (12th
    # gen) or AMD Zen 5. Pass -NoVnni to build for older hardware.
    [switch] $NoVnni,

    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PackageDir   = Split-Path -Parent $PSScriptRoot
$RepoRoot     = Split-Path -Parent (Split-Path -Parent $PackageDir)
$SubmoduleDir = Join-Path $RepoRoot 'third_party\audio.cpp'
$BuildDir     = Join-Path $PackageDir 'build\windows'
$OutputDir    = Join-Path $PackageDir 'windows\Libs'
$HeaderPath   = Join-Path $PackageDir 'src\include\audiocpp_ffi.h'

# --- preconditions -----------------------------------------------------------

if (-not (Test-Path (Join-Path $SubmoduleDir 'CMakeLists.txt'))) {
    throw "audio.cpp submodule is empty at $SubmoduleDir. Run: git submodule update --init --recursive"
}

foreach ($tool in @('cmake', 'ninja')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found on PATH. Install it (winget install Kitware.CMake Ninja-build.Ninja) and reopen the shell."
    }
}

# nvcc aside, everything here needs the MSVC toolchain on PATH. Catching it now
# gives a one-line fix instead of a wall of CMake compiler-detection output.
if (-not (Get-Command 'cl.exe' -ErrorAction SilentlyContinue)) {
    throw @'
cl.exe not found on PATH.

Open "x64 Native Tools Command Prompt for VS 2022" and run powershell there, or
in an existing shell run:
  & "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64
'@
}

if ($Clean -or $env:CLEAN -eq '1') {
    if (Test-Path $BuildDir) {
        Write-Host '==> cleaning build directory'
        Remove-Item -Recurse -Force $BuildDir
    }
}

# --- configure ---------------------------------------------------------------

$vnni = if ($NoVnni) { 'OFF' } else { 'ON' }

Write-Host "==> configuring (type=$BuildType models=$Models avx_vnni=$vnni jobs=$Jobs)"

$cmakeArgs = @(
    '-S', (Join-Path $PackageDir 'src')
    '-B', $BuildDir
    '-G', 'Ninja'

    # nvcc aside, MSVC is the only supported compiler here: audio.cpp's CMake
    # has an if(MSVC) branch for /permissive-, /utf-8 and OpenMP that clang-cl
    # does not trigger.
    '-DCMAKE_C_COMPILER=cl'
    '-DCMAKE_CXX_COMPILER=cl'
    "-DCMAKE_BUILD_TYPE=$BuildType"

    # /utf-8 is required, not cosmetic: src/community_models/inflect_v2/frontend.cpp
    # has non-ASCII literals that MSVC otherwise decodes as the active code page.
    '-DCMAKE_C_FLAGS=/utf-8'
    '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc'

    # Match the Flutter runner's dynamic CRT. Nothing is allocated on one side
    # of the FFI boundary and freed on the other, so this is belt and braces --
    # but a mismatched CRT is the kind of bug that only shows up under load.
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'

    "-DAUDIOCPP_FFI_SOURCE_DIR=$SubmoduleDir"
    '-DAUDIOCPP_MODEL_SET=custom'
    "-DAUDIOCPP_MODELS=$Models"

    # --- backends ---
    # CPU only for now. CUDA comes later; adding it is a matter of
    # -DENGINE_ENABLE_CUDA=ON plus -DCMAKE_CUDA_ARCHITECTURES for the target
    # card, and the resulting DLL still contains this CPU backend.
    '-DENGINE_ENABLE_METAL=OFF'
    '-DENGINE_ENABLE_CUDA=OFF'
    '-DENGINE_ENABLE_VULKAN=OFF'
    '-DENGINE_ENABLE_HIP=OFF'

    # --- CPU tuning: Intel Core Ultra ---
    # NATIVE=OFF does not mean "unoptimised". It flips ggml's INS_ENB group on,
    # which turns on SSE4.2/AVX/AVX2/BMI2 (and FMA+F16C, implied by /arch:AVX2
    # on MSVC) as an explicit baseline rather than whatever the build machine
    # happens to report. On MSVC, NATIVE=ON instead runs FindSIMD.cmake, which
    # probes for AVX/AVX2/AVX512 and knows nothing about VNNI.
    '-DENGINE_ENABLE_NATIVE_CPU=OFF'
    "-DGGML_AVX_VNNI=$vnni"

    # Explicit, because it is the one flag that would look like an upgrade and
    # is not: no Core Ultra part has AVX-512. Intel disabled it across the
    # hybrid P-core/E-core designs from Alder Lake onward, so /arch:AVX512
    # produces a binary that faults on the target machine. AMX is Xeon-only
    # and MSVC does not support it either way.
    '-DGGML_AVX512=OFF'

    # Runtime repack of Q4_0 into the blocked layout the AVX2/VNNI kernels
    # want. On by default upstream; pinned here because it is most of the
    # reason q4_0 is usable on CPU at all.
    '-DGGML_CPU_REPACK=ON'

    # llamafile's SGEMM, the main CPU matmul path.
    '-DENGINE_ENABLE_LLAMAFILE=ON'

    # macOS passes OFF only because Apple clang ships no libomp. MSVC has
    # OpenMP, and audio.cpp already handles it -- but its default /openmp is
    # OpenMP 2.0 and rejects the code, hence :experimental.
    '-DENGINE_ENABLE_OPENMP=ON'
    '-DOpenMP_C_FLAGS=/openmp:experimental'
    '-DOpenMP_CXX_FLAGS=/openmp:experimental'
)

& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

# --- build -------------------------------------------------------------------

Write-Host '==> building'
& cmake --build $BuildDir --target audiocpp_ffi --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

$dll = Get-ChildItem -Path $BuildDir -Filter 'audiocpp_ffi.dll' -Recurse -File |
       Select-Object -First 1
if (-not $dll) { throw 'build succeeded but audiocpp_ffi.dll was not found' }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-Item -Force $dll.FullName (Join-Path $OutputDir 'audiocpp_ffi.dll')

# The import library is not needed at runtime (Dart uses LoadLibrary + GetProcAddress)
# but copying it keeps dumpbin/link diagnostics next to the binary they describe.
$lib = Get-ChildItem -Path $BuildDir -Filter 'audiocpp_ffi.lib' -Recurse -File |
       Select-Object -First 1
if ($lib) { Copy-Item -Force $lib.FullName (Join-Path $OutputDir 'audiocpp_ffi.lib') }

$installed = Join-Path $OutputDir 'audiocpp_ffi.dll'

# --- verify the export surface ----------------------------------------------

# The twin of the `nm -gU | grep -c ' T '` check in CLAUDE.md. Read the expected
# count out of the header rather than hardcoding it, so a new AUDIOCPP_API
# function that fails to export cannot slip through silently.
$expected = @([regex]::Matches(
    (Get-Content -Raw $HeaderPath),
    '(?m)^AUDIOCPP_API\s+(?:[\w\s\*/]*?)\b(audiocpp_\w+)\s*\('
) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count

if ($expected -eq 0) { throw "no AUDIOCPP_API entry points found in $HeaderPath" }

if (Get-Command 'dumpbin.exe' -ErrorAction SilentlyContinue) {
    # @() so a zero-match result is still countable under Set-StrictMode.
    $actual = @(& dumpbin /nologo /exports $installed |
                Select-String -Pattern '\baudiocpp_\w+$').Count
    if ($actual -ne $expected) {
        throw "export mismatch: header declares $expected AUDIOCPP_API functions, DLL exports $actual"
    }
    Write-Host "==> exports verified ($actual/$expected)"
} else {
    Write-Warning 'dumpbin not on PATH, skipping export verification'
}

Write-Host "==> installed $installed"
Get-Item $installed | Format-List Name, Length, LastWriteTime
