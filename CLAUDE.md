# Working in this repo

Flutter app over [audio.cpp](https://github.com/0xShug0/audio.cpp) (ggml-based
audio inference), integrated via Dart FFI. See `README.md` for setup.

## Layout

| Path | What it is |
|---|---|
| `third_party/audio.cpp` | Git submodule, pinned. **Never edit** — changes here are lost on update. Patch upstream or work around it in the shim. |
| `packages/audiocpp/src/` | The C shim: `audiocpp_ffi.h` (ABI) + `audiocpp_ffi.cpp` + CMake. |
| `packages/audiocpp/macos/`, `ios/` | Per-platform pods. macOS vendors a dylib, iOS an xcframework of static slices. |
| `packages/audiocpp/lib/` | Dart: generated bindings, `NativeBridge`, worker isolate, typed API. |
| `audiocpp_flutter/lib/src/tracks/` | The app's core: `Track`, `TrackStore`, `GenerationQueue`, `GenerationEngine`. No widgets. |
| `audiocpp_flutter/lib/src/` | The app: `create/`, `library/`, `player/`, `models/` panes over that core. |
| `audiocpp_flutter/assets/model_specs/` | Curated by hand from `third_party/audio.cpp/model_specs/` — one file per family we support, not a copy of the lot. |

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

**iOS links the shim statically, and four things conspire to break that.**
Each is silent -- the app builds clean and fails on device -- so all four live
in `ios/audiocpp.podspec` with the reason written next to them:

1. Dart reaches the entry points through `dlsym`, so nothing references them at
   link time and the linker never pulls them out of the archive. `-force_load`.
2. Release then dead-strips what `-force_load` just brought in, for the same
   reason. `-Wl,-u,_<symbol>` per entry point makes each a dead-strip root; the
   podspec reads the list out of the header so a new `AUDIOCPP_API` function
   cannot silently go missing.
3. `-dead_strip` *also* removes the embedded model-spec table, which no `-u`
   flag reaches (212 spec strings in a debug build, 0 in release, every model
   load failing with "spec not found"). Hence `DEAD_CODE_STRIPPING = NO`.
   The macOS dylib escapes all of this only because CMake does not pass
   `-dead_strip` when linking a shared library.
4. An `OTHER_LDFLAGS[sdk=...]` line *replaces* the unconditional one instead of
   adding to it, silently dropping every other pod's flags. Only the slice name
   is SDK-conditional; `OTHER_LDFLAGS` itself stays plain.

`-force_load` points into the vendored xcframework rather than the copy
CocoaPods unpacks: Xcode validates the app target's linker inputs before the
pod's copy phase runs.

**A model has to fit in an iOS process, and MiniMax Music 3 does not.**
Loading q4_0 on device fails with `std::bad_alloc`: 7.9 GB across five GGUFs,
5.6 GB of it the language model alone, and the weights are real backend buffers
-- `gguf_init_from_file` then `ggml_backend_alloc_ctx_tensors`, with no
llama.cpp-style mmap path to fall back on. q4_0 is the smallest package
upstream publishes. Raising the ceiling needs
`com.apple.developer.kernel.increased-memory-limit` and
`extended-virtual-addressing` in a `Runner.entitlements`, which a **free
personal team cannot sign** -- Xcode refuses the profile outright. Everything
else in the iOS port works; this is the only thing standing between the app and
a generated track.

**Bump the ABI version on a breaking change.** `AUDIOCPP_FFI_ABI_VERSION_MAJOR`
in the header and `AudioCppLibrary.expectedAbiMajor` in
`lib/src/ffi/library.dart` must match, so a stale dylib fails loudly instead of
corrupting memory.

**The dylib must exist before `pod install`.** `vendored_libraries` is a glob
CocoaPods resolves at install time. If it runs while the file is absent, the
Pods project simply has no reference to it and later builds succeed without it
-- failing only at runtime. `build_macos.sh` therefore deletes
`audiocpp_flutter/macos/Pods/Manifest.lock` after producing the dylib, which is
what makes Flutter re-run `pod install` and re-resolve the glob.

