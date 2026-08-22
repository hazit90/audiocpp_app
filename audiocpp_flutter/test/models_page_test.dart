import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:audiocpp_flutter/src/models/model_downloader.dart';
import 'package:audiocpp_flutter/src/models/model_library_controller.dart';
import 'package:audiocpp_flutter/src/models/model_storage.dart';
import 'package:audiocpp_flutter/src/models/models_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Renders the Models screen against the real synced catalogue.
///
/// This is the closest thing to launching the app that runs in CI, and it
/// catches the failure that matters most here: the assets not being wired up,
/// which would otherwise only show as an empty screen at runtime.
void main() {
  late Directory tempDir;
  late ModelLibraryController controller;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('audiocpp_models_page');
    final storage = ModelStorage(root: Directory(p.join(tempDir.path, 'models')));
    controller = ModelLibraryController(
      storage: storage,
      // Unroutable endpoint: nothing in this test should reach the network, and
      // a silent real request would make the test slow and flaky.
      downloader: ModelDownloader(
        storage: storage,
        endpoint: Uri.parse('http://127.0.0.1:1'),
      ),
    );
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelsPage(controller: controller)),
      ),
    );
    await tester.pump();
  }

  testWidgets('loads the bundled catalogue from assets', (WidgetTester tester) async {
    await controller.load();

    expect(controller.loadError, isNull);
    expect(controller.catalog.specs.length, greaterThanOrEqualTo(50),
        reason: 'assets/model_specs must be synced and declared in pubspec.yaml');
  });

  testWidgets('shows music families and hides everything else',
      (WidgetTester tester) async {
    await controller.load();
    await pumpPage(tester);

    expect(find.text('MiniMax Music 3'), findsOneWidget);
    expect(find.text('Stable Audio 3'), findsOneWidget);

    // A music app must not offer speech recognition models.
    final families = controller.families.map((ModelSpec s) => s.family);
    expect(families, isNot(contains('qwen3_asr')));
  });

  testWidgets('offers a download for each installable variant',
      (WidgetTester tester) async {
    await controller.load();
    await pumpPage(tester);

    expect(find.text('Download'), findsWidgets);
    expect(find.text('Recommended'), findsWidgets);
  });

  testWidgets('reports nothing installed on a clean machine',
      (WidgetTester tester) async {
    await controller.load();
    await pumpPage(tester);

    expect(find.text('No models installed'), findsOneWidget);
    expect(controller.hasAnyInstalled, isFalse);
  });

  testWidgets('surfaces a failed download instead of failing silently',
      (WidgetTester tester) async {
    await controller.load();
    final package = controller.catalog
        .specForFamily('minimax_music3')!
        .recommendedPackage!;

    // The endpoint refuses connections, so this exercises the error path.
    await controller.install(package);

    final status = controller.statusFor(package.id)!;
    expect(status.state, InstallState.notInstalled);
    expect(status.error, isNotNull);

    await pumpPage(tester);
    expect(find.byType(SelectableText), findsWidgets);
  });

  testWidgets('marks a package installed once its files and manifest exist',
      (WidgetTester tester) async {
    await controller.load();
    final package = controller.catalog
        .specForFamily('minimax_music3')!
        .recommendedPackage!;

    // Simulate an install done by audio.cpp's own Python tool: files on disk
    // plus the shared manifest. The app must recognise it.
    for (final remote in package.files) {
      final file = controller.storage.fileFor(package, remote);
      await file.parent.create(recursive: true);
      await file.writeAsString('x');
    }
    await controller.storage.manifestFileFor(package).writeAsString(
          '{"schema_version":1,"package_id":"${package.id}",'
          '"repo":"${package.download.repo}","requested_revision":"main",'
          '"resolved_revision":"abc","installed_at_unix":1,"files":{}}',
        );

    await controller.refreshInstallState();

    expect(controller.statusFor(package.id)!.state, InstallState.installed);
    expect(controller.hasAnyInstalled, isTrue);

    await pumpPage(tester);
    expect(find.text('No models installed'), findsNothing);
  });

  testWidgets('flags an install whose files went missing as incomplete',
      (WidgetTester tester) async {
    await controller.load();
    final package = controller.catalog
        .specForFamily('minimax_music3')!
        .recommendedPackage!;

    // Manifest only, no files: a directory someone deleted by hand. Loading
    // this would fail deep inside the engine, so it must read as incomplete.
    final manifest = controller.storage.manifestFileFor(package);
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString(
      '{"schema_version":1,"package_id":"${package.id}","repo":"r",'
      '"requested_revision":"main","resolved_revision":"abc",'
      '"installed_at_unix":1,"files":{}}',
    );

    await controller.refreshInstallState();

    expect(controller.statusFor(package.id)!.state, InstallState.incomplete);

    await pumpPage(tester);
    expect(find.text('Repair'), findsOneWidget);
  });
}
