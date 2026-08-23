# Working in this repo

Flutter app over [audio.cpp](https://github.com/0xShug0/audio.cpp) (ggml-based
audio inference), integrated via Dart FFI. See `README.md` for setup.

## Layout

| Path | What it is |
|---|---|
| `third_party/audio.cpp` | Git submodule, pinned to **our fork** (`hazit90/audio.cpp`). Never edit in place — commit to a topic branch there and bump the pin. See "Working in the fork". |
| `packages/audiocpp/src/` | The C shim: `audiocpp_ffi.h` (ABI) + `audiocpp_ffi.cpp` + CMake. |
| `packages/audiocpp/macos/`, `ios/` | Per-platform pods. macOS vendors a dylib, iOS an xcframework of static slices. |
| `packages/audiocpp/windows/` | Flutter Windows plugin. Compiles nothing — it hands the prebuilt DLL to the runner via `audiocpp_bundled_libraries`. |
| `packages/audiocpp/lib/` | Dart: generated bindings, `NativeBridge`, worker isolate, typed API. |
| `audiocpp_flutter/lib/src/tracks/` | The app's core: `Track`, `TrackStore`, `GenerationQueue`, `GenerationEngine`. No widgets. |
| `audiocpp_flutter/lib/src/` | The app: `create/`, `library/`, `player/`, `models/` panes over that core. |
| `audiocpp_flutter/assets/model_specs/` | Curated by hand from `third_party/audio.cpp/model_specs/` — one file per family we support, not a copy of the lot. |

## Working in the fork

The submodule points at `hazit90/audio.cpp`, not upstream. Engine changes are
ours to make and ours to keep.

**Never open a PR or an issue against `0xShug0/audio.cpp`.** Changes are not
upstreamed, so do not treat carrying a patch as temporary or suggest a PR as the
way to stop carrying it. The submodule has an `upstream` remote for *fetching*
only.

**A pin must be pushed before it lands.** Bumping the superproject to a commit
that exists only locally leaves every other clone — CI included — unable to
resolve the submodule, and nothing surfaces that until someone tries. Push the
topic branch first, then bump.

**Keep the fork rebasable, because rebasing is now permanent.** `main` mirrors
upstream untouched, changes live on topic branches, and `external/` stays free
of local edits. Upstream moves fast (426 commits in the six months to the
current pin) but almost entirely in `external/ggml` and new model families, so
a patch confined to a model plus a couple of framework headers rebases for
nearly nothing. A local change under `external/` is what would end that.

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

Windows needs no export list and must not grow one. `__declspec(dllexport)` is
opt-in, so ggml's symbols never reach the DLL's export table in the first place
— do not reach for `WINDOWS_EXPORT_ALL_SYMBOLS`, which would undo exactly the
firewall the `.exports` file provides on macOS. `build_windows.ps1` runs the
equivalent check itself, reading the expected count out of the header:

```powershell
dumpbin /exports packages\audiocpp\windows\Libs\audiocpp_ffi.dll | Select-String 'audiocpp_'
```

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

**Windows is the macOS shape, not the iOS one.** A shared library built out of
band and loaded by absolute path. None of the iOS machinery applies — no
`-force_load`, no `-u` dead-strip roots, no libtool merge — because all of it
exists to work around *static* linking. Three things are load-bearing and each
is silent when wrong:

1. `/utf-8` is required, not cosmetic. `src/community_models/inflect_v2/frontend.cpp`
   has non-ASCII literals that MSVC otherwise decodes as the active code page.
2. `/openmp:experimental` is required. MSVC's default `/openmp` implements only
   OpenMP 2.0 and rejects the code. macOS passes `ENGINE_ENABLE_OPENMP=OFF`
   solely because Apple clang ships no libomp; that reason does not apply here.
3. `AUDIOCPP_MODELS` lives in *every* build script now. Adding a model family
   means editing `build_macos.sh`, `build_windows.ps1` and `build_ios.sh`.

**Never build a `std::filesystem::path` from a `const char *` in the shim.** Use
`to_path()` in `audiocpp_ffi.cpp`. The ABI says its strings are UTF-8 and every
Dart caller honours that, but MSVC's narrow `path` constructor decodes using the
active code page instead — so a single non-ASCII character in a Windows account
name silently breaks model loading and WAV export, because every model and track
path is rooted at the user's profile directory.

**Windows CPU flags are tuned for Intel Core Ultra, and one of them is a trap.**
`GGML_AVX_VNNI=ON` is the big win and is *not* in ggml's `INS_ENB` default
group, so it only happens if asked. `GGML_AVX512` must stay OFF: no Core Ultra
part has AVX-512 — Intel disabled it across the hybrid P-core/E-core designs —
so it looks like an upgrade and produces a binary that faults on the target
machine. Note that enabling VNNI bakes the intrinsics in with no runtime check,
making Alder Lake / Zen 5 a hard floor; `build_windows.ps1 -NoVnni` opts out.

