import 'package:meta/meta.dart';

/// How a package's files can be fetched.
enum DownloadKind {
  huggingFaceSnapshot('huggingface_snapshot'),

  /// Declared by the spec but not fetchable — these packages are listed as
  /// unavailable rather than hidden, so the reason is visible.
  unsupported('unsupported'),

  unknown('');

  const DownloadKind(this.wireName);

  final String wireName;

  static DownloadKind parse(String? value) {
    for (final kind in DownloadKind.values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    return DownloadKind.unknown;
  }
}

/// Where a package's files come from.
@immutable
final class DownloadSource {
  const DownloadSource({
    required this.kind,
    required this.repo,
    this.revision = 'main',
    this.gated = false,
  });

  factory DownloadSource.fromJson(Map<String, Object?> json) {
    return DownloadSource(
      kind: DownloadKind.parse(json['kind'] as String?),
      repo: json['repo'] as String? ?? '',
      revision: json['revision'] as String? ?? 'main',
      gated: json['gated'] as bool? ?? false,
    );
  }

  /// Hugging Face repo id, e.g. `audio-cpp/MiniMax-Music3-GGUF`.
  final String repo;

  /// Branch, tag or commit.
  final String revision;

  /// When true the repo needs an accepted licence and a token.
  final bool gated;

  final DownloadKind kind;

  bool get isFetchable => kind == DownloadKind.huggingFaceSnapshot && repo.isNotEmpty;

  /// Default host for [urlFor].
  static final Uri defaultEndpoint = Uri.parse('https://huggingface.co');

  /// Resolve URL for one file, matching what audio.cpp's own model manager builds.
  ///
  /// [endpoint] swaps the host, for a Hugging Face mirror or a test server.
  Uri urlFor(String remotePath, {Uri? endpoint}) {
    // Path segments are encoded individually so `/` survives but spaces and
    // other characters in filenames do not break the URL.
    final segments = remotePath.split('/').map(Uri.encodeComponent).join('/');
    final base = endpoint ?? defaultEndpoint;
    return base.replace(
      path: '${base.path}/$repo/resolve/${Uri.encodeComponent(revision)}/$segments'
          .replaceAll('//', '/'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadSource &&
      other.kind == kind &&
      other.repo == repo &&
      other.revision == revision &&
      other.gated == gated;

  @override
  int get hashCode => Object.hash(kind, repo, revision, gated);
}

/// Thrown when a spec declares a file path that would escape the models root.
///
/// The specs are shipped with the app, so this should never fire in practice —
/// but path traversal is exactly the kind of thing that must fail loudly rather
/// than silently write outside the intended directory.
final class UnsafeModelPathException implements Exception {
  const UnsafeModelPathException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'UnsafeModelPathException: $reason ($path)';
}

/// One installable variant of a model, e.g. `minimax_music3_q4_0`.
@immutable
final class ModelPackage {
  const ModelPackage({
    required this.id,
    required this.family,
    required this.displayName,
    required this.isDefault,
    required this.format,
    required this.precision,
    required this.targetDirectory,
    required this.files,
    required this.stripPrefix,
    required this.download,
  });

  factory ModelPackage.fromJson(
    Map<String, Object?> json, {
    required String family,
    required DownloadSource? familyDefault,
  }) {
    final override = json['download'] as Map<String, Object?>?;
    return ModelPackage(
      id: json['id']! as String,
      family: family,
      displayName: json['display_name'] as String? ?? json['id']! as String,
      isDefault: json['default'] as bool? ?? false,
      format: json['format'] as String? ?? '',
      precision: json['precision'] as String? ?? '',
      targetDirectory: json['target_directory']! as String,
      files: (json['files'] as List<Object?>? ?? const [])
          .cast<String>()
          .toList(growable: false),
      stripPrefix: json['strip_prefix'] as String? ?? '',
      download: override != null
          ? DownloadSource.fromJson(override)
          : familyDefault ??
              const DownloadSource(kind: DownloadKind.unknown, repo: ''),
    );
  }

  /// Package id, unique across the whole catalogue.
  final String id;

  /// Family this package belongs to, e.g. `minimax_music3`.
  final String family;

  final String displayName;

  /// True for the variant the spec recommends by default.
  final bool isDefault;

  /// `gguf`, `safetensors`, …
  final String format;

  /// `q4_0`, `q8_0`, `bf16`, `f16`, …
  final String precision;

  /// Directory name under the models root, e.g. `MiniMax-Music3-GGUF`.
  ///
  /// Several packages of a family share one directory, which is why installed
  /// state is tracked per package id rather than per directory.
  final String targetDirectory;

  /// Remote file paths within the repo.
  final List<String> files;

  /// Prefix removed from each remote path to get its local path.
  final String stripPrefix;

  final DownloadSource download;

  bool get isFetchable => download.isFetchable && files.isNotEmpty;

  /// Filename of the interop manifest audio.cpp's model manager also writes.
  ///
  /// Using the same name and location means a package installed by the Python
  /// tool shows as installed here, and vice versa.
  String get manifestFileName => '.audiocpp-package-$id.json';

  /// Local path of [remotePath], relative to the models root.
  ///
  /// Mirrors `stripped_path` in `tools/model_manager_v2.py`, including its
  /// refusal of absolute paths and `..` segments.
  String localPathFor(String remotePath) {
    var relative = remotePath;
    // A "." prefix means "no prefix". At least one shipped spec
    // (vietneu_tts) declares it, and audio.cpp's own Python installer errors
    // out on that package; reading it as empty makes it installable and can
    // never resolve outside the target directory.
    final normalisedPrefix = stripPrefix == '.' || stripPrefix == './' ? '' : stripPrefix;
    if (normalisedPrefix.isNotEmpty) {
      final prefix = normalisedPrefix.endsWith('/')
          ? normalisedPrefix.substring(0, normalisedPrefix.length - 1)
          : normalisedPrefix;
      if (relative == prefix) {
        throw UnsafeModelPathException(
          remotePath,
          'strip_prefix removes the whole file path',
        );
      }
      if (!relative.startsWith('$prefix/')) {
        throw UnsafeModelPathException(
          remotePath,
          "file path does not start with strip_prefix '$stripPrefix'",
        );
      }
      relative = relative.substring(prefix.length + 1);
    }
    _assertSafeRelative(relative, 'local file path');
    _assertSafeRelative(targetDirectory, 'target_directory');
    return '$targetDirectory/$relative';
  }

  Uri urlFor(String remotePath, {Uri? endpoint}) =>
      download.urlFor(remotePath, endpoint: endpoint);

  static void _assertSafeRelative(String value, String label) {
    if (value.isEmpty || value == '.') {
      throw UnsafeModelPathException(value, '$label must not be empty');
    }
    // A backslash is an ordinary character in a Hugging Face repo path but a
    // separator to every Windows filesystem API, so `a\..\b` would pass a
    // '/'-only check here and still escape the model directory once it reached
    // dart:io. Reject the character outright rather than trying to normalise
    // it: no legitimate remote path in any spec we ship contains one.
    if (value.contains(r'\')) {
      throw UnsafeModelPathException(
          value, '$label must not contain a backslash');
    }
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw UnsafeModelPathException(value, '$label must be relative');
    }
    if (value.split('/').contains('..')) {
      throw UnsafeModelPathException(value, '$label must not contain ".."');
    }
  }
}
