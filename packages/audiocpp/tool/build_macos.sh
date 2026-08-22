#!/usr/bin/env bash
#
# Builds libaudiocpp_ffi.dylib (audio.cpp + the FFI shim) for macOS with Metal,
# and drops it where the CocoaPods podspec expects to vendor it.
#
# This runs out of band rather than from a podspec script_phase on purpose:
# compiling ggml and the engine takes minutes, and Xcode would otherwise re-run
# it on every incremental Flutter build.
#
# Usage:
#   ./tool/build_macos.sh                  # release, Metal, minimax_music3 only
#   BUILD_TYPE=Debug ./tool/build_macos.sh
#   AUDIOCPP_MODELS="minimax_music3;ace_step" ./tool/build_macos.sh
#   CLEAN=1 ./tool/build_macos.sh          # drop the CMake cache first

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_DIR}/../.." && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/third_party/audio.cpp"
BUILD_DIR="${PACKAGE_DIR}/build/macos"
OUTPUT_DIR="${PACKAGE_DIR}/macos/Libs"

BUILD_TYPE="${BUILD_TYPE:-Release}"
AUDIOCPP_MODELS="${AUDIOCPP_MODELS:-minimax_music3}"
# audio.cpp calls std::to_chars on floats (src/framework/debug/trace.cpp), which
# libc++ only exposes from macOS 13.3. Anything lower fails to compile, and the
# host app's own deployment target must be at least this high to link the dylib.
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.3}"
# Apple silicon gets Metal; on Intel Macs Metal support in ggml is not worth the
# trouble, so fall back to the CPU backend.
if [[ "$(uname -m)" == "arm64" ]]; then
  ENABLE_METAL="${ENABLE_METAL:-ON}"
else
  ENABLE_METAL="${ENABLE_METAL:-OFF}"
fi

if [[ ! -f "${SUBMODULE_DIR}/CMakeLists.txt" ]]; then
  echo "error: audio.cpp submodule is empty at ${SUBMODULE_DIR}" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found on PATH (brew install cmake)" >&2
  exit 1
fi

# Ninja is a lot faster on a tree this size, but not worth making mandatory.
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
else
  GENERATOR="Unix Makefiles"
  echo "note: ninja not found, falling back to make (brew install ninja for faster builds)"
fi

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

if [[ "${CLEAN:-0}" == "1" ]]; then
  rm -rf "${BUILD_DIR}"
fi

echo "==> configuring (type=${BUILD_TYPE} metal=${ENABLE_METAL} models=${AUDIOCPP_MODELS} macos=${DEPLOYMENT_TARGET})"
cmake -S "${PACKAGE_DIR}/src" -B "${BUILD_DIR}" -G "${GENERATOR}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DAUDIOCPP_FFI_SOURCE_DIR="${SUBMODULE_DIR}" \
  -DAUDIOCPP_MODEL_SET=custom \
  -DAUDIOCPP_MODELS="${AUDIOCPP_MODELS}" \
  -DENGINE_ENABLE_METAL="${ENABLE_METAL}" \
  -DENGINE_ENABLE_OPENMP=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"

echo "==> building"
cmake --build "${BUILD_DIR}" --target audiocpp_ffi --parallel "${JOBS}"

DYLIB="$(find "${BUILD_DIR}" -name 'libaudiocpp_ffi.dylib' -type f -print -quit)"
if [[ -z "${DYLIB}" ]]; then
  echo "error: build succeeded but libaudiocpp_ffi.dylib was not found" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
cp "${DYLIB}" "${OUTPUT_DIR}/libaudiocpp_ffi.dylib"

echo "==> installed ${OUTPUT_DIR}/libaudiocpp_ffi.dylib"
ls -lh "${OUTPUT_DIR}/libaudiocpp_ffi.dylib"