**Thread count is not a core count on a hybrid CPU.** ggml synchronises workers
at every graph node with a spin barrier, so a graph runs at the speed of its
slowest thread and an E-core gates every node. `lib/src/platform/cpu_topology.dart`
asks Windows for the per-core efficiency class and uses only the fastest class.
It fails soft to the old heuristic, and `AUDIOCPP_THREADS` overrides it — which
is the honest way to tune, since the right number is measurable.

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
thread-safe. Discarding a running track removes it from the store at once and
calls `audiocpp_cancel_request`, and `isFinishingDiscarded` covers the gap until
the run unwinds -- the track is gone, but the machine is not free yet.

Cancellation is honoured *between units of work*, never mid-step. Measured on an
M1 Max with q4_0: 67ms in the autoregressive phase, 122ms 180s into a run, 148ms
during the weight upload. Not at all once a run is past its last check — which
is the only case `isStopping` exists for, and why it stays quiet for
`stopGrace` first. A strip that appears and vanishes inside 150ms is a glitch,
not information. So `_abandoned` stays as the backstop, the UI says
"stops at the end of the current step" rather than implying instant, and a
cancelled run is `AUDIOCPP_CANCELLED` / `GenerationCancelled` -- never a
failure, or the user gets an error they caused on purpose.

**The bar is measured, and the rules that keep it honest.**
`audiocpp_progress_query` returns a phase, a position inside it, and a serial
identifying the run; `GenerationQueue` polls it on the ticker it already runs.
Three things about turning that into a bar are easy to get wrong.

It weights each phase by measured cost rather than counting units. AR is
thousands of cheap frames and a fifth of a run, flow is three quarters of it in a
fraction of the units, and those shares move with `inferenceSteps` -- 18/76/5 at
30 steps, 10/86/3 at 60 -- so they can never be stored as fractions. It only
moves forward: when a phase costs more than predicted the finished segments stay
put and the error goes into the estimate, because a bar that rewinds reads as a
bug. And a reading whose serial is not this run's is dropped, or the tail of the
previous run renders as the opening of this one.

Rates live in `phase_rates.dart`, persisted per model package, seeded from an
M1 Max. Shipping one machine's numbers is deliberate: the ratio between phases
belongs to the model, while the absolute scale corrects itself from the run in
flight within seconds. The alternative -- what this replaced -- was no estimate
at all until a first run had finished, and one that was ~25% short when it came.

The weight upload reports no phase, so the first seconds of a run are still
indeterminate.

**Loading a model is free; the weights arrive inside `generate()`.**
`registry.load` reads specs and opens files and measures 0s. The gigabytes land
lazily when `ensure_ar` and friends build a component, and `mem_saver` (on by
default) resets those components after each phase — so the language model is
re-read at the start of *every* generation, not once. `BackendWeightStore`
checks for cancellation per tensor because of this, reached through a flag on
`ExecutionContext`, which is the only thing every weight builder already holds.

`audiocpp_model_load` itself still cannot be interrupted, and `_run` asks
`_abandoned` once more after it: the engine clears its flag when a run starts,
so a discard during the load would otherwise be erased and the generation would
go ahead in full.

**Disposing cancels first.** A run owns the worker isolate, so every teardown
command queues behind it: without this, closing the app mid-generation waits out
`AudioCppEngine.dispose`'s 30s timeout and then kills an isolate still inside a
native call. Both `GenerationQueue.dispose` and `AudioCppEngine.dispose` ask for
a stop before tearing anything down.

**The cancel call must not be a worker command.** The worker isolate is blocked
inside `audiocpp_session_run` for the whole generation, so a `WorkerCommand`
would sit in its queue until the very run it was meant to stop had finished.
`AudioCppEngine.requestCancel` therefore calls the library directly from the
calling isolate. That is sound because Dart statics are per-isolate but `dlopen`
is not: a second `AudioCppLibrary` handle resolves to the same loaded image, so
both isolates see the same `RunControl` in the shim. Nothing is shared
across the port, so the no-pointers-across-isolates rule still holds.

`audiocpp_progress_query` is read the same way and for the same reason, which is
also why progress is polled rather than pushed: a callback would be delivered to
the isolate blocked inside the run and arrive after the run it described.

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

A store mutation *started by a tap* needs both, alternating. The tap runs in the
faked-time zone, so everything after the store's `await` on a file write only
resumes on a `pump()` — while the write itself only progresses inside
`runAsync`. One of each is not enough and fails in a way that looks like a
missing `notifyListeners()`: `store.tracks` is already correct, because `remove`
mutates the list before its first `await`, yet no notification ever fires and
the pane renders stale. `settle()` in `library_pane_test.dart` is the loop.

## After editing the C header

```bash
cd packages/audiocpp
dart run ffigen --config ffigen.yaml   # regenerate bindings (committed)
./tool/setup_macos.sh                  # rebuild the dylib (F5 does this too)
flutter test
```

`./tool/setup_ios.sh` is the iOS twin, same staleness contract. It builds a
device slice only; `SIMULATOR=1` adds a simulator one.
`.\tool\setup_windows.ps1` is the Windows twin, and needs a Visual Studio
Developer PowerShell so `cl.exe` is on PATH — it checks and says so rather than
failing inside CMake.

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
