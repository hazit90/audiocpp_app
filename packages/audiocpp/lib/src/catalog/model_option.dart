import 'package:meta/meta.dart';

/// Value type of a model option, as declared in `model_specs/<family>.json`.
enum ModelOptionType {
  string('string'),
  integer('int'),
  number('float'),
  boolean('bool'),

  /// Constrained to [ModelOption.values].
  enumeration('enum'),

  /// Filesystem path to a non-audio asset.
  path('path'),

  /// Filesystem path to an audio file.
  audioPath('audio_path'),

  /// A type this package does not know about, most likely added upstream.
  unknown('');

  const ModelOptionType(this.wireName);

  final String wireName;

  static ModelOptionType parse(String? value) {
    for (final type in ModelOptionType.values) {
      if (type.wireName == value) {
        return type;
      }
    }
    return ModelOptionType.unknown;
  }
}

/// One tunable option a model accepts.
///
/// This is what makes a generated settings UI possible: the spec carries the
/// name, type, bounds, default and human description for every parameter, so
/// controls do not have to be hand-written per family and cannot drift when a
/// model changes upstream.
@immutable
final class ModelOption {
  const ModelOption({
    required this.name,
    required this.type,
    required this.description,
    required this.required,
    this.defaultValue,
    this.values = const [],
    this.min,
    this.max,
    this.preset,
  });

  factory ModelOption.fromJson(Map<String, Object?> json) {
    return ModelOption(
      name: json['name']! as String,
      type: ModelOptionType.parse(json['type'] as String?),
      description: json['description'] as String? ?? '',
      required: json['required'] as bool? ?? false,
      // Defaults arrive as bool/num/String depending on type; the engine takes
      // every option as a string, so normalise once here.
      defaultValue: _stringify(json['default']),
      values: (json['values'] as List<Object?>?)
              ?.map((Object? value) => value.toString())
              .toList(growable: false) ??
          const [],
      min: json['min'] as num?,
      max: json['max'] as num?,
      preset: json['preset'] as String?,
    );
  }

  /// Option key passed to the engine, e.g. `duration_sec`.
  final String name;

  final ModelOptionType type;

  /// Human-readable explanation, suitable for helper text.
  final String description;

  /// When true the engine rejects a request that omits this option.
  final bool required;

  /// Default as a string, matching how the engine consumes options.
  final String? defaultValue;

  /// Allowed values for [ModelOptionType.enumeration].
  final List<String> values;

  final num? min;
  final num? max;

  /// Named preset group this option belongs to, when the spec declares one.
  final String? preset;

  /// True when a slider is a sensible control: numeric with both bounds known.
  bool get hasFullRange => min != null && max != null;

  static String? _stringify(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    if (value is bool) {
      return value ? 'true' : 'false';
    }
    if (value is double && value == value.roundToDouble() && value.isFinite) {
      // 20.0 in JSON means 20 to the engine; keep option strings tidy.
      return value.toInt().toString();
    }
    return value.toString();
  }
}

/// The three option scopes audio.cpp distinguishes.
@immutable
final class ModelOptions {
  const ModelOptions({
    this.request = const [],
    this.session = const [],
    this.load = const [],
  });

  factory ModelOptions.fromJson(Map<String, Object?>? json) {
    if (json == null) {
      return const ModelOptions();
    }
    return ModelOptions(
      request: _parseList(json['request']),
      session: _parseList(json['session']),
      load: _parseList(json['load']),
    );
  }

  /// Per-generation options, e.g. `lyrics`, `seed`, `duration_sec`.
  final List<ModelOption> request;

  /// Options fixed when the session is created, e.g. component precisions.
  final List<ModelOption> session;

  /// Options applied while loading the package.
  final List<ModelOption> load;

  bool get isEmpty => request.isEmpty && session.isEmpty && load.isEmpty;

  ModelOption? findRequest(String name) {
    for (final option in request) {
      if (option.name == name) {
        return option;
      }
    }
    return null;
  }

  static List<ModelOption> _parseList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .cast<Map<String, Object?>>()
        .map(ModelOption.fromJson)
        .toList(growable: false);
  }
}
