import 'package:meta/meta.dart';

/// Compute backend used for inference.
///
/// Values mirror `audiocpp_backend` in `audiocpp_ffi.h`. Only backends the
/// native library was compiled with will actually work; on macOS builds from
/// `tool/build_macos.sh` that is [cpu] and, on Apple silicon, [metal].
enum AudioCppBackend {
  cpu(0),
  cuda(1),
  hip(2),
  vulkan(3),
  metal(4),

  /// Let ggml pick the best device it can see.
  bestAvailable(5);

  const AudioCppBackend(this.nativeValue);

  final int nativeValue;
}

/// Task a session performs. Values mirror `audiocpp_task`.
///
/// The names match audio.cpp's own vocabulary, and [nativeValue] must stay in
/// step with `engine::runtime::VoiceTaskKind`.
enum AudioCppTask {
  vad(0),
  asr(1),
  diarization(2),
  sourceSeparation(3),

  /// Text-to-audio generation. What MiniMax Music 3 uses (`--task gen`).
  audioGeneration(4),
  tts(5),
  voiceCloning(6),
  voiceConversion(7),
  speechToSpeech(8),
  alignment(9),
  voiceDesign(10),
  speakerRecognition(11),
  svc(12),
  midi(13);

  const AudioCppTask(this.nativeValue);

  final int nativeValue;
}

/// One ggml device visible to the loaded native library.
@immutable
final class AudioCppDevice {
  const AudioCppDevice({
    required this.backend,
    required this.index,
    required this.name,
    required this.type,
  });

  /// ggml registry name, e.g. `Metal`, `CPU`, `CUDA`.
  final String backend;

  /// Index within [backend]'s registry. This is what [SessionConfig.device] takes.
  final int index;

  /// Human-readable device name, e.g. `Apple M3 Pro`.
  final String name;

  /// `CPU`, `GPU`, `IGPU`, `ACCEL`, or `META`.
  final String type;

  @override
  String toString() => '$backend:$index "$name" [$type]';
}

/// Identifies a model package on disk and how to load it.
@immutable
final class ModelDescriptor {
  const ModelDescriptor({
    required this.path,
    this.family,
    this.modelSpecOverride,
    this.configId,
    this.weightId,
    this.loadOptions = const {},
  });

  /// Directory holding the model package, e.g. `.../MiniMax-Music3-GGUF`.
  final String path;

  /// Family hint such as `minimax_music3`. Strongly recommended: without it the
  /// registry has to infer the family from the package contents.
  final String? family;

  /// Explicit path to a `model_specs/<family>.json`.
  ///
  /// Unnecessary for libraries built by `tool/build_macos.sh`, which compiles
  /// the spec catalog in via `AUDIOCPP_DEPLOYMENT_BUILD=ON`.
  final String? modelSpecOverride;

  /// Named config asset inside the package, when it ships more than one.
  final String? configId;

  /// Named weight asset inside the package, when it ships more than one.
  final String? weightId;

  /// Raw `--load-option` pairs forwarded to the loader.
  final Map<String, String> loadOptions;
}

/// How a session is configured: which task, on which device, with how many threads.
@immutable
final class SessionConfig {
  const SessionConfig({
    required this.task,
    this.backend = AudioCppBackend.bestAvailable,
    this.device = 0,
    this.threads = 4,
    this.sessionOptions = const {},
  }) : assert(threads > 0, 'threads must be positive'),
       assert(device >= 0, 'device must be non-negative');

  final AudioCppTask task;
  final AudioCppBackend backend;

  /// Device index within [backend]'s registry. See [AudioCppDevice.index].
  final int device;

  final int threads;

  /// Raw `--session-option` pairs, e.g.
  /// `{'minimax_music3.language_model_gguf': 'language_model_q8_0.gguf'}`.
  final Map<String, String> sessionOptions;
}

/// A single inference request.
///
/// [InferenceRequest] stays deliberately close to the native shape. Prefer the
/// family-specific builders, such as `MiniMaxMusic3Request`, which know the
/// option names and validate their ranges.
@immutable
class InferenceRequest {
  const InferenceRequest({
    this.text,
    this.language,
    this.options = const {},
  });

  /// Primary text input. For MiniMax Music 3 this is the style caption.
  final String? text;

  /// Language tag passed alongside [text].
  final String? language;

  /// Raw `--request-option` pairs.
  final Map<String, String> options;
}
