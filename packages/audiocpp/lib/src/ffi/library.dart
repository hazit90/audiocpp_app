import 'dart:ffi';
import 'dart:io';

import '../exceptions.dart';
import 'audiocpp_bindings.g.dart';

/// Resolves and opens `libaudiocpp_ffi`, and verifies its ABI.
///
/// Loading is idempotent per isolate: [instance] caches the opened library, so
/// the worker isolate pays the resolution cost once.
abstract final class AudioCppLibrary {
  /// Must match `AUDIOCPP_FFI_ABI_VERSION_MAJOR` in `audiocpp_ffi.h`.
  static const int expectedAbiMajor = 1;

  /// Environment variable checked first, so tests and CLI tools can point at a
  /// build directory without installing the dylib anywhere.
  static const String pathEnvironmentVariable = 'AUDIOCPP_FFI_LIBRARY_PATH';

  /// Set before the first [instance] access to load a specific binary.
  /// Intended for tests; app code should rely on the bundled library.
  static String? overridePath;

  static AudioCppBindings? _instance;

  static AudioCppBindings get instance => _instance ??= _open();

  static AudioCppBindings _open() {
    final searched = <String>[];
    final bindings = _tryCandidates(searched);
    if (bindings == null) {
      throw AudioCppLibraryNotFoundException(
        'Could not open libaudiocpp_ffi. Build it with '
        'packages/audiocpp/tool/build_macos.sh, or set '
        '$pathEnvironmentVariable to an existing binary.',
        searchedPaths: searched,
      );
    }

    final actualMajor = bindings.audiocpp_abi_version_major();
    if (actualMajor != expectedAbiMajor) {
      throw AudioCppAbiMismatchException(
        expectedMajor: expectedAbiMajor,
        actualMajor: actualMajor,
      );
    }
    return bindings;
  }

  static AudioCppBindings? _tryCandidates(List<String> searched) {
    for (final candidate in _candidatePaths()) {
      searched.add(candidate);
      try {
        // 'process' is not a path; it looks up symbols already linked into the
        // running executable, which is how the CocoaPods-vendored dylib is
        // reachable inside a built .app bundle.
        final library =
            candidate == _processSentinel ? DynamicLibrary.process() : DynamicLibrary.open(candidate);
        final bindings = AudioCppBindings(library);
        // Probing a cheap symbol turns "wrong library entirely" into a clean
        // failure here rather than a crash on the first real call.
        bindings.audiocpp_abi_version_major();
        return bindings;
      } on ArgumentError {
        continue;
      } on Object {
        continue;
      }
    }
    return null;
  }

  static const String _processSentinel = ':process:';

  /// Path to the copy embedded in the running app bundle, or null when the
  /// process is not running from one (tests, `dart run`).
  static String? _bundledLibraryPath() {
    final executableDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Frameworks/
      return '${executableDir.parent.path}/Frameworks/libaudiocpp_ffi.dylib';
    }
    if (Platform.isWindows) {
      return '${executableDir.path}\\audiocpp_ffi.dll';
    }
    return '${executableDir.path}/lib/libaudiocpp_ffi.so';
  }

  static Iterable<String> _candidatePaths() sync* {
    final override = overridePath;
    if (override != null) {
      yield override;
    }

    final fromEnvironment = Platform.environment[pathEnvironmentVariable];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      yield fromEnvironment;
    }

    // Inside a packaged app the dylib sits next to the other embedded
    // frameworks. Resolve it absolutely: nothing links it into the executable,
    // so DynamicLibrary.process() cannot see it, and a bare dlopen name does
    // not search the executable's @rpath.
    final bundled = _bundledLibraryPath();
    if (bundled != null) {
      yield bundled;
    }

    yield _processSentinel;

    if (Platform.isMacOS) {
      yield 'libaudiocpp_ffi.dylib';
      // Where tool/build_macos.sh installs it, relative to a repo-root cwd.
      yield 'packages/audiocpp/macos/Libs/libaudiocpp_ffi.dylib';
    } else if (Platform.isWindows) {
      yield 'audiocpp_ffi.dll';
    } else {
      yield 'libaudiocpp_ffi.so';
    }
  }
}
