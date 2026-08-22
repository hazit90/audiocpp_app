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
audiocpp_flutter          Flutter UI — Create / Library / Models panes,
       │                  GenerationQueue, TrackStore, playback
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

## How the app is arranged

Generation blocks for minutes and cannot be cancelled, which shapes the UI more
than anything else does.

**Work is queued, not awaited.** Describing a track adds it to a queue and
returns immediately; one drain loop runs tracks in order, keeping the model
resident between them. Concurrency is not on the table — the session holds
several gigabytes and audio.cpp's handles are not thread-safe, so a second run
would mean a second resident model rather than more throughput.

**Tracks outlive the session.** Parameters, status and waveform peaks live in
`<Application Support>/tracks/index.json` beside the WAVs, written atomically.
A generation interrupted by a crash comes back as a failed track you can retry,
rather than disappearing.

**Nothing pretends to have progress.** The running track shows elapsed time and
an estimate extrapolated from the previous run at the same steps × seconds, and
says so. See *Scope today* for why there is no real progress bar.

| Path | What it is |
|---|---|
| `lib/src/app_shell.dart` | Navigation, owns the long-lived objects, breakpoints |
| `lib/src/create/` | The prompt form and the queue button |
| `lib/src/library/` | Queue section, track rows, row actions |
| `lib/src/player/` | Playback, waveform, the docked player bar |
| `lib/src/tracks/` | `Track`, `TrackStore`, `GenerationQueue`, failure messages |
| `lib/src/models/` | Catalogue, downloads, which families are offered |

## Setup

Open the **repository root** in VS Code, pick macOS as the device, and press
Start Debugging (F5). A `preLaunchTask` initialises the submodule, fetches Dart
packages and builds the native library before Flutter runs, so a fresh clone
works with no manual steps.

Everything it does is also available from a terminal:

```bash
./packages/audiocpp/tool/setup_macos.sh
cd audiocpp_flutter && flutter run -d macos
```

`setup_macos.sh` is cheap to re-run: it rebuilds the native library only when
the shim sources, the build script, or the pinned audio.cpp revision changed,
and exits in well under a second otherwise. A cold build is about 45 seconds.

> Do not skip it. The dylib is vendored into the app through a CocoaPods glob
> resolved at `pod install` time. Building without it used to produce an app
> that ran and failed only when it tried to load the engine; the podspec now
> fails the build instead, naming this script.

## Getting a model

Open **Models** in the app and download MiniMax Music 3. It installs into
`<Application Support>/models/`, and Create picks it up with no path to type.
Models are not in git — they are gigabytes.

Only families listed in `audiocpp_flutter/lib/src/models/supported_models.dart`
are offered. Availability is a decision, not a discovery: three things must
agree before a family works, and that file documents them.

Upstream's installer still works if you prefer it, but the app will not see the
result unless it lands in the same directory:

```bash
cd third_party/audio.cpp
python3 tools/model_manager_v2.py install minimax_music3_q4_0
```

## Requirements

- macOS 13.3 or newer. audio.cpp uses `std::to_chars` on floats, which libc++
  only exposes from 13.3; the app, the podspec and the CMake deployment target
  are all pinned there and must stay in step.
- Apple silicon for Metal acceleration. Intel Macs fall back to the CPU backend.
- CMake. Ninja is optional but much faster than make on this tree.

## Development

```bash
cd packages/audiocpp && flutter test    # 36 tests, incl. real native calls
cd audiocpp_flutter  && flutter test    # 83 tests, no dylib needed
cd packages/audiocpp && flutter analyze
cd audiocpp_flutter  && flutter analyze
```

The app's tests run on the Dart VM with no native library: `GenerationQueue`
takes a narrow `GenerationEngine` interface, and the tests supply a fake that
blocks on a gate. That is what makes queue ordering, retries, abandonment and
crash recovery testable when a real generation takes minutes.

After editing anything under `packages/audiocpp/src/`, re-run
`setup_macos.sh` (or just press F5) before testing. `flutter run` on its own
will not rebuild the native library and will silently keep using the old one.

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
  the offline session. `MiniMaxMusic3Session` is an `IOfflineVoiceTaskSession`
  — one blocking `run()` — and upstream's only callback mechanism
  (`StreamEventCallback`) is ASR-shaped: transcripts and partial audio, no step
  counter. Cancelling the running track therefore lets it finish and discards
  the result, which is what the UI says it does.
- Lyrics are required. MiniMax Music 3 declares them as a required request
  option, so the app has no instrumental mode; the form reads that from the
  spec rather than hardcoding it.
- Only `minimax_music3` is linked in. Add families via `AUDIOCPP_MODELS`; the
  build deliberately excludes the other ~49 to keep build time and size down.
  Linking one is necessary but not sufficient — see `supported_models.dart`.
