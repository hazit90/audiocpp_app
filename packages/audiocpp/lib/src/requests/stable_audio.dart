import 'package:meta/meta.dart';

import '../types.dart';
import 'minimax_music3.dart';

/// A typed request for the `stable_audio` family: text-to-music and sound
/// effects from a prompt alone.
///
/// The option names here are taken from the engine's own CLI interface
/// (`src/models/stable_audio/loader.cpp`) rather than from the model spec,
/// which declares no request options at all. An option the engine does not
/// recognise is ignored silently, so the names matter more than usual.
///
/// Unlike [MiniMaxMusic3Request] there is no lyrics input. Stable Audio has no
/// lyrics conditioning of any kind -- the word does not appear anywhere in
/// `src/models/stable_audio/`. Its spec claims a `lyrics` capability upstream;
/// that claim is wrong, and the copy in `assets/model_specs/` corrects it.
@immutable
final class StableAudio3Request extends InferenceRequest {
  StableAudio3Request({
    required this.prompt,
    this.negativePrompt = '',
    this.durationSeconds = 30,
    this.inferenceSteps = 8,
    this.guidanceScale = 1.0,
    this.seed = 0,
    this.sampler,
    Map<String, String> extraOptions = const {},
  })  : assert(durationSeconds > 0, 'durationSeconds must be positive'),
        assert(inferenceSteps > 0, 'inferenceSteps must be positive'),
        assert(guidanceScale >= 0, 'guidanceScale must be non-negative'),
        super(
          text: prompt,
          options: {
            'duration_seconds': '$durationSeconds',
            'num_inference_steps': '$inferenceSteps',
            'guidance_scale': '$guidanceScale',
            'seed': '$seed',
            if (negativePrompt.trim().isNotEmpty) 'negative_prompt': negativePrompt,
            'sampler': ?sampler,
            ...extraOptions,
          },
        );

  /// What to generate. Passed as the session's text input, like MiniMax's
  /// caption.
  ///
  /// A `|` splits this into several prompts and the engine then requires the
  /// count to match `batch_size`, so a bare pipe in a one-shot request is an
  /// error rather than punctuation.
  final String prompt;

  /// What to steer away from. Omitted from the options entirely when blank,
  /// rather than sent as an empty string.
  final String negativePrompt;

  /// Target duration. Unlike MiniMax's frame budget this is a real target: the
  /// engine generates past it by `duration_padding_seconds` and trims back.
  final int durationSeconds;

  /// Rectified-flow diffusion steps. The engine's default is 8 -- this model is
  /// not the 30-step proposition MiniMax Music 3 is.
  final int inferenceSteps;

  /// Classifier-free guidance scale. Engine default is 1.0.
  final double guidanceScale;

  /// Generation seed. The engine picks a random one when the option is absent,
  /// so this is always sent to keep a track reproducible.
  final int seed;

  /// Diffusion sampler, or null for the engine's `pingpong` default. The
  /// DPM++ samplers are only accepted by the foundation/medium path.
  final String? sampler;

  /// Samplers the engine accepts, in the order its docs list them.
  static const List<String> samplers = <String>[
    'pingpong',
    'euler',
    'dpmpp-2m',
    'dpmpp-3m-sde',
  ];

  /// Session options for this family.
  static Map<String, String> sessionOverrides({bool? memorySaver}) {
    return <String, String>{
      if (memorySaver != null) 'stable_audio.mem_saver': '$memorySaver',
    };
  }

  /// Family string the registry expects for this model.
  static const String family = 'stable_audio';

  /// The task this family runs under (`--task gen`).
  static const AudioCppTask task = AudioCppTask.audioGeneration;
}
