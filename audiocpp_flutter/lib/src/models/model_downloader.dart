import 'dart:async';
import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:path/path.dart' as p;

import 'model_storage.dart';
import 'package_manifest.dart';

/// Progress of an in-flight package download.
final class DownloadProgress {
  const DownloadProgress({
    required this.packageId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.filesDone,
    required this.fileCount,
    required this.currentFile,
  });

  final String packageId;
  final int receivedBytes;

  /// Total across every file, or null while sizes are still being probed.
  final int? totalBytes;

  final int filesDone;
  final int fileCount;

  /// Remote path currently being fetched.
  final String currentFile;

  /// 0..1, or null when the total is not yet known.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// Raised when a download fails in a way worth showing the user.
final class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Signals that a download was cancelled rather than failed.
final class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'download cancelled';
}

/// Handle for cancelling an in-flight download.
final class DownloadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Downloads model packages from Hugging Face.
///
/// Deliberately plain Dart rather than audio.cpp's native package manager: the
/// specs carry the repo and an explicit file list, so each file is an ordinary
/// HTTPS GET. That keeps progress, resume and cancellation on our side of the
/// boundary, and avoids the BoringSSL dependency the native manager needs.
final class ModelDownloader {
  ModelDownloader({required this.storage, HttpClient? client, this.endpoint})
      : _client = client ?? (HttpClient()..userAgent = 'audiocpp_app/0.1');

  final ModelStorage storage;
  final HttpClient _client;

  /// Overrides the Hugging Face host, for a mirror or a test server.
  final Uri? endpoint;

  /// Token for gated repos. Only sent to huggingface.co.
  String? huggingFaceToken;

  void close() => _client.close(force: true);

  /// Total download size for [package], or null if the server withheld sizes.
  ///
  /// Issues one HEAD per file, so it is worth caching in the caller.
  Future<int?> probeSize(ModelPackage package) async {
    var total = 0;
    for (final remote in package.files) {
      final info = await _head(package, remote);
      final size = info.size;
      if (size == null) {
        return null;
      }
      total += size;
    }
    return total;
  }

  /// Downloads every file of [package] and installs it atomically.
  ///
  /// Files land in a staging directory first and are moved into place only once
  /// all of them have arrived, so an interrupted download can never present
  /// itself as an installed model. Re-running resumes from what is already
  /// staged.
  Future<void> download(
    ModelPackage package, {
    required void Function(DownloadProgress) onProgress,
    DownloadCancellation? cancellation,
  }) async {
    if (!package.isFetchable) {
      throw DownloadException(
        '${package.displayName} cannot be downloaded: '
        'the model spec declares no fetchable source.',
      );
    }

    await storage.ensureExists();
    final staging = storage.stagingFor(package);
    await staging.create(recursive: true);

    // Probe first so the progress bar has a real denominator from the start.
    final sizes = <String, int?>{};
    final etags = <String, String>{};
    var resolvedRevision = '';
    for (final remote in package.files) {
      _throwIfCancelled(cancellation);
      final info = await _head(package, remote);
      sizes[remote] = info.size;
      etags[remote] = info.etag;
      if (resolvedRevision.isEmpty) {
        resolvedRevision = info.revision;
      }
    }

    final knownTotal = sizes.values.every((int? s) => s != null)
        ? sizes.values.fold<int>(0, (int sum, int? s) => sum + s!)
        : null;

    var received = 0;
    var filesDone = 0;

    // Count what a previous attempt already staged so resume does not restart
    // the progress bar at zero.
    for (final remote in package.files) {
      final staged = storage.stagingFileFor(package, remote);
      if (staged.existsSync()) {
        received += await staged.length();
      }
    }

    onProgress(DownloadProgress(
      packageId: package.id,
      receivedBytes: received,
      totalBytes: knownTotal,
      filesDone: filesDone,
      fileCount: package.files.length,
      currentFile: package.files.isEmpty ? '' : package.files.first,
    ));

    for (final remote in package.files) {
      _throwIfCancelled(cancellation);

      final staged = storage.stagingFileFor(package, remote);
      final expected = sizes[remote];
      var alreadyHave = staged.existsSync() ? await staged.length() : 0;

      if (expected != null && alreadyHave == expected) {
        filesDone++;
        continue;
      }
      if (expected != null && alreadyHave > expected) {
        // A previous run wrote past the expected length, so the file cannot be
        // trusted. Start it over rather than resuming into garbage.
        await staged.delete();
        received -= alreadyHave;
        alreadyHave = 0;
      }

      await _downloadFile(
        package: package,
        remotePath: remote,
        destination: staged,
        resumeFrom: alreadyHave,
        cancellation: cancellation,
        onRestart: () {
          // The server ignored our Range header and is resending the whole
          // file, so the bytes we counted from the previous attempt are gone.
          received -= alreadyHave;
        },
        onChunk: (int bytes) {
          received += bytes;
          onProgress(DownloadProgress(
            packageId: package.id,
            receivedBytes: received,
            totalBytes: knownTotal,
            filesDone: filesDone,
            fileCount: package.files.length,
            currentFile: remote,
          ));
        },
      );

      filesDone++;
    }

    _throwIfCancelled(cancellation);
    await _promote(package, resolvedRevision, sizes, etags);
  }

