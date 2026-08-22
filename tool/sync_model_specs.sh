#!/usr/bin/env bash
#
# Copies audio.cpp's model specs into the app's assets.
#
# The catalogue and the generated option controls both read these. Copying at
# build time rather than committing a second copy means the catalogue cannot
# drift from the pinned submodule -- a stale spec would otherwise advertise
# packages the linked engine cannot load.
#
# Run after checking out or bumping the submodule. Cheap and idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/third_party/audio.cpp/model_specs"
DEST_DIR="${REPO_ROOT}/audiocpp_flutter/assets/model_specs"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "error: ${SOURCE_DIR} not found" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"
cp "${SOURCE_DIR}"/*.json "${DEST_DIR}/"

# Flutter cannot list an asset directory at runtime, so ship an index the app
# reads first. Generating it here keeps it honest.
(
  cd "${DEST_DIR}"
  printf '%s\n' *.json | python3 -c 'import json,sys; print(json.dumps(sorted(l.strip() for l in sys.stdin if l.strip()), indent=2))' > index.json
)

COUNT="$(find "${DEST_DIR}" -name '*.json' -not -name 'index.json' | wc -l | tr -d ' ')"
COMMIT="$(git -C "${REPO_ROOT}/third_party/audio.cpp" rev-parse --short HEAD)"
echo "==> synced ${COUNT} model specs from audio.cpp@${COMMIT}"
