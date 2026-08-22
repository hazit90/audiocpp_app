# Working in this repo

Flutter app over [audio.cpp](https://github.com/0xShug0/audio.cpp) (ggml-based
audio inference), integrated via Dart FFI. See `README.md` for setup.

## Layout

| Path | What it is |
|---|---|
| `third_party/audio.cpp` | Git submodule, pinned. **Never edit** — changes here are lost on update. Patch upstream or work around it in the shim. |
| `packages/audiocpp/src/` | The C shim: `audiocpp_ffi.h` (ABI) + `audiocpp_ffi.cpp` + CMake. |
| `packages/audiocpp/lib/` | Dart: generated bindings, `NativeBridge`, worker isolate, typed API. |
| `audiocpp_flutter/` | The app. |

## Rules that matter

**Never let a C++ exception cross the C boundary.** Every entry point in
`audiocpp_ffi.cpp` routes through `guard()`, which catches and maps to an
`audiocpp_status` plus a thread-local message. New entry points do the same.

**Enum-typed values never cross the ABI.** Enum width is implementation-defined,
so struct fields, parameters and return values use `int32_t` with the enum named
in a comment. Keep it that way — a width mismatch corrupts silently.

**Native handles stay on the worker isolate.** Never send a `Pointer` across an
isolate port. Add work as a `WorkerCommand` in `lib/src/engine/protocol.dart`.

**Keep the export list tight.** `src/audiocpp_ffi.exports` is what actually keeps
ggml's ~2500 symbols out of the dylib; the CMake visibility presets only reach
our own sources. Verify after ABI changes:

```bash
nm -gU packages/audiocpp/macos/Libs/libaudiocpp_ffi.dylib | grep -c ' T '
```

It should equal the number of `AUDIOCPP_API` functions.

**Bump the ABI version on a breaking change.** `AUDIOCPP_FFI_ABI_VERSION_MAJOR`
in the header and `AudioCppLibrary.expectedAbiMajor` in
`lib/src/ffi/library.dart` must match, so a stale dylib fails loudly instead of
corrupting memory.

## After editing the C header

```bash
cd packages/audiocpp
dart run ffigen --config ffigen.yaml   # regenerate bindings (committed)
./tool/build_macos.sh                  # rebuild the dylib
flutter test
```

## Build settings that are load-bearing

- `CMAKE_OSX_DEPLOYMENT_TARGET=13.3` — audio.cpp calls `std::to_chars` on floats;
  libc++ only exposes it from 13.3. Must match the app's target, the Podfile's
  `platform :osx`, and `MACOSX_DEPLOYMENT_TARGET` in the Xcode project.
- `AUDIOCPP_DEPLOYMENT_BUILD=ON` — compiles `model_specs/*.json` into the
  runtime. Without it the engine resolves specs by walking up from the model dir
  and the cwd, neither of which is dependable inside a `.app`.
- `AUDIOCPP_MODEL_SET=custom` + `AUDIOCPP_MODELS` — only linked families can be
  loaded. Adding a model means adding it here and rebuilding.
- `ENGINE_ENABLE_OPENMP=OFF` — macOS clang ships no libomp by default.

## Gotchas found the hard way

- ggml registers the Metal backend under the name `MTL`, not `Metal`.
- The vendored dylib lands in `<App>.app/Contents/Frameworks/` but nothing links
  it into the executable, so `DynamicLibrary.process()` cannot see it and a bare
  `dlopen` name does not search `@rpath`. `library.dart` resolves it absolutely
  from `Platform.resolvedExecutable`.
- The build script is deliberately *not* a podspec `script_phase`: compiling ggml
  takes minutes and Xcode would re-run it on every incremental Flutter build.
