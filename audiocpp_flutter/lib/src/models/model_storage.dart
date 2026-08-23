import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package_manifest.dart';

/// Owns where model files live on disk.
///
/// Models are multi-gigabyte directories, so the location is a setting rather
/// than a constant: people with an external drive will want to point at it, and
/// moving models after the fact is far more annoying than choosing up front.
final class ModelStorage {
  ModelStorage({required this.root});

  /// Resolves the default root, `<Application Support>/models`.
  ///
  /// Windows takes a different directory on purpose. There,
  /// `getApplicationSupportDirectory()` resolves under `%APPDATA%`, which is the
  /// *roaming* profile — a place Windows may try to synchronise to a file server
  /// on domain-joined machines. A model package is several gigabytes, so it
  /// belongs in `%LOCALAPPDATA%` instead. Tracks are small and stay put.
  static Future<ModelStorage> resolveDefault({String? overridePath}) async {
    if (overridePath != null && overridePath.isNotEmpty) {
      return ModelStorage(root: Directory(overridePath));
    }
    final support = await getApplicationSupportDirectory();
    if (Platform.isWindows) {
      final local = _windowsLocalAppDataEquivalent(support);
      if (local != null) {
        return ModelStorage(root: Directory(p.join(local, 'models')));
      }
    }
    return ModelStorage(root: Directory(p.join(support.path, 'models')));
  }

  /// Maps `%APPDATA%\<Company>\<Product>` onto its `%LOCALAPPDATA%` twin.
  ///
  /// Derived from the roaming path rather than composed from scratch so the
  /// company and product names stay whatever `path_provider` read out of the
  /// executable's version resource — they are not ours to guess.
  ///
  /// Returns null if the environment does not look as expected, in which case
  /// the caller keeps the roaming path: a working app in the wrong directory
  /// beats a broken one.
  static String? _windowsLocalAppDataEquivalent(Directory support) {
    final roaming = Platform.environment['APPDATA'];
    final local = Platform.environment['LOCALAPPDATA'];
    if (roaming == null || roaming.isEmpty || local == null || local.isEmpty) {
      return null;
    }
    if (!p.isWithin(roaming, support.path)) {
      return null;
    }
    return p.join(local, p.relative(support.path, from: roaming));
  }

  /// Directory holding every installed package.
  final Directory root;

  /// Staging area for in-flight downloads.
  ///
  /// Kept on the same filesystem as [root] so the final move is a rename, not a
  /// copy — a partially downloaded model must never be visible as installed.
  Directory get stagingRoot => Directory(p.join(root.path, '.incomplete'));

  Future<void> ensureExists() async {
    await root.create(recursive: true);
  }

  /// Directory a package installs into, e.g. `<root>/MiniMax-Music3-GGUF`.
  Directory directoryFor(ModelPackage package) =>
      Directory(p.join(root.path, package.targetDirectory));

  /// Path the app passes to `ModelDescriptor.path`.
  String modelPathFor(ModelPackage package) => directoryFor(package).path;

  File manifestFileFor(ModelPackage package) =>
      File(p.join(directoryFor(package).path, package.manifestFileName));

  /// Absolute local path for one of the package's remote files.
  File fileFor(ModelPackage package, String remotePath) =>
      File(p.join(root.path, p.joinAll(package.localPathFor(remotePath).split('/'))));

  Directory stagingFor(ModelPackage package) =>
      Directory(p.join(stagingRoot.path, package.id));

  File stagingFileFor(ModelPackage package, String remotePath) => File(
        p.join(
          stagingFor(package).path,
          p.joinAll(package.localPathFor(remotePath).split('/')),
        ),
      );

  /// Reads the install record for [package], or null when it is not installed.
  Future<PackageManifest?> manifestFor(ModelPackage package) =>
      PackageManifest.read(manifestFileFor(package));

  /// Whether every file the package declares is present on disk.
  ///
  /// A manifest alone is not proof: files can be deleted underneath us, and a
  /// missing file would otherwise surface as an opaque engine load failure.
  Future<bool> isComplete(ModelPackage package) async {
    if (await manifestFor(package) == null) {
      return false;
    }
    for (final remote in package.files) {
      if (!fileFor(package, remote).existsSync()) {
        return false;
      }
    }
    return true;
  }

  /// Bytes on disk for the files this package declares.
  Future<int> installedBytes(ModelPackage package) async {
    var total = 0;
    for (final remote in package.files) {
      final file = fileFor(package, remote);
      if (file.existsSync()) {
        total += await file.length();
      }
    }
    return total;
  }

  /// Bytes already staged for an interrupted download of [package].
  Future<int> stagedBytes(ModelPackage package) async {
    final directory = stagingFor(package);
    if (!directory.existsSync()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Removes a package's files and its manifest.
  ///
  /// Files shared with another installed package of the same family are kept —
  /// several packages share one target directory, so a blind directory delete
  /// would silently break a sibling.
  Future<void> remove(
    ModelPackage package, {
    required Iterable<ModelPackage> siblings,
  }) async {
    final keep = <String>{};
    for (final sibling in siblings) {
      if (sibling.id == package.id) {
        continue;
      }
      if (await isComplete(sibling)) {
        for (final remote in sibling.files) {
          keep.add(fileFor(sibling, remote).path);
        }
      }
    }

    // Delete the manifest first: if this is interrupted, the package reads as
    // not installed rather than as installed but incomplete.
    final manifest = manifestFileFor(package);
    if (manifest.existsSync()) {
      await manifest.delete();
    }

    for (final remote in package.files) {
      final file = fileFor(package, remote);
      if (!keep.contains(file.path) && file.existsSync()) {
        await file.delete();
      }
    }

    await discardStaging(package);
    await _pruneEmptyDirectories(directoryFor(package));
  }

  /// Throws away a partial download.
  Future<void> discardStaging(ModelPackage package) async {
    final staging = stagingFor(package);
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
  }

  Future<void> _pruneEmptyDirectories(Directory directory) async {
    if (!directory.existsSync() || !p.isWithin(root.path, directory.path)) {
      return;
    }
    final entries = directory.listSync();
    for (final entry in entries) {
      if (entry is Directory) {
        await _pruneEmptyDirectories(entry);
      }
    }
    if (directory.listSync().isEmpty) {
      await directory.delete();
    }
  }
}

/// Formats a byte count for display, e.g. `1.4 GB`.
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
