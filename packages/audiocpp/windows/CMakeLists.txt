# Flutter Windows plugin entry point for the audiocpp FFI shim.
#
# This compiles nothing. audiocpp_ffi.dll is built out of band by
# tool/build_windows.ps1 -- compiling ggml and the engine takes minutes, and
# Flutter would otherwise re-run it on every incremental build. All this file
# does is hand the DLL to the runner so it gets copied next to the executable,
# which is where lib/src/ffi/library.dart looks for it.
cmake_minimum_required(VERSION 3.14)

project(audiocpp LANGUAGES CXX)

set(AUDIOCPP_DLL "${CMAKE_CURRENT_SOURCE_DIR}/Libs/audiocpp_ffi.dll")

# The macOS podspec has a script_phase that fails the build when the dylib is
# missing; this is the Windows twin. Without it the app builds clean, ships
# without a native library, and only fails when someone presses Generate.
if (NOT EXISTS "${AUDIOCPP_DLL}")
    message(FATAL_ERROR
        "audiocpp_ffi.dll not found at ${AUDIOCPP_DLL}.\n"
        "Build it first, from a Visual Studio Developer PowerShell:\n"
        "  packages\\audiocpp\\tool\\setup_windows.ps1")
endif()

# generated_plugins.cmake appends this to PLUGIN_BUNDLED_LIBRARIES, which the
# runner installs into the directory holding the .exe.
set(audiocpp_bundled_libraries "${AUDIOCPP_DLL}" PARENT_SCOPE)
