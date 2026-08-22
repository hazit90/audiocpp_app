import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('native enum values', () {
    // These must match engine::core::BackendType and
    // engine::runtime::VoiceTaskKind. A silent drift here would route work to
    // the wrong backend or task rather than fail loudly, so pin them.
    test('AudioCppBackend matches the C ABI ordering', () {
      expect(AudioCppBackend.cpu.nativeValue, 0);
      expect(AudioCppBackend.cuda.nativeValue, 1);
      expect(AudioCppBackend.hip.nativeValue, 2);
      expect(AudioCppBackend.vulkan.nativeValue, 3);
      expect(AudioCppBackend.metal.nativeValue, 4);
      expect(AudioCppBackend.bestAvailable.nativeValue, 5);
    });

    test('AudioCppTask matches the C ABI ordering', () {
      expect(AudioCppTask.vad.nativeValue, 0);
      expect(AudioCppTask.asr.nativeValue, 1);
      expect(AudioCppTask.audioGeneration.nativeValue, 4);
      expect(AudioCppTask.tts.nativeValue, 5);
      expect(AudioCppTask.midi.nativeValue, 13);
    });

    test('every enumerator is declared in index order', () {
      for (var i = 0; i < AudioCppTask.values.length; i++) {
        expect(AudioCppTask.values[i].nativeValue, i);
      }
      for (var i = 0; i < AudioCppBackend.values.length; i++) {
        expect(AudioCppBackend.values[i].nativeValue, i);
      }
    });
  });

  group('SessionConfig', () {
    test('rejects a non-positive thread count', () {
      expect(
        () => SessionConfig(task: AudioCppTask.audioGeneration, threads: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a negative device index', () {
      expect(
        () => SessionConfig(task: AudioCppTask.audioGeneration, device: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('defaults to letting ggml choose the device', () {
      const config = SessionConfig(task: AudioCppTask.audioGeneration);
      expect(config.backend, AudioCppBackend.bestAvailable);
      expect(config.device, 0);
      expect(config.threads, 4);
    });
  });

  group('AudioCppDevice', () {
    test('renders the selector the CLI documents', () {
      const device = AudioCppDevice(
        backend: 'Metal',
        index: 0,
        name: 'Apple M3 Pro',
        type: 'GPU',
      );
      expect(device.toString(), 'Metal:0 "Apple M3 Pro" [GPU]');
    });
  });
}
