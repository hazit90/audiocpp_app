import 'dart:convert';

import 'package:meta/meta.dart';

import 'model_option.dart';
import 'model_package.dart';

/// Broad grouping a family belongs to, from the spec's `category` field.
enum ModelCategory {
  audioGeneration('audio_generation'),
  tts('tts'),
  asr('asr'),
  voiceConversion('voice_conversion'),
  speechAnalysis('speech_analysis'),
  audioTools('audio_tools'),
  community('community'),
  unknown('');

  const ModelCategory(this.wireName);

  final String wireName;

  static ModelCategory parse(String? value) {
    for (final category in ModelCategory.values) {
      if (category.wireName == value) {
        return category;
      }
    }
    return ModelCategory.unknown;
  }
}

/// A model family as described by `model_specs/<family>.json`.
@immutable
final class ModelSpec {
  const ModelSpec({
    required this.family,
    required this.displayName,
    required this.description,
    required this.category,
    required this.status,
    required this.tasks,
    required this.languages,
    required this.packages,
    required this.options,
    required this.tags,
    this.recommendedPackageId,
  });

  factory ModelSpec.fromJson(Map<String, Object?> json) {
    final family = json['family']! as String;
    final defaults = json['package_defaults'] as Map<String, Object?>?;
    final downloadDefault = defaults?['download'] as Map<String, Object?>?;
    final familySource =
        downloadDefault == null ? null : DownloadSource.fromJson(downloadDefault);
    final ui = json['ui'] as Map<String, Object?>? ?? const {};

    return ModelSpec(
      family: family,
      displayName: json['display_name'] as String? ?? family,
      description: json['description'] as String? ?? '',
      category: ModelCategory.parse(json['category'] as String?),
      status: json['status'] as String? ?? '',
      tasks: _stringList(json['tasks']),
      languages: _stringList(json['languages']),
      packages: (json['packages'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>()
          .map((Map<String, Object?> package) => ModelPackage.fromJson(
                package,
                family: family,
                familyDefault: familySource,
              ))
          .toList(growable: false),
      options: ModelOptions.fromJson(json['options'] as Map<String, Object?>?),
      tags: _stringList(ui['tags']),
      recommendedPackageId: ui['recommended_package'] as String?,
    );
  }

  /// Parses one spec from its JSON text.
  factory ModelSpec.parse(String source) =>
      ModelSpec.fromJson(jsonDecode(source) as Map<String, Object?>);

  /// Registry family name, e.g. `minimax_music3`. This is what
  /// `ModelDescriptor.family` takes.
  final String family;

  final String displayName;
  final String description;
  final ModelCategory category;

  /// Upstream maturity marker, e.g. `stable`, `preview`.
  final String status;

  /// Task ids the family advertises, e.g. `music`, `sfx`, `edit`, `tts`.
  final List<String> tasks;

  final List<String> languages;
  final List<ModelPackage> packages;
  final ModelOptions options;

  /// Display tags from the spec's `ui` block, e.g. `Music`, `SFX`, `GGUF`.
  final List<String> tags;

  final String? recommendedPackageId;

  /// True when the family generates music or sound effects.
  bool get isMusicOrSfx => tasks.contains('music') || tasks.contains('sfx');

  /// Packages that can actually be downloaded.
  List<ModelPackage> get fetchablePackages =>
      packages.where((ModelPackage p) => p.isFetchable).toList(growable: false);

  /// The variant to offer first: the spec's recommendation, else the one
  /// flagged default, else the first fetchable one.
  ModelPackage? get recommendedPackage {
    final fetchable = fetchablePackages;
    if (fetchable.isEmpty) {
      return null;
    }
    final id = recommendedPackageId;
    if (id != null) {
      for (final package in fetchable) {
        if (package.id == id) {
          return package;
        }
      }
    }
    for (final package in fetchable) {
      if (package.isDefault) {
        return package;
      }
    }
    return fetchable.first;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value.map((Object? entry) => entry.toString()).toList(growable: false);
  }
}

/// Every model spec shipped with the app.
@immutable
final class ModelCatalog {
  const ModelCatalog(this.specs);

  /// Parses a set of spec documents, skipping any that fail to decode.
  ///
  /// A single malformed spec should cost that one family, not the whole
  /// catalogue — specs come from a submodule that moves independently.
  factory ModelCatalog.parse(Iterable<String> sources) {
    final specs = <ModelSpec>[];
    for (final source in sources) {
      try {
        specs.add(ModelSpec.parse(source));
      } on Object {
        continue;
      }
    }
    specs.sort((ModelSpec a, ModelSpec b) => a.displayName.compareTo(b.displayName));
    return ModelCatalog(List<ModelSpec>.unmodifiable(specs));
  }

  final List<ModelSpec> specs;

  /// Families that generate music or sound effects, which is all this app
  /// currently offers.
  List<ModelSpec> get musicAndSfx =>
      specs.where((ModelSpec s) => s.isMusicOrSfx).toList(growable: false);

  ModelSpec? specForFamily(String family) {
    for (final spec in specs) {
      if (spec.family == family) {
        return spec;
      }
    }
    return null;
  }

  ModelPackage? packageById(String id) {
    for (final spec in specs) {
      for (final package in spec.packages) {
        if (package.id == id) {
          return package;
        }
      }
    }
    return null;
  }

  ModelSpec? specForPackage(String packageId) {
    for (final spec in specs) {
      for (final package in spec.packages) {
        if (package.id == packageId) {
          return spec;
        }
      }
    }
    return null;
  }
}
