import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';

/// Where one track is in its lifecycle.
///
/// [queued] and [running] are persisted like any other state: generation takes
/// minutes, so a track that was mid-flight when the app died has to come back
/// as something the user can see and retry rather than vanishing.
enum TrackStatus {
  queued,
  running,
  done,
  failed;

  static TrackStatus parse(String? name) => TrackStatus.values.firstWhere(
        (TrackStatus status) => status.name == name,
        orElse: () => TrackStatus.failed,
      );
}

/// Everything that determines what the engine produces, kept together so a
/// finished track can be replayed or nudged ("remix") without reconstructing
/// the form field by field.
@immutable
final class GenerationParams {
  const GenerationParams({
    required this.caption,
    required this.lyrics,
    this.durationSeconds = 30,
    this.inferenceSteps = 30,
    this.guidanceScale = 1.7,
    this.arGuidanceScale = 1.5,
    this.topK = 50,
    this.seed = 0,
    this.styleTags = const <String>[],
  });

  factory GenerationParams.fromJson(Map<String, Object?> json) {
    return GenerationParams(
      caption: json['caption'] as String? ?? '',
      lyrics: json['lyrics'] as String? ?? '',
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 30,
      inferenceSteps: (json['inference_steps'] as num?)?.toInt() ?? 30,
      guidanceScale: (json['guidance_scale'] as num?)?.toDouble() ?? 1.7,
      arGuidanceScale: (json['ar_guidance_scale'] as num?)?.toDouble() ?? 1.5,
      topK: (json['top_k'] as num?)?.toInt() ?? 50,
      seed: (json['seed'] as num?)?.toInt() ?? 0,
      styleTags: <String>[
        ...?(json['style_tags'] as List<Object?>?)?.whereType<String>(),
      ],
    );
  }

  /// Style caption. Sent as the session's text input.
  final String caption;

  /// Lyrics to sing; empty means an instrumental.
  final String lyrics;

  final int durationSeconds;
  final int inferenceSteps;
  final double guidanceScale;
  final double arGuidanceScale;
  final int topK;
  final int seed;

  /// Chips the caption was composed from, kept so the Style tab can restore its
  /// selection. Purely a UI concern — the engine only ever sees [caption].
  final List<String> styleTags;

  bool get isInstrumental => lyrics.trim().isEmpty;

  /// The typed request this describes.
  MiniMaxMusic3Request toRequest() => MiniMaxMusic3Request(
        caption: caption,
        lyrics: lyrics,
        durationSeconds: durationSeconds,
        inferenceSteps: inferenceSteps,
        guidanceScale: guidanceScale,
        arGuidanceScale: arGuidanceScale,
        topK: topK,
        seed: seed,
      );

  GenerationParams copyWith({
    String? caption,
    String? lyrics,
    int? durationSeconds,
    int? inferenceSteps,
    double? guidanceScale,
    double? arGuidanceScale,
    int? topK,
    int? seed,
    List<String>? styleTags,
  }) {
    return GenerationParams(
      caption: caption ?? this.caption,
      lyrics: lyrics ?? this.lyrics,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      inferenceSteps: inferenceSteps ?? this.inferenceSteps,
      guidanceScale: guidanceScale ?? this.guidanceScale,
      arGuidanceScale: arGuidanceScale ?? this.arGuidanceScale,
      topK: topK ?? this.topK,
      seed: seed ?? this.seed,
      styleTags: styleTags ?? this.styleTags,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'caption': caption,
        'lyrics': lyrics,
        'duration_seconds': durationSeconds,
        'inference_steps': inferenceSteps,
        'guidance_scale': guidanceScale,
        'ar_guidance_scale': arGuidanceScale,
        'top_k': topK,
        'seed': seed,
        'style_tags': styleTags,
      };
}

/// One generated (or pending) track.
///
/// Immutable: the store replaces entries rather than mutating them, which keeps
/// "what is on disk" and "what is in memory" a single assignment apart.
@immutable
final class Track {
  const Track({
    required this.id,
    required this.title,
    required this.params,
    required this.modelPackageId,
    required this.createdAt,
    this.status = TrackStatus.queued,
    this.audioFileName,
    this.duration,
    this.completedAt,
    this.errorMessage,
    this.favourite = false,
    this.queueOrder,
    this.peaks = const <int>[],
  });

  factory Track.fromJson(Map<String, Object?> json) {
    final durationMs = (json['duration_ms'] as num?)?.toInt();
    final completed = (json['completed_at_unix_ms'] as num?)?.toInt();
    return Track(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      params: GenerationParams.fromJson(
        json['params'] as Map<String, Object?>? ?? const <String, Object?>{},
      ),
      modelPackageId: json['model_package_id'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      ),
      status: TrackStatus.parse(json['status'] as String?),
      audioFileName: json['audio_file_name'] as String?,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      completedAt: completed == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(completed),
      errorMessage: json['error_message'] as String?,
      favourite: json['favourite'] as bool? ?? false,
      queueOrder: (json['queue_order'] as num?)?.toInt(),
      peaks: <int>[
        ...?(json['peaks'] as List<Object?>?)
            ?.whereType<num>()
            .map((num value) => value.toInt()),
      ],
    );
  }

  /// Bumped whenever a field changes meaning rather than merely appearing.
  static const int schemaVersion = 1;

  final String id;
  final String title;
  final GenerationParams params;

  /// Which installed package produced this, so a track survives the model it
  /// was made with being uninstalled and can say what it needs to be remade.
  final String modelPackageId;

  final DateTime createdAt;
  final TrackStatus status;

  /// File name inside the store's audio directory, never an absolute path — the
  /// container path changes between builds and installs, so storing it would
  /// break every track the first time the app is reinstalled.
  final String? audioFileName;

  final Duration? duration;
  final DateTime? completedAt;
  final String? errorMessage;
  final bool favourite;

  /// Position in the generation queue, ascending, for tracks that are still
  /// pending. Explicit rather than derived from [createdAt] because the queue
  /// can be reordered, and null on anything already finished.
  final int? queueOrder;

  /// Amplitude buckets for the waveform, 0-255, empty until the track finishes.
  /// Stored rather than recomputed so scrubbing is instant on every play.
  final List<int> peaks;

  bool get isPending =>
      status == TrackStatus.queued || status == TrackStatus.running;

  bool get hasAudio => status == TrackStatus.done && audioFileName != null;

  Track copyWith({
    String? title,
    GenerationParams? params,
    TrackStatus? status,
    String? audioFileName,
    Duration? duration,
    DateTime? completedAt,
    String? errorMessage,
    bool? favourite,
    int? queueOrder,
    List<int>? peaks,
    bool clearError = false,
    bool clearQueueOrder = false,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      params: params ?? this.params,
      modelPackageId: modelPackageId,
      createdAt: createdAt,
      status: status ?? this.status,
      audioFileName: audioFileName ?? this.audioFileName,
      duration: duration ?? this.duration,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      favourite: favourite ?? this.favourite,
      queueOrder: clearQueueOrder ? null : (queueOrder ?? this.queueOrder),
      peaks: peaks ?? this.peaks,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'params': params.toJson(),
        'model_package_id': modelPackageId,
        'created_at_unix_ms': createdAt.millisecondsSinceEpoch,
        'status': status.name,
        'audio_file_name': audioFileName,
        'duration_ms': duration?.inMilliseconds,
        'completed_at_unix_ms': completedAt?.millisecondsSinceEpoch,
        'error_message': errorMessage,
        'favourite': favourite,
        'queue_order': queueOrder,
        'peaks': peaks,
      };
}
