import 'package:meta/meta.dart';

import 'ffi/audiocpp_bindings.g.dart' show audiocpp_status;

/// Base class for every failure raised by `package:audiocpp`.
@immutable
sealed class AudioCppException implements Exception {
  const AudioCppException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The native library could not be located or opened.
///
/// Almost always means `packages/audiocpp/tool/build_macos.sh` has not been run,
/// or the app bundle was built before the dylib existed.
final class AudioCppLibraryNotFoundException extends AudioCppException {
  const AudioCppLibraryNotFoundException(super.message, {this.searchedPaths = const []});

  /// Paths that were tried, in order, for inclusion in bug reports.
  final List<String> searchedPaths;
}

/// The loaded dylib reports an ABI major version this package cannot talk to.
final class AudioCppAbiMismatchException extends AudioCppException {
  const AudioCppAbiMismatchException({
    required this.expectedMajor,
    required this.actualMajor,
  }) : super(
          'libaudiocpp_ffi reports ABI major version $actualMajor, but this '
          'package was generated against $expectedMajor. Rebuild the native '
          'library with tool/build_macos.sh.',
        );

  final int expectedMajor;
  final int actualMajor;
}

/// A native call returned a non-OK status.
///
/// [message] carries the engine's own error text, which is usually far more
/// specific than [status] (missing GGUF component, unsupported option, and so
/// on), so prefer it when surfacing failures to a user.
final class AudioCppNativeException extends AudioCppException {
  const AudioCppNativeException(this.status, super.message);

  final audiocpp_status status;

  @override
  String toString() => 'AudioCppNativeException(${status.name}): $message';
}

/// A handle was used after it, or its owner, was disposed.
final class AudioCppDisposedException extends AudioCppException {
  const AudioCppDisposedException(super.message);
}
