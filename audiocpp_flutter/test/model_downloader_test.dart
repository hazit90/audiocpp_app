import 'dart:io';
import 'dart:typed_data';

import 'package:audiocpp/audiocpp.dart';
import 'package:audiocpp_flutter/src/models/model_downloader.dart';
import 'package:audiocpp_flutter/src/models/model_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A stand-in for huggingface.co.
///
/// Downloads are the one part of Phase 1 with real failure modes — partial
/// transfers, servers that ignore Range, cancellation mid-stream — so they are
/// exercised against a real socket rather than a mocked client.
final class _FakeHub {
  _FakeHub(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeHub> start() async =>
      _FakeHub(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  final Map<String, Uint8List> files = <String, Uint8List>{};

  /// When true, Range requests are answered with a full 200 body.
  bool ignoreRange = false;

  /// Status to return instead of serving, when set.
  int? forcedStatus;

  /// Bytes written before the connection is dropped, when set.
  int? truncateAfter;

  int requestCount = 0;
  final List<String> rangeHeaders = <String>[];

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    // The downloader builds real Hugging Face paths against our host, so
    // strip the /{repo}/resolve/{revision}/ prefix to find the file.
    final decoded = Uri.decodeComponent(request.uri.path);
    final match = RegExp(r'^/.+?/.+?/resolve/[^/]+/(.*)$').firstMatch(decoded);
    final key = match?.group(1) ?? decoded;
    final body = files[key];

    if (forcedStatus != null) {
      request.response.statusCode = forcedStatus!;
      await request.response.close();
      return;
    }
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.set('x-repo-commit', 'deadbeef');
    request.response.headers.set(HttpHeaders.etagHeader, '"etag-$key"');

    if (request.method == 'HEAD') {
      request.response.headers.contentLength = body.length;
      await request.response.close();
      return;
    }

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      rangeHeaders.add(range);
    }

    var start = 0;
    if (range != null && !ignoreRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      request.response.statusCode = HttpStatus.partialContent;
    }

    final payload = body.sublist(start);
    final limit = truncateAfter;
    request.response.headers.contentLength = payload.length;

    // Written in pieces with flushes: Dart's HttpClient buffers small
    // responses and emits nothing at all if one ends short, so a single
    // add() would never exercise partial-transfer handling.
    const chunk = 256 * 1024;
    final stop = limit != null && limit < payload.length ? limit : payload.length;
    for (var offset = 0; offset < stop; offset += chunk) {
      final end = (offset + chunk) < stop ? offset + chunk : stop;
      request.response.add(payload.sublist(offset, end));
      await request.response.flush();
    }

    if (stop < payload.length) {
      // Drop the connection mid-body, the way a real interrupted transfer does.
      await request.response.close().catchError((Object _) {});
      return;
    }
    await request.response.close();
  }
}

/// Builds a package; the downloader is pointed at the fake hub via `endpoint`,
/// so `ModelPackage` stays the real, final class from the catalogue.
ModelPackage _package({
  String id = 'test_pkg',
  List<String> files = const <String>['a.gguf', 'sub/b.json'],
  String target = 'Test-GGUF',
  bool gated = false,
  DownloadKind kind = DownloadKind.huggingFaceSnapshot,
  String repo = 'test/repo',
}) {
  return ModelPackage(
    id: id,
    family: 'test_family',
    displayName: 'Test Package',
    isDefault: true,
    format: 'gguf',
    precision: 'q4_0',
    targetDirectory: target,
    files: files,
    stripPrefix: '',
    download: DownloadSource(kind: kind, repo: repo, gated: gated),
  );
}

/// Large enough that a truncated response actually delivers chunks before
/// failing; Dart's HttpClient buffers small bodies whole.
const int _bigFile = 4 * 1024 * 1024;
const int _smallFile = 1024 * 1024;
const int _totalBytes = _bigFile + _smallFile;

Uint8List _bytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => (i + seed) % 256));

