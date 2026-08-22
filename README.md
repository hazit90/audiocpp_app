# audiocpp_app

A Flutter app that runs [audio.cpp](https://github.com/0xShug0/audio.cpp) models
locally, starting with
[MiniMax Music 3](https://huggingface.co/audio-cpp/MiniMax-Music3-GGUF)
text-to-music generation.

```
audiocpp_app/
├── third_party/audio.cpp     git submodule, pinned upstream C++ engine
├── packages/audiocpp/        Dart FFI package: C shim + typed API
└── audiocpp_flutter/         the app
```

## Architecture

audio.cpp has no C API — its public headers are all C++ (`std::optional`,
`std::filesystem::path`, virtual interfaces), which Dart FFI cannot bind to. So
the integration has four layers:

```
audiocpp_flutter          Flutter UI + MusicGenerationController
       │
package:audiocpp          AudioCppEngine — async API, worker isolate
       │                  NativeBridge   — blocking FFI calls, owns handles
       │
libaudiocpp_ffi.dylib     our C ABI (audiocpp_ffi.h) — 18 exported symbols
       │
third_party/audio.cpp     engine_runtime + ggml (Metal)
```

Two decisions do most of the work:

**All native handles live on one worker isolate.** Loading MiniMax Music 3 and
generating a track both block for minutes. Handles never cross the isolate
boundary — the main isolate holds integer ids, not pointers. The C ABI declares
handles as not thread-safe, and this makes that structurally true instead of a
convention.

**The C shim is the only thing coupled to audio.cpp's C++.** When upstream moves
its headers, `packages/audiocpp/src/audiocpp_ffi.cpp` is what breaks. The Dart
layers above it are insulated by a versioned ABI, checked at load time.

## Setup

```bash
git submodule update --init --recursive
```

Build the native library (a few minutes; compiles ggml + the engine):

```bash
cd packages/audiocpp && ./tool/build_macos.sh
```

Then run the app:

```bash
cd audiocpp_flutter && flutter run -d macos
```

## Getting a model

```bash
cd third_party/audio.cpp
python3 tools/model_manager_v2.py install minimax_music3_q4_0
```

Point the app's "Model package directory" field at the resulting
`MiniMax-Music3-GGUF` folder. Models are not in git — they are gigabytes and the
model manager fetches them.

## Requirements

- macOS 13.3 or newer. audio.cpp uses `std::to_chars` on floats, which libc++
  only exposes from 13.3; the app, the podspec and the CMake deployment target
  are all pinned there and must stay in step.
- Apple silicon for Metal acceleration. Intel Macs fall back to the CPU backend.
- CMake. Ninja is optional but much faster than make on this tree.

## Development

```bash
cd packages/audiocpp && flutter test    # 19 tests, incl. real native calls
cd packages/audiocpp && flutter analyze
cd audiocpp_flutter  && flutter analyze
```

The native smoke tests skip themselves when the dylib has not been built, so a
fresh checkout still runs green. CI should build it first so they run for real.

## Updating audio.cpp

```bash
cd third_party/audio.cpp
git fetch origin && git checkout <commit>
cd ../.. && git add third_party/audio.cpp
cd packages/audiocpp && CLEAN=1 ./tool/build_macos.sh
```

The submodule is pinned to a commit, so a bump is an explicit, reviewable
change. Rebuild and run the tests after one: the shim calls into C++ that
upstream is free to reshape.

## Scope today

- macOS only. The C ABI and CMake are portable; only the packaging is not.
- Offline inference only — no streaming, which the ABI would have to grow
  deliberately. MiniMax Music 3 is offline-only regardless.
- No cancellation or progress reporting: audio.cpp exposes no hook for either on
  the offline session.
- Only `minimax_music3` is linked in. Add families via `AUDIOCPP_MODELS`; the
  build deliberately excludes the other ~49 to keep build time and size down.
