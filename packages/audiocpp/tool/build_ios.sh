#!/usr/bin/env bash
#
# Builds audiocpp.xcframework (audio.cpp + the FFI shim) for iOS and drops it
# where the CocoaPods podspec expects to vendor it.
#
# Unlike macOS, iOS gets a *static* library: Apple's distribution format for a
# prebuilt binary is an .xcframework, and a static slice inside one has nothing
# to embed and nothing to code-sign. The tradeoff is that CMake does not roll
# an archive's dependencies into it, so this script merges every static library
# the build produced into one archive with libtool.
#
# Runs out of band rather than from a podspec script_phase, for the same reason
# build_macos.sh does: compiling ggml takes minutes and Xcode would re-run it on
# every incremental Flutter build.
#
# Usage:
#   ./tool/build_ios.sh                    # release, device arm64, Metal
#   BUILD_TYPE=Debug ./tool/build_ios.sh
#   SIMULATOR=1 ./tool/build_ios.sh        # add a simulator slice
#   AUDIOCPP_MODELS="minimax_music3;ace_step" ./tool/build_ios.sh
#   CLEAN=1 ./tool/build_ios.sh            # drop the CMake cache first

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_DIR}/../.." && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/third_party/audio.cpp"
BUILD_ROOT="${PACKAGE_DIR}/build/ios"
OUTPUT_DIR="${PACKAGE_DIR}/ios/Frameworks"
XCFRAMEWORK="${OUTPUT_DIR}/audiocpp.xcframework"

BUILD_TYPE="${BUILD_TYPE:-Release}"
AUDIOCPP_MODELS="${AUDIOCPP_MODELS:-minimax_music3}"
# audio.cpp calls std::to_chars on floats (src/framework/debug/trace.cpp). libc++
# only exposes that overload from iOS 16.3 -- the same libc++ release that gates
# the macOS build to 13.3. The app's IPHONEOS_DEPLOYMENT_TARGET and the Podfile's
# `platform :ios` must be at least this high.
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-16.3}"
# Every iOS device has Metal. The simulator does not run ggml's Metal kernels
# usefully, but the backend still compiles, so one setting covers both.
ENABLE_METAL="${ENABLE_METAL:-ON}"
SIMULATOR="${SIMULATOR:-0}"

if [[ ! -f "${SUBMODULE_DIR}/CMakeLists.txt" ]]; then
  echo "error: audio.cpp submodule is empty at ${SUBMODULE_DIR}" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found on PATH (brew install cmake)" >&2
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "error: no iOS SDK found. Install Xcode and its iOS platform, then:" >&2
  echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
else
  GENERATOR="Unix Makefiles"
  echo "note: ninja not found, falling back to make (brew install ninja for faster builds)"
fi

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

if [[ "${CLEAN:-0}" == "1" ]]; then
  rm -rf "${BUILD_ROOT}"
fi

# Builds one SDK slice and merges its archives. $1 = slice name (matches the
# CMake sysroot), $2 = architectures.
build_slice() {
  local slice="$1"
  local archs="$2"
  local build_dir="${BUILD_ROOT}/${slice}"
  # Must be named libaudiocpp_ffi.a, not <slice>-libaudiocpp_ffi.a: CocoaPods
  # emits a -l flag for a vendored static library by stripping a leading "lib"
  # from the filename, so anything not following the libFoo.a convention
  # produces a -l the linker cannot resolve. Each slice therefore gets its own
  # directory rather than its own filename.
  local merged="${BUILD_ROOT}/merged/${slice}/libaudiocpp_ffi.a"
  mkdir -p "$(dirname "${merged}")"

  echo "==> configuring ${slice} (type=${BUILD_TYPE} archs=${archs} metal=${ENABLE_METAL} models=${AUDIOCPP_MODELS} ios=${DEPLOYMENT_TARGET})"
  cmake -S "${PACKAGE_DIR}/src" -B "${build_dir}" -G "${GENERATOR}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${slice}" \
    -DCMAKE_OSX_ARCHITECTURES="${archs}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DAUDIOCPP_FFI_STATIC=ON \
    -DAUDIOCPP_FFI_SOURCE_DIR="${SUBMODULE_DIR}" \
    -DAUDIOCPP_MODEL_SET=custom \
    -DAUDIOCPP_MODELS="${AUDIOCPP_MODELS}" \
    -DENGINE_ENABLE_METAL="${ENABLE_METAL}" \
    -DENGINE_ENABLE_OPENMP=OFF \
    -DENGINE_ENABLE_NATIVE_CPU=OFF

  echo "==> building ${slice}"
  cmake --build "${build_dir}" --target audiocpp_ffi --parallel "${JOBS}"

  # CMake emits an archive containing only audiocpp_ffi.cpp.o -- a STATIC target
  # does not absorb the libraries it links. Merge in everything the build
  # produced so the vendored archive is self-contained. Only audiocpp_ffi and
  # its dependencies were built (the submodule's other targets are
  # EXCLUDE_FROM_ALL), so every .a here belongs in the result.
  local archives=()
  while IFS= read -r archive; do
    archives+=("${archive}")
  done < <(find "${build_dir}" -name '*.a' -type f | sort)

  if [[ ${#archives[@]} -eq 0 ]]; then
    echo "error: ${slice} build produced no static archives" >&2
    exit 1
  fi

  echo "==> merging ${#archives[@]} archives into ${slice}/libaudiocpp_ffi.a"
  # Duplicate member basenames across archives are normal here and libtool only
  # warns; anything else is a real failure and set -e will catch it.
  libtool -static -o "${merged}" "${archives[@]}" 2>&1 | grep -v 'has the same member name' || true

  if [[ ! -f "${merged}" ]]; then
    echo "error: libtool produced no archive for ${slice}" >&2
    exit 1
  fi

  # The entry points are reached only through dlsym, so nothing references them
  # at link time. If they are missing from the merged archive the app fails at
  # runtime with a confusing "library not found", so check here instead.
  local exported
  exported="$(nm -g "${merged}" 2>/dev/null | grep -c ' T _audiocpp_' || true)"
  echo "==> ${slice}: $(du -h "${merged}" | cut -f1), ${exported} audiocpp_* entry points"
  if [[ "${exported}" -eq 0 ]]; then
    echo "error: merged archive exports no audiocpp_* symbols" >&2
    exit 1
  fi

  SLICE_ARCHIVES+=("${merged}")
}

SLICE_ARCHIVES=()
build_slice iphoneos "arm64"
if [[ "${SIMULATOR}" == "1" ]]; then
  build_slice iphonesimulator "arm64"
fi

echo "==> packaging xcframework"
rm -rf "${XCFRAMEWORK}"
mkdir -p "${OUTPUT_DIR}"

CREATE_ARGS=()
for archive in "${SLICE_ARCHIVES[@]}"; do
  CREATE_ARGS+=(-library "${archive}" -headers "${PACKAGE_DIR}/src/include")
done
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "${XCFRAMEWORK}" >/dev/null

echo "==> installed ${XCFRAMEWORK}"
du -sh "${XCFRAMEWORK}"

# Same trap as the macOS build: vendored_frameworks is a glob CocoaPods resolves
# at `pod install` time. If an install ran while this was missing, the Pods
# project has no reference to it, the app builds clean, and it fails only at
# runtime. Dropping the manifest forces Flutter to re-run pod install.
MANIFEST="${REPO_ROOT}/audiocpp_flutter/ios/Pods/Manifest.lock"
if [[ -f "${MANIFEST}" ]]; then
  rm -f "${MANIFEST}"
  echo "==> invalidated CocoaPods manifest so the xcframework gets re-vendored"
fi
