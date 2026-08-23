#!/usr/bin/env bash
#
# Makes a checkout ready to run on iOS, and is cheap enough to sit in front of
# every launch. The iOS counterpart of setup_macos.sh, with the same contract:
#
#   1. initialises the audio.cpp submodule if it is empty
#   2. runs `flutter pub get` where it has never been run
#   3. rebuilds audiocpp.xcframework only when it is missing or stale
#
# The common case -- nothing changed since the last launch -- exits in well
# under a second. Pass FORCE=1 to rebuild regardless.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_DIR}/../.." && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/third_party/audio.cpp"
APP_DIR="${REPO_ROOT}/audiocpp_flutter"
XCFRAMEWORK="${PACKAGE_DIR}/ios/Frameworks/audiocpp.xcframework"
STAMP="${PACKAGE_DIR}/ios/Frameworks/.build-stamp"

log() { printf '[setup-ios] %s\n' "$1"; }

# --- 1. submodule ------------------------------------------------------------

if [[ ! -f "${SUBMODULE_DIR}/CMakeLists.txt" ]]; then
  log 'audio.cpp submodule is empty, initialising (this fetches ~200 MB)'
  git -C "${REPO_ROOT}" submodule update --init --recursive
fi

SUBMODULE_SHA="$(git -C "${SUBMODULE_DIR}" rev-parse HEAD)"

# --- 2. dart dependencies ----------------------------------------------------

for dir in "${PACKAGE_DIR}" "${APP_DIR}"; do
  if [[ ! -f "${dir}/.dart_tool/package_config.json" ]]; then
    log "flutter pub get in $(basename "${dir}")"
    (cd "${dir}" && flutter pub get)
  fi
done

# --- 3. native library -------------------------------------------------------

needs_build() {
  [[ "${FORCE:-0}" == "1" ]] && { echo 'FORCE=1'; return 0; }
  [[ -d "${XCFRAMEWORK}" ]] || { echo 'xcframework missing'; return 0; }

  # A submodule bump changes the engine the shim compiles against, and mtimes
  # alone would not notice it.
  if [[ ! -f "${STAMP}" ]] || [[ "$(cat "${STAMP}")" != "${SUBMODULE_SHA}" ]]; then
    echo 'audio.cpp revision changed'
    return 0
  fi

  # Any shim source, header, export list or CMake change newer than the binary.
  if [[ -n "$(find "${PACKAGE_DIR}/src" -type f -newer "${XCFRAMEWORK}" -print -quit)" ]]; then
    echo 'shim sources changed'
    return 0
  fi

  if [[ "${PACKAGE_DIR}/tool/build_ios.sh" -nt "${XCFRAMEWORK}" ]]; then
    echo 'build script changed'
    return 0
  fi

  return 1
}

if reason="$(needs_build)"; then
  log "rebuilding native library (${reason})"
  "${PACKAGE_DIR}/tool/build_ios.sh"
  printf '%s' "${SUBMODULE_SHA}" > "${STAMP}"
else
  log 'native library is up to date'
fi
