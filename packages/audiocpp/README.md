# package:audiocpp

Dart FFI bindings for [audio.cpp](https://github.com/0xShug0/audio.cpp), the
ggml-based audio inference engine, with a typed API for running MiniMax Music 3.

## Why there is a C shim

audio.cpp exposes only C++: `std::filesystem::path`, `std::optional`,
`std::unordered_map`, and virtual interfaces such as
`engine::runtime::IOfflineVoiceTaskSession`. Dart FFI cannot bind to any of
that, so this package owns a narrow C ABI over it:

```
src/include/audiocpp_ffi.h   the ABI (opaque handles, int32 status codes)
src/audiocpp_ffi.cpp         wraps the C++ engine; no exception escapes
src/CMakeLists.txt           builds it into libaudiocpp_ffi.dylib
lib/src/ffi/*.g.dart         ffigen output from the header
lib/src/native/              synchronous driver; owns every native handle
lib/src/engine/              worker isolate + async public API
```

The shim is the only thing that has to change when audio.cpp's C++ moves. The
Dart layers above it are insulated.

## Layout of the Dart API

`AudioCppEngine` spawns one worker isolate and keeps *all* native handles inside
it. Nothing crosses the isolate boundary except plain data and integer handle
ids — never a raw `Pointer`. This matters for two reasons:

- Model loading and generation block for minutes. On the main isolate that would
  freeze the UI.
- The C ABI declares handles as not thread-safe. Confining them to one isolate
  makes that structurally true rather than a convention.

The cost: commands run strictly in order, so a long generation delays anything
queued behind it, including `dispose`.

## Building the native library

```bash
./tool/build_macos.sh
```

Produces `macos/Libs/libaudiocpp_ffi.dylib`, which the CocoaPods podspec vendors
into the app bundle. The dylib is gitignored — every developer builds their own.

| Variable | Default | Notes |
|---|---|---|
| `BUILD_TYPE` | `Release` | |
| `AUDIOCPP_MODELS` | `minimax_music3` | Semicolon-separated. Only linked families can be loaded. |
| `ENABLE_METAL` | `ON` on arm64 | |
| `DEPLOYMENT_TARGET` | `13.3` | See below. |
| `JOBS` | CPU count | |
| `CLEAN` | `0` | `1` drops the CMake cache first. |

Two build settings are load-bearing:

- **`CMAKE_OSX_DEPLOYMENT_TARGET=13.3`.** audio.cpp calls `std::to_chars` on
  floats in `src/framework/debug/trace.cpp`, which libc++ only exposes from
  macOS 13.3. Lower targets fail to compile. The host app's deployment target
  must be at least as high.
- **`AUDIOCPP_DEPLOYMENT_BUILD=ON`** (forced in `src/CMakeLists.txt`). Without
  it the engine resolves `model_specs/<family>.json` by walking up from the
  model directory and the process working directory — neither of which is
  dependable inside a packaged `.app`. This compiles the spec catalog in.

`AUDIOCPP_MODEL_SET=custom` keeps the binary to the families we ship. Building
all ~50 costs build time and size for nothing.

## Usage

```dart
final engine = await AudioCppEngine.start();

final model = await engine.loadModel(const ModelDescriptor(
  path: '/path/to/MiniMax-Music3-GGUF',
  family: MiniMaxMusic3Request.family,
));

final session = await model.createSession(const SessionConfig(
  task: AudioCppTask.audioGeneration,
  backend: AudioCppBackend.metal,
  threads: 8,
));

final audio = await session.run(MiniMaxMusic3Request(
  caption: 'A bright pop rock song with clean drums and a clear female vocal.',
  lyrics: '[verse] City lights are shining low. [chorus] Sing the melody tonight.',
  durationSeconds: 30,
));

await audio.writeWav('/tmp/song.wav');

await audio.dispose();
await session.dispose();
await model.dispose();
await engine.dispose();
```

`writeWav` uses audio.cpp's own WAV writer, so the samples never travel through
the Dart heap. Use `readSamples()` only when you actually need the floats — it
copies the whole buffer.

Disposing the engine releases everything it still holds, so shutdown does not
require unwinding by hand.

## Getting a model

```bash
cd third_party/audio.cpp
python3 tools/model_manager_v2.py install minimax_music3_q4_0
```

Point `ModelDescriptor.path` at the resulting `MiniMax-Music3-GGUF` directory.

## Regenerating the bindings

After editing `src/include/audiocpp_ffi.h`:

```bash
dart run ffigen --config ffigen.yaml
```

The generated file is committed so consumers do not need libclang to build.

Bump `AUDIOCPP_FFI_ABI_VERSION_MAJOR` in the header on a breaking change and
`AudioCppLibrary.expectedAbiMajor` in `lib/src/ffi/library.dart` to match — a
stale dylib then fails with a clear `AudioCppAbiMismatchException` instead of
corrupting memory.

## Known limitations

- **macOS only.** The C ABI and CMake are portable; only the platform packaging
  (podspec, build script) is macOS-specific.
- **No cancellation.** audio.cpp exposes no cancel hook on the offline session,
  so a started generation runs to completion.
- **No progress reporting.** Same reason.
- **Offline mode only.** `RunMode::Streaming` needs a pull/callback design the
  ABI would have to grow deliberately. MiniMax Music 3 is offline-only anyway.
