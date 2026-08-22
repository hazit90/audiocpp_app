import 'package:meta/meta.dart';

import '../types.dart';

/// A typed request for the `minimax_music3` family: text-to-music with lyrics
/// conditioning.
///
/// The option names and defaults here track
/// `third_party/audio.cpp/docs/community_models/minimax_music3.md`. Keeping them
/// in one place means the rest of the app never has to hand-write
/// `--request-option` strings.
@immutable
final class MiniMaxMusic3Request extends InferenceRequest {
  MiniMaxMusic3Request({
    required this.caption,
    required this.lyrics,
    this.durationSeconds = 20,
    this.inferenceSteps = 30,
    this.guidanceScale = 1.7,
    this.arGuidanceScale = 1.5,
    this.topK = 50,
    this.seed = 0,
    Map<String, String> extraOptions = const {},
  })  : assert(durationSeconds > 0, 'durationSeconds must be positive'),
        assert(inferenceSteps > 0, 'inferenceSteps must be positive'),
        assert(guidanceScale >= 0, 'guidanceScale must be non-negative'),
        assert(arGuidanceScale >= 0, 'arGuidanceScale must be non-negative'),
        assert(topK > 0, 'topK must be positive'),
        super(
          text: caption,
          options: {
            'lyrics': lyrics,
            'duration_sec': '$durationSeconds',
            'num_inference_steps': '$inferenceSteps',
            'guidance_scale': '$guidanceScale',
            'ar_guidance_scale': '$arGuidanceScale',
            'top_k': '$topK',
            'seed': '$seed',
            ...extraOptions,
          },
        );

  /// Style caption, e.g. "A bright pop rock song with clean drums...".
  /// Passed as the session's text input, not as an option.
  final String caption;

  /// Lyrics to sing. Section tags such as `[verse]`, `[chorus]`, `[bridge]`
  /// and `[outro]` are understood. Required by the model.
  final String lyrics;

  /// Autoregressive frame budget, in seconds.
  ///
  /// This is *not* a hard cap on output length: the finished song may be
  /// shorter depending on prompt, lyrics, seed and sampling. Larger budgets
  /// raise peak memory because the AR and flow stages reserve room up front.
  final int durationSeconds;

  /// Flow-matching Euler steps per chunk. Lower is faster and rougher.
  final int inferenceSteps;

  /// Flow transformer CFG scale. `0` selects the non-CFG flow path.
  final double guidanceScale;

  /// Semantic/depth AR CFG scale. `0` selects the non-CFG AR path.
  final double arGuidanceScale;

  /// Top-k sampling bound for semantic and residual code sampling.
  final int topK;

  /// Generation seed. Diffusion-style music generation varies a lot by seed,
  /// so exposing this is worth it even though `0` is the documented default.
  final int seed;

  /// Session options selecting component GGUF precisions inside the package.
  ///
  /// Do not combine these with a `weight_type` for the same component: the GGUF
  /// file already determines the stored precision.
  static Map<String, String> componentOverrides({
    String? languageModelGguf,
    String? rvqDepthDecoderGguf,
    String? flowTransformerGguf,
    int? graphContextMb,
    int? weightContextMb,
    bool? memorySaver,
  }) {
    return {
      'minimax_music3.language_model_gguf': ?languageModelGguf,
      'minimax_music3.rvq_depth_decoder_gguf': ?rvqDepthDecoderGguf,
      'minimax_music3.flow_transformer_gguf': ?flowTransformerGguf,
      if (graphContextMb != null) 'minimax_music3.graph_context_mb': '$graphContextMb',
      if (weightContextMb != null) 'minimax_music3.weight_context_mb': '$weightContextMb',
      if (memorySaver != null) 'minimax_music3.mem_saver': '$memorySaver',
    };
  }

  /// Family string the registry expects for this model.
  static const String family = 'minimax_music3';

  /// The task this family runs under (`--task gen`).
  static const AudioCppTask task = AudioCppTask.audioGeneration;
}
