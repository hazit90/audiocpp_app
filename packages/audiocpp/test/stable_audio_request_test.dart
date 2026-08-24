import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StableAudio3Request', () {
    test('puts the prompt in text, not in an option', () {
      final request = StableAudio3Request(prompt: 'uplifting house music');

      // The engine prefers request.text_input and only falls back to a `prompt`
      // option, so sending it as text is what keeps the two paths from
      // disagreeing.
      expect(request.text, 'uplifting house music');
      expect(request.options.containsKey('prompt'), isFalse);
    });

    test('emits the engine defaults, which are not MiniMax defaults', () {
      final request = StableAudio3Request(prompt: 'prompt');

      // 8 steps and guidance 1.0, against MiniMax's 30 and 1.7. Carrying the
      // other family's numbers over is the mistake this guards.
      expect(request.options['num_inference_steps'], '8');
      expect(request.options['guidance_scale'], '1.0');
      expect(request.options['duration_seconds'], '30');
      expect(request.options['seed'], '0');
    });

    test('omits a blank negative prompt rather than sending an empty one', () {
      expect(
        StableAudio3Request(prompt: 'p').options.containsKey('negative_prompt'),
        isFalse,
      );
      expect(
        StableAudio3Request(prompt: 'p', negativePrompt: '   ')
            .options
            .containsKey('negative_prompt'),
        isFalse,
      );
      expect(
        StableAudio3Request(prompt: 'p', negativePrompt: 'vocals')
            .options['negative_prompt'],
        'vocals',
      );
    });

    test('sends no sampler unless one was chosen', () {
      expect(StableAudio3Request(prompt: 'p').options.containsKey('sampler'),
          isFalse);
      expect(
        StableAudio3Request(prompt: 'p', sampler: 'euler').options['sampler'],
        'euler',
      );
    });

    test('never emits a lyrics option, because the model has none', () {
      // Stable Audio's upstream spec claims a `lyrics` capability. It has no
      // lyrics input of any kind; sending one would be silently ignored and
      // the track would come back instrumental with no explanation.
      expect(
        StableAudio3Request(prompt: 'p').options.containsKey('lyrics'),
        isFalse,
      );
    });

    test('exposes the family and task the registry expects', () {
      expect(StableAudio3Request.family, 'stable_audio');
      expect(StableAudio3Request.task, AudioCppTask.audioGeneration);
    });
  });
}
