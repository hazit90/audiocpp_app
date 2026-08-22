@TestOn('mac-os')
library;

import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads a real MiniMax Music 3 package through the FFI layer.
///
/// Opt-in, because it needs a multi-gigabyte model on disk:
///
/// ```bash
/// AUDIOCPP_TEST_MODEL_PATH=/path/to/MiniMax-Music3-GGUF flutter test \
///   test/minimax_music3_integration_test.dart
/// ```
///
/// Everything else in this package is tested against fakes or the empty
/// engine. This is the only test that proves the C shim survives contact with
/// actual weights, so it is worth running by hand after any ABI change.
void main() {
  final modelPath = Platform.environment['AUDIOCPP_TEST_MODEL_PATH'];
  final libraryFile = File('macos/Libs/libaudiocpp_ffi.dylib');

  String? resolveSkip() {
    if (modelPath == null || modelPath.isEmpty) {
      return 'set AUDIOCPP_TEST_MODEL_PATH to a model package directory';
    }
    if (!Directory(modelPath).existsSync()) {
      return 'AUDIOCPP_TEST_MODEL_PATH does not exist: $modelPath';
    }
    if (!libraryFile.existsSync()) {
      return 'libaudiocpp_ffi.dylib not built; run tool/build_macos.sh';
    }
    return null;
  }

  final skip = resolveSkip();

  group('MiniMax Music 3 against real weights', () {
    late AudioCppEngine engine;
    late AudioCppModel model;

    setUpAll(() async {
      engine = await AudioCppEngine.start(
        libraryPath: libraryFile.absolute.path,
      );
      model = await engine.loadModel(
        ModelDescriptor(
          path: modelPath!,
          family: MiniMaxMusic3Request.family,
        ),
      );
    });

    tearDownAll(() async {
      await engine.dispose();
    });

    test('the registry resolves the package to the right family', () {
      expect(model.family, 'minimax_music3');
    });

    test('the model advertises offline audio generation', () {
      expect(model.supportsTask(AudioCppTask.audioGeneration), isTrue);
      expect(model.supportedTasks, contains(AudioCppTask.audioGeneration));
    });

    test('a Metal generation session can be created', () async {
      final session = await model.createSession(
        const SessionConfig(
          task: AudioCppTask.audioGeneration,
          backend: AudioCppBackend.bestAvailable,
          threads: 6,
        ),
      );

      expect(session, isNotNull);
      await session.dispose();
    });

    test('a session for an unsupported task fails cleanly', () async {
      // The engine must reject this rather than crash the worker isolate; a
      // hard crash here would take the whole app down in production.
      await expectLater(
        model.createSession(const SessionConfig(task: AudioCppTask.asr)),
        throwsA(isA<AudioCppException>()),
      );

      // The worker must still be usable afterwards.
      expect(await engine.listDevices(), isNotEmpty);
    });
  }, skip: skip);
}