void main() {
  late Directory tempDir;
  late _FakeHub hub;
  late ModelStorage storage;
  late ModelDownloader downloader;
  late ModelPackage package;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('audiocpp_dl_test');
    hub = await _FakeHub.start();
    storage = ModelStorage(root: Directory(p.join(tempDir.path, 'models')));
    downloader = ModelDownloader(
      storage: storage,
      endpoint: Uri.parse('http://127.0.0.1:${hub.port}'),
    );
    package = _package();
    hub.files['a.gguf'] = _bytes(_bigFile);
    hub.files['sub/b.json'] = _bytes(_smallFile, 7);
  });

  tearDown(() async {
    downloader.close();
    await hub.close();
    await tempDir.delete(recursive: true);
  });

  Future<List<DownloadProgress>> run({DownloadCancellation? cancellation}) async {
    final events = <DownloadProgress>[];
    await downloader.download(
      package,
      onProgress: events.add,
      cancellation: cancellation,
    );
    return events;
  }

  test('downloads every file and writes an interoperable manifest', () async {
    await run();

    expect(await storage.isComplete(package), isTrue);
    expect(storage.fileFor(package, 'a.gguf').lengthSync(), _bigFile);
    expect(storage.fileFor(package, 'sub/b.json').lengthSync(), _smallFile);

    final manifest = await storage.manifestFor(package);
    expect(manifest, isNotNull);
    expect(manifest!.packageId, 'test_pkg');
    expect(manifest.resolvedRevision, 'deadbeef');
    expect(manifest.files['a.gguf']?.size, _bigFile);
    expect(manifest.files['a.gguf']?.etag, 'etag-a.gguf');
    expect(manifest.totalBytes, _totalBytes);

    // The filename must match what audio.cpp's Python installer looks for.
    expect(
      p.basename(storage.manifestFileFor(package).path),
      '.audiocpp-package-test_pkg.json',
    );
  });

  test('reports progress that ends at the true total', () async {
    final events = await run();

    expect(events, isNotEmpty);
    expect(events.last.totalBytes, _totalBytes);
    expect(events.last.receivedBytes, _totalBytes);
    expect(events.last.fraction, 1.0);
    // Progress must never run backwards or overshoot.
    var previous = 0;
    for (final event in events) {
      expect(event.receivedBytes, greaterThanOrEqualTo(previous));
      expect(event.receivedBytes, lessThanOrEqualTo(_totalBytes));
      previous = event.receivedBytes;
    }
  });

  test('nothing is installed until every file has arrived', () async {
    hub.truncateAfter = 1024 * 1024;

    await expectLater(run(), throwsA(isA<Object>()));

    // A half-downloaded model that reads as installed would surface later as an
    // opaque engine failure, so the invariant is worth pinning.
    expect(await storage.isComplete(package), isFalse);
    expect(await storage.manifestFor(package), isNull);
    expect(storage.fileFor(package, 'a.gguf').existsSync(), isFalse);
    expect(await storage.stagedBytes(package), greaterThan(0));
  });

  test('resumes from staged bytes with a Range request', () async {
    hub.truncateAfter = 1024 * 1024;
    await expectLater(run(), throwsA(isA<Object>()));
    final staged = await storage.stagedBytes(package);
    expect(staged, greaterThan(0));

    hub.truncateAfter = null;
    hub.rangeHeaders.clear();
    await run();

    expect(hub.rangeHeaders, isNotEmpty, reason: 'should have asked to resume');
    expect(await storage.isComplete(package), isTrue);
    // The real test of resume: the file is correct, not merely present.
    expect(storage.fileFor(package, 'a.gguf').readAsBytesSync(), _bytes(_bigFile));
  });

  test('recovers when the server ignores Range', () async {
    hub.truncateAfter = 1024 * 1024;
    await expectLater(run(), throwsA(isA<Object>()));

    hub.truncateAfter = null;
    hub.ignoreRange = true;
    final events = await run();

    expect(await storage.isComplete(package), isTrue);
    expect(storage.fileFor(package, 'a.gguf').readAsBytesSync(), _bytes(_bigFile));
    // Byte accounting must not double-count the discarded partial file.
    expect(events.last.receivedBytes, _totalBytes);
  });

  test('cancellation stops the download and keeps it uninstalled', () async {
    final cancellation = DownloadCancellation();
    final events = <DownloadProgress>[];

    final future = downloader.download(
      package,
      cancellation: cancellation,
      onProgress: (DownloadProgress progress) {
        events.add(progress);
        cancellation.cancel();
      },
    );

    await expectLater(future, throwsA(isA<DownloadCancelledException>()));
    expect(await storage.isComplete(package), isFalse);
    expect(await storage.manifestFor(package), isNull);
  });

  test('surfaces a helpful message for a missing file', () async {
    hub.forcedStatus = HttpStatus.notFound;

    await expectLater(
      run(),
      throwsA(isA<DownloadException>().having(
        (DownloadException e) => e.message,
        'message',
        contains('not found'),
      )),
    );
  });

  test('explains a gated repo rather than showing a bare 403', () async {
    final gated = _package(id: 'gated_pkg', files: <String>['a.gguf'], gated: true);
    hub.forcedStatus = HttpStatus.forbidden;

    await expectLater(
      downloader.download(gated, onProgress: (_) {}),
      throwsA(isA<DownloadException>().having(
        (DownloadException e) => e.message,
        'message',
        contains('token'),
      )),
    );
  });

  test('refuses a package with no fetchable source', () async {
    final unsupported = _package(kind: DownloadKind.unsupported, repo: '');

    await expectLater(
      downloader.download(unsupported, onProgress: (_) {}),
      throwsA(isA<DownloadException>()),
    );
  });

  group('removal', () {
    test('deletes files and manifest', () async {
      await run();
      await storage.remove(package, siblings: <ModelPackage>[package]);

      expect(await storage.isComplete(package), isFalse);
      expect(storage.fileFor(package, 'a.gguf').existsSync(), isFalse);
      expect(storage.directoryFor(package).existsSync(), isFalse);
    });

    test('keeps files still owned by an installed sibling', () async {
      // Packages of a family share one target directory, so a blind delete
      // would break the sibling that is still installed.
      await run();
      final sibling = _package(id: 'test_pkg_sibling', files: <String>['a.gguf']);
      await downloader.download(sibling, onProgress: (_) {});

      await storage.remove(package, siblings: <ModelPackage>[package, sibling]);

      expect(storage.fileFor(sibling, 'a.gguf').existsSync(), isTrue,
          reason: 'shared file is still owned by the sibling');
      expect(storage.fileFor(package, 'sub/b.json').existsSync(), isFalse,
          reason: 'file unique to the removed package should go');
      expect(await storage.isComplete(sibling), isTrue);
    });
  });

  test('formatBytes renders human sizes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
  });
}
