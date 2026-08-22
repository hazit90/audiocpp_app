import 'dart:async';
import 'dart:convert';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'model_downloader.dart';
import 'model_storage.dart';

/// Install state of one package, as shown in the Models screen.
enum InstallState {
  notInstalled,
  downloading,
  installed,

  /// Manifest present but files missing — usually deleted underneath us.
  incomplete,

  /// The spec declares no fetchable source.
  unavailable,
}

/// Everything the UI needs about one package.
@immutable
final class PackageStatus {
  const PackageStatus({
    required this.package,
    required this.state,
    this.progress,
    this.installedBytes = 0,
    this.remoteBytes,
    this.error,
  });

  final ModelPackage package;
  final InstallState state;
  final DownloadProgress? progress;

  /// Bytes on disk for this package.
  final int installedBytes;

  /// Download size, once probed.
  final int? remoteBytes;

  final String? error;

  PackageStatus copyWith({
    InstallState? state,
    DownloadProgress? progress,
    int? installedBytes,
    int? remoteBytes,
    String? error,
    bool clearProgress = false,
    bool clearError = false,
  }) {
    return PackageStatus(
      package: package,
      state: state ?? this.state,
      progress: clearProgress ? null : (progress ?? this.progress),
      installedBytes: installedBytes ?? this.installedBytes,
      remoteBytes: remoteBytes ?? this.remoteBytes,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads the model catalogue and tracks what is installed.
///
/// Downloads run one at a time. Model files are large enough that parallel
/// downloads mostly compete for the same bandwidth while making progress
/// harder to read, and a queue matches how the rest of the app behaves.
final class ModelLibraryController extends ChangeNotifier {
  ModelLibraryController({
    required this.storage,
    required this.downloader,
  });

  /// Directory the specs are synced into by `tool/sync_model_specs.sh`.
  static const String specsAssetDirectory = 'assets/model_specs';

  final ModelStorage storage;
  final ModelDownloader downloader;

  ModelCatalog _catalog = const ModelCatalog(<ModelSpec>[]);
  final Map<String, PackageStatus> _statuses = <String, PackageStatus>{};
  final Map<String, DownloadCancellation> _cancellations =
      <String, DownloadCancellation>{};

  bool _loading = true;
  String? _loadError;

  ModelCatalog get catalog => _catalog;
  bool get isLoading => _loading;
  String? get loadError => _loadError;

  /// Families this app offers, which is music and SFX generation only.
  List<ModelSpec> get families => _catalog.musicAndSfx;

  PackageStatus? statusFor(String packageId) => _statuses[packageId];

  /// Packages ready to load, newest install first.
  List<PackageStatus> get installed => _statuses.values
      .where((PackageStatus s) => s.state == InstallState.installed)
      .toList(growable: false);

  bool get hasAnyInstalled => installed.isNotEmpty;

  /// Total bytes used by installed packages.
  int get totalInstalledBytes => installed.fold(
      0, (int sum, PackageStatus s) => sum + s.installedBytes);

  /// Reads the bundled specs and scans the disk for installed packages.
  Future<void> load() async {
    _loading = true;
    _loadError = null;
    notifyListeners();

    try {
      final index = jsonDecode(
        await rootBundle.loadString('$specsAssetDirectory/index.json'),
      ) as List<Object?>;

      final sources = <String>[];
      for (final entry in index) {
        final name = entry! as String;
        if (name == 'index.json') {
          continue;
        }
        sources.add(await rootBundle.loadString('$specsAssetDirectory/$name'));
      }

      _catalog = ModelCatalog.parse(sources);
      await refreshInstallState();
    } on Object catch (error) {
      _loadError = 'Could not read the model catalogue: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Rescans the disk. Cheap enough to call whenever the screen is shown.
  Future<void> refreshInstallState() async {
    for (final spec in families) {
      for (final package in spec.packages) {
        // Never clobber the state of a download in flight.
        if (_statuses[package.id]?.state == InstallState.downloading) {
          continue;
        }

        if (!package.isFetchable) {
          _statuses[package.id] = PackageStatus(
            package: package,
            state: InstallState.unavailable,
          );
          continue;
        }

        final manifest = await storage.manifestFor(package);
        final complete = await storage.isComplete(package);
        _statuses[package.id] = PackageStatus(
          package: package,
          state: complete
              ? InstallState.installed
              : (manifest != null
                  ? InstallState.incomplete
                  : InstallState.notInstalled),
          installedBytes: complete ? await storage.installedBytes(package) : 0,
          remoteBytes: _statuses[package.id]?.remoteBytes ??
              (complete ? manifest?.totalBytes : null),
        );
      }
    }
    notifyListeners();
  }

  /// Asks the server how large a package is, without downloading it.
  Future<void> probeSize(ModelPackage package) async {
    final current = _statuses[package.id];
    if (current == null || current.remoteBytes != null) {
      return;
    }
    try {
      final size = await downloader.probeSize(package);
      if (size != null) {
        _statuses[package.id] = current.copyWith(remoteBytes: size);
        notifyListeners();
      }
    } on Object {
      // A size is a nicety; failing to get one must not surface as an error.
    }
  }

  /// Downloads and installs [package].
  Future<void> install(ModelPackage package) async {
    final existing = _statuses[package.id];
    if (existing?.state == InstallState.downloading) {
      return;
    }

    final cancellation = DownloadCancellation();
    _cancellations[package.id] = cancellation;
    _statuses[package.id] = (existing ??
            PackageStatus(package: package, state: InstallState.notInstalled))
        .copyWith(state: InstallState.downloading, clearError: true);
    notifyListeners();

    try {
      await downloader.download(
        package,
        cancellation: cancellation,
        onProgress: (DownloadProgress progress) {
          final status = _statuses[package.id];
          if (status != null) {
            _statuses[package.id] = status.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );

      _statuses[package.id] = PackageStatus(
        package: package,
        state: InstallState.installed,
        installedBytes: await storage.installedBytes(package),
        remoteBytes: _statuses[package.id]?.remoteBytes,
      );
    } on DownloadCancelledException {
      // Staged bytes are kept deliberately, so resuming is cheap.
      _statuses[package.id] = PackageStatus(
        package: package,
        state: InstallState.notInstalled,
        remoteBytes: _statuses[package.id]?.remoteBytes,
      );
    } on Object catch (error) {
      _statuses[package.id] = PackageStatus(
        package: package,
        state: InstallState.notInstalled,
        remoteBytes: _statuses[package.id]?.remoteBytes,
        error: error is DownloadException ? error.message : error.toString(),
      );
    } finally {
      _cancellations.remove(package.id);
      notifyListeners();
    }
  }

  /// Stops an in-flight download, keeping what has arrived for a later resume.
  void cancel(ModelPackage package) => _cancellations[package.id]?.cancel();

  /// Deletes an installed package.
  Future<void> remove(ModelPackage package) async {
    final spec = _catalog.specForPackage(package.id);
    await storage.remove(package, siblings: spec?.packages ?? <ModelPackage>[package]);
    await refreshInstallState();
  }

  /// Throws away a partial download without installing anything.
  Future<void> discardPartial(ModelPackage package) async {
    await storage.discardStaging(package);
    await refreshInstallState();
  }

  @override
  void dispose() {
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    downloader.close();
    super.dispose();
  }
}