  /// Moves staged files into their final locations and writes the manifest.
  ///
  /// The manifest is written last: until it exists the package reads as not
  /// installed, so a crash midway through leaves a retryable state rather than
  /// a half-installed model the engine would fail on.
  Future<void> _promote(
    ModelPackage package,
    String resolvedRevision,
    Map<String, int?> sizes,
    Map<String, String> etags,
  ) async {
    for (final remote in package.files) {
      final staged = storage.stagingFileFor(package, remote);
      final target = storage.fileFor(package, remote);
      if (!staged.existsSync()) {
        throw DownloadException('missing downloaded file: $remote');
      }
      await Directory(p.dirname(target.path)).create(recursive: true);
      if (target.existsSync()) {
        await target.delete();
      }
      try {
        await staged.rename(target.path);
      } on FileSystemException {
        // Different filesystems: fall back to copy-then-delete.
        await staged.copy(target.path);
        await staged.delete();
      }
    }

    final manifest = buildManifest(
      package: package,
      resolvedRevision: resolvedRevision,
      files: <String, ManifestFile>{
        for (final remote in package.files)
          remote: ManifestFile(size: sizes[remote], etag: etags[remote] ?? ''),
      },
    );
    await manifest.write(storage.manifestFileFor(package));
    await storage.discardStaging(package);
  }

  /// Fetches one file, resuming from [resumeFrom] when the server allows it.
  ///
  /// Byte accounting lives entirely in [onChunk]; [onRestart] fires when the
  /// server declined the range and previously counted bytes must be dropped.
  Future<void> _downloadFile({
    required ModelPackage package,
    required String remotePath,
    required File destination,
    required int resumeFrom,
    required void Function(int) onChunk,
    required void Function() onRestart,
    DownloadCancellation? cancellation,
  }) async {
    await Directory(p.dirname(destination.path)).create(recursive: true);

    final request = await _client.getUrl(package.urlFor(remotePath, endpoint: endpoint));
    _applyHeaders(request, package);
    if (resumeFrom > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
    }

    final response = await request.close();

    // 206 means the server honoured the range; 200 means it ignored it and is
    // sending the whole file, so any partial content must be discarded.
    final appending = response.statusCode == HttpStatus.partialContent;
    if (response.statusCode != HttpStatus.ok && !appending) {
      await response.drain<void>();
      throw DownloadException(_describeStatus(response.statusCode, package, remotePath));
    }

    if (resumeFrom > 0 && !appending) {
      onRestart();
    }

    // RandomAccessFile rather than openWrite: an IOSink queues its writes and
    // drops them if the source stream errors, so an interrupted transfer would
    // leave a zero-byte file and every resume would restart from scratch.
    // Awaiting each chunk keeps the partial file real.
    final handle = await destination.open(
      mode: appending ? FileMode.append : FileMode.write,
    );
    try {
      await for (final chunk in response) {
        if (cancellation?.isCancelled ?? false) {
          throw const DownloadCancelledException();
        }
        await handle.writeFrom(chunk);
        onChunk(chunk.length);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<_RemoteFileInfo> _head(ModelPackage package, String remotePath) async {
    final request =
        await _client.openUrl('HEAD', package.urlFor(remotePath, endpoint: endpoint));
    _applyHeaders(request, package);
    final response = await request.close();
    await response.drain<void>();

    if (response.statusCode != HttpStatus.ok) {
      throw DownloadException(
        _describeStatus(response.statusCode, package, remotePath),
      );
    }
    return _RemoteFileInfo(
      size: response.headers.contentLength >= 0 ? response.headers.contentLength : null,
      revision: response.headers.value('x-repo-commit') ?? '',
      etag: (response.headers.value(HttpHeaders.etagHeader) ?? '').replaceAll('"', ''),
    );
  }

  void _applyHeaders(HttpClientRequest request, ModelPackage package) {
    final token = huggingFaceToken;
    // Only ever attach the token to huggingface.co, never to a redirect target.
    if (token != null && token.isNotEmpty && request.uri.host == 'huggingface.co') {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }

  String _describeStatus(int status, ModelPackage package, String remotePath) {
    final where = '${package.download.repo}/$remotePath';
    return switch (status) {
      HttpStatus.unauthorized || HttpStatus.forbidden => package.download.gated
          ? '$where needs a Hugging Face token with access accepted for that '
              'repo. Add one in Settings.'
          : 'Access to $where was refused (HTTP $status).',
      HttpStatus.notFound =>
        '$where was not found. The model spec may be newer than the files '
            'published to Hugging Face.',
      _ => 'Failed to fetch $where (HTTP $status).',
    };
  }

  void _throwIfCancelled(DownloadCancellation? cancellation) {
    if (cancellation?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }
  }
}

final class _RemoteFileInfo {
  const _RemoteFileInfo({
    required this.size,
    required this.revision,
    required this.etag,
  });

  final int? size;
  final String revision;
  final String etag;
}
