@TestOn('mac-os')
library;

import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the real dylib without needing a model on disk.
///
/// Skipped when the library has not been built, so a fresh checkout still has a
/// green test run; CI should build it first and let these fail loudly.
void main() {
  final libraryFile = File('macos/Libs/libaudiocpp_ffi.dylib');
  final libraryPath = libraryFile.existsSync() ? libraryFile.absolute.path : null;
  final skipReason = libraryPath == null
      ? 'libaudiocpp_ffi.dylib not built; run tool/build_macos.sh'
      : null;

  group('native library', () {
    late AudioCppEngine engine;

    setUp(() async {
      engine = await AudioCppEngine.start(libraryPath: libraryPath);
    });

    tearDown(() async {
      await engine.dispose();
    });

    test('enumerates at least the CPU device', () async {
      final devices = await engine.listDevices();

      expect(devices, isNotEmpty);
      expect(
        devices.map((AudioCppDevice d) => d.backend),
        contains('CPU'),
        reason: 'ggml always registers a CPU backend',
      );
    });

    test('reports the Metal device on Apple silicon', () async {
      final devices = await engine.listDevices();
      final backends = devices.map((AudioCppDevice d) => d.backend).toSet();

      // tool/build_macos.sh enables Metal on arm64 only, and ggml registers the
      // backend under the name "MTL" rather than "Metal".
      if (Platform.version.contains('arm64')) {
        expect(backends, contains('MTL'));
        expect(
          devices.firstWhere((AudioCppDevice d) => d.backend == 'MTL').type,
          'GPU',
        );
      }
    });

    test('surfaces a missing model as a native error, not a crash', () async {
      await expectLater(
        engine.loadModel(
          const ModelDescriptor(
            path: '/nonexistent/MiniMax-Music3-GGUF',
            family: MiniMaxMusic3Request.family,
          ),
        ),
        throwsA(isA<AudioCppNativeException>()),
      );
    });

    test('stays usable after a failed command', () async {
      await expectLater(
        engine.loadModel(const ModelDescriptor(path: '/nonexistent')),
        throwsA(isA<AudioCppException>()),
      );

      // The worker must survive a failed command rather than tearing down and
      // taking every other handle with it.
      expect(await engine.listDevices(), isNotEmpty);
    });

    test('rejects use after dispose', () async {
      await engine.dispose();

      expect(
        () => engine.listDevices(),
        throwsA(isA<AudioCppDisposedException>()),
      );
    });
  }, skip: skipReason);
}