## Rules that matter in the app

**Availability is a decision, not a discovery.** A family works only when three
things agree: it is linked (`AUDIOCPP_MODELS`), its spec is in
`assets/model_specs/`, and the Create pane can build its request. The set in
`lib/src/models/supported_models.dart` is the list a person reads; do all three
or add none. Offering a multi-gigabyte download for a family that cannot load is
worse than not listing it.

**Ask the spec, don't hardcode the model's rules.** MiniMax Music 3 declares
`lyrics` as a required request option, and the form reads that to decide whether
an instrumental mode exists. New per-family behaviour belongs in the spec lookup
next to it, not in a widget's `if`.

**One generation at a time, and no faking progress.** `GenerationQueue` drains
serially because the session holds gigabytes and the handles are not
thread-safe. The ABI has no cancellation, so cancelling a running track marks it
abandoned and discards the result when it lands — say that in the UI rather than
implying a stop. There is no step callback either: elapsed time and an
extrapolated estimate are all we can honestly show.

**Widgets never touch native handles or block.** Anything long-running goes
through `GenerationQueue`, which talks to the narrow `GenerationEngine`
interface. Keep that interface narrow: it is what lets the whole queue be tested
on the Dart VM with no dylib.

**`Size.fromHeight` / `Size.fromWidth` leave the other axis at infinity.** Both
have shipped bugs here — a button in a `Row` and a button in a `ListView`, each
blanking its whole pane. Get full width from a `SizedBox`, not a `minimumSize`.

**Widget tests: `pump()` does not advance real time.** The store does file I/O,
so a test must `await tester.runAsync(...)` for that work to finish, then
`pump()`. Tap in the normal zone — gestures need the test binding's clock and do
not dispatch inside `runAsync`. And never `pumpAndSettle()` while the queue is
running: the indeterminate progress bar animates forever.

## After editing the C header

```bash
cd packages/audiocpp
dart run ffigen --config ffigen.yaml   # regenerate bindings (committed)
./tool/setup_macos.sh                  # rebuild the dylib (F5 does this too)
flutter test
```

`./tool/setup_ios.sh` is the iOS twin, same staleness contract. It builds a
device slice only; `SIMULATOR=1` adds a simulator one.

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
- iOS deployment target `16.3` — the same libc++ `std::to_chars` gate as macOS
  13.3. Must match `build_ios.sh`, the iOS podspec, the Podfile's
  `platform :ios` and `IPHONEOS_DEPLOYMENT_TARGET`.
- `ENGINE_ENABLE_NATIVE_CPU=OFF` on iOS — host ISA flags are meaningless when
  cross-compiling.

## Gotchas found the hard way

- ggml registers the Metal backend under the name `MTL`, not `Metal`.
- sentencepiece's `if (CMAKE_SYSTEM_NAME STREQUAL "iOS")` branch calls
  `set_xcode_property()`, a macro only the third-party `ios.toolchain.cmake`
  defines. We use CMake's own iOS support, so `src/CMakeLists.txt` defines a
  no-op macro before `add_subdirectory` — everything it touches is an `spm_*`
  tool we never build.
- CocoaPods derives a vendored static library's `-l` flag by stripping a leading
  `lib`, so the merged archive must be named `libaudiocpp_ffi.a`. It also
  de-duplicates `OTHER_LDFLAGS` tokens, which collapses eighteen `-u _sym`
  flags into one — `-Wl,-u,_sym` keeps them distinct.
- A CMake `STATIC` target does not absorb the libraries it links, so
  `build_ios.sh` merges every archive the build produced with `libtool`.
- The vendored dylib lands in `<App>.app/Contents/Frameworks/` but nothing links
  it into the executable, so `DynamicLibrary.process()` cannot see it and a bare
  `dlopen` name does not search `@rpath`. `library.dart` resolves it absolutely
  from `Platform.resolvedExecutable`.
- The build script is deliberately *not* a podspec `script_phase`: compiling ggml
  takes minutes and Xcode would re-run it on every incremental Flutter build.
