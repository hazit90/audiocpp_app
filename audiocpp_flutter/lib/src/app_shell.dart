import 'dart:async';

import 'package:flutter/material.dart';

import 'models/model_downloader.dart';
import 'models/model_library_controller.dart';
import 'models/model_storage.dart';
import 'models/models_page.dart';
import 'music_generation_page.dart';

/// Top-level navigation.
///
/// Models comes first while nothing is installed: generation cannot do anything
/// useful until a package is on disk, and sending people to an empty Create
/// screen would just be a dead end.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ModelLibraryController? _models;
  int _index = 0;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    unawaited(_initialise());
  }

  Future<void> _initialise() async {
    try {
      final storage = await ModelStorage.resolveDefault();
      await storage.ensureExists();
      final controller = ModelLibraryController(
        storage: storage,
        downloader: ModelDownloader(storage: storage),
      );
      await controller.load();
      if (mounted) {
        setState(() => _models = controller);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _startupError = '$error');
      }
    }
  }

  @override
  void dispose() {
    _models?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final error = _startupError;

    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SelectableText('Could not start: $error'),
          ),
        ),
      );
    }
    if (models == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (int value) => setState(() => _index = value),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Icon(Icons.graphic_eq),
            ),
            destinations: const <NavigationRailDestination>[
              NavigationRailDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: Text('Models'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.music_note_outlined),
                selectedIcon: Icon(Icons.music_note),
                label: Text('Create'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: switch (_index) {
              0 => ModelsPage(controller: models),
              _ => const MusicGenerationPage(),
            },
          ),
        ],
      ),
    );
  }
}
