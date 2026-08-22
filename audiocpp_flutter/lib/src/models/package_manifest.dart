import 'dart:convert';
import 'dart:io';

import 'package:audiocpp/audiocpp.dart';

/// Record of one installed package, written beside the model files.
///
/// The format deliberately matches what `tools/model_manager_v2.py` writes, so
/// a package installed with audio.cpp's own CLI shows as installed here and
/// vice versa. Diverging would mean a user who followed the upstream docs sees
/// an empty library.
final class PackageManifest {
  const PackageManifest({
    required this.packageId,
    required this.repo,
    required this.requestedRevision,
    required this.resolvedRevision,
    required this.installedAtUnix,
    required this.files,
  });

  factory PackageManifest.fromJson(Map<String, Object?> json) {
    final rawFiles = json['files'] as Map<String, Object?>? ?? const {};
    return PackageManifest(
      packageId: json['package_id'] as String? ?? '',
      repo: json['repo'] as String? ?? '',
      requestedRevision: json['requested_revision'] as String? ?? 'main',
      resolvedRevision: json['resolved_revision'] as String? ?? '',
      installedAtUnix: (json['installed_at_unix'] as num?)?.toInt() ?? 0,
      files: rawFiles.map((String name, Object? value) {
        final entry = value as Map<String, Object?>? ?? const {};
        return MapEntry<String, ManifestFile>(
          name,
          ManifestFile(
            size: (entry['size'] as num?)?.toInt(),
            etag: entry['etag'] as String? ?? '',
          ),
        );
      }),
    );
  }

  static const int schemaVersion = 1;

  final String packageId;
  final String repo;
  final String requestedRevision;

  /// Commit the revision resolved to at install time, from the `X-Repo-Commit`
  /// response header. Lets us tell a stale install from a current one.
  final String resolvedRevision;

  final int installedAtUnix;

  /// Remote path to size and etag, as served at install time.
  final Map<String, ManifestFile> files;

  DateTime get installedAt =>
      DateTime.fromMillisecondsSinceEpoch(installedAtUnix * 1000);

  /// Total bytes recorded for this package, where sizes were known.
  int get totalBytes => files.values
      .fold(0, (int sum, ManifestFile f) => sum + (f.size ?? 0));

  Map<String, Object?> toJson() => <String, Object?>{
        'schema_version': schemaVersion,
        'package_id': packageId,
        'repo': repo,
        'requested_revision': requestedRevision,
        'resolved_revision': resolvedRevision,
        'installed_at_unix': installedAtUnix,
        'files': files.map(
          (String name, ManifestFile file) => MapEntry<String, Object?>(
            name,
            <String, Object?>{'size': file.size, 'etag': file.etag},
          ),
        ),
      };

  /// Reads the manifest for [package], or null when it is not installed.
  static Future<PackageManifest?> read(File file) async {
    try {
      if (!file.existsSync()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return PackageManifest.fromJson(decoded);
    } on Object {
      // A corrupt manifest means "not installed", which prompts a reinstall.
      return null;
    }
  }

  /// Writes atomically, so an interrupted write cannot leave a manifest that
  /// claims an install which did not finish.
  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

/// Size and etag recorded for one file at install time.
final class ManifestFile {
  const ManifestFile({required this.size, required this.etag});

  final int? size;
  final String etag;
}

/// Builds a manifest for a completed install.
PackageManifest buildManifest({
  required ModelPackage package,
  required String resolvedRevision,
  required Map<String, ManifestFile> files,
}) {
  return PackageManifest(
    packageId: package.id,
    repo: package.download.repo,
    requestedRevision: package.download.revision,
    resolvedRevision: resolvedRevision,
    installedAtUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    files: files,
  );
}
