import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MiniMaxMusic3Request', () {
    test('puts the caption in text and the lyrics in options', () {
      final request = MiniMaxMusic3Request(
        caption: 'A bright pop rock song.',
        lyrics: '[verse] City lights are shining low.',
      );

      // The engine reads the caption as the session's text input and the lyrics
      // as a request option; swapping them silently produces garbage.
      expect(request.text, 'A bright pop rock song.');
      expect(request.options['lyrics'], '[verse] City lights are shining low.');
    });

    test('emits the documented defaults', () {
      final request = MiniMaxMusic3Request(caption: 'caption', lyrics: 'lyrics');

      expect(request.options['duration_sec'], '20');
      expect(request.options['num_inference_steps'], '30');
      expect(request.options['guidance_scale'], '1.7');
      expect(request.options['ar_guidance_scale'], '1.5');
      expect(request.options['top_k'], '50');
      expect(request.options['seed'], '0');
    });

    test('serialises overridden values', () {
      final request = MiniMaxMusic3Request(
        caption: 'caption',
        lyrics: 'lyrics',
        durationSeconds: 45,
        inferenceSteps: 12,
        guidanceScale: 0,
        arGuidanceScale: 0,
        topK: 100,
        seed: 4242,
      );

      expect(request.options['duration_sec'], '45');
      expect(request.options['num_inference_steps'], '12');
      // 0 selects the non-CFG path, so it must survive as "0.0", not vanish.
      expect(request.options['guidance_scale'], '0.0');
      expect(request.options['ar_guidance_scale'], '0.0');
      expect(request.options['top_k'], '100');
      expect(request.options['seed'], '4242');
    });

    test('extraOptions can add keys but not silently drop the required ones', () {
      final request = MiniMaxMusic3Request(
        caption: 'caption',
        lyrics: 'lyrics',
        extraOptions: const {'some_future_option': 'value'},
      );

      expect(request.options['some_future_option'], 'value');
      expect(request.options['lyrics'], 'lyrics');
    });

    test('rejects out-of-range parameters', () {
      expect(
        () => MiniMaxMusic3Request(caption: 'c', lyrics: 'l', durationSeconds: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MiniMaxMusic3Request(caption: 'c', lyrics: 'l', inferenceSteps: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MiniMaxMusic3Request(caption: 'c', lyrics: 'l', topK: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MiniMaxMusic3Request(caption: 'c', lyrics: 'l', guidanceScale: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('componentOverrides omits unset entries', () {
      expect(MiniMaxMusic3Request.componentOverrides(), isEmpty);

      final overrides = MiniMaxMusic3Request.componentOverrides(
        languageModelGguf: 'language_model_q8_0.gguf',
        memorySaver: false,
      );

      expect(overrides, {
        'minimax_music3.language_model_gguf': 'language_model_q8_0.gguf',
        'minimax_music3.mem_saver': 'false',
      });
    });

    test('exposes the family and task the registry expects', () {
      expect(MiniMaxMusic3Request.family, 'minimax_music3');
      expect(MiniMaxMusic3Request.task, AudioCppTask.audioGeneration);
    });
  });
}
