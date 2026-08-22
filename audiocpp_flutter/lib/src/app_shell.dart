import 'dart:async';

import 'package:flutter/material.dart';

import 'create/create_page.dart';
import 'library/library_pane.dart';
import 'models/model_downloader.dart';
import 'models/model_library_controller.dart';
import 'models/model_storage.dart';
import 'models/models_page.dart';
import 'player/now_playing_bar.dart';
import 'player/playback_controller.dart';
import 'music_generation_controller.dart';
import 'tracks/generation_queue.dart';
import 'tracks/track.dart';
import 'tracks/track_store.dart';

/// Widths at which the layout changes.
///
/// Two numbers, one set of rules, one widget tree — the same build has to work
/// on a resized macOS window and on a phone, and a second mobile-only tree
/// would drift from this one within a week.
abstract final class Breakpoints {
  /// At or above this, the library sits beside the main pane.
  static const double threePane = 1200;

  /// Below this, the rail becomes a bottom bar.
  static const double compact = 840;
}

enum ShellPane { create, library, models }

/// Top-level navigation and the owner of everything long-lived.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ModelLibraryController? _models;
  GenerationQueue? _queue;
  MusicGenerationController? _engine;
  PlaybackController? _playback;

  /// Settings handed to the Create pane by "Remix these settings".
  ///
  /// Held here rather than pushed into the pane because at narrow widths the
  /// pane does not exist yet when the button is pressed.
  GenerationParams? _remix;

  ShellPane _pane = ShellPane.create;
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
      final models = ModelLibraryController(
        storage: storage,
        downloader: ModelDownloader(storage: storage),
      );
      await models.load();

      final store = await TrackStore.resolveDefault();
      await store.load();
      unawaited(store.pruneOrphanedAudio());

      final engine = MusicGenerationController();
      // Bring the worker isolate up now so a missing dylib or an unusable
      // backend surfaces before anyone has typed a prompt.
      unawaited(engine.initialise());

      final queue = GenerationQueue(
        store: store,
        engine: engine,
        resolveModelPath: (String packageId) async {
          for (final status in models.installed) {
            if (status.package.id == packageId) {
              return storage.modelPathFor(status.package);
            }
          }
          return null;
        },
      );
      queue.restore();

      final playback = PlaybackController(store: store);

      if (mounted) {
        setState(() {
          _models = models;
          _engine = engine;
          _queue = queue;
          _playback = playback;
          // Land on Models while nothing is installed: an empty Create pane is
          // a dead end.
          _pane = models.hasAnyInstalled ? ShellPane.create : ShellPane.models;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _startupError = '$error');
      }
    }
  }

  @override
  void dispose() {
    _playback?.dispose();
    _queue?.dispose();
    _engine?.dispose();
    _models?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

    final models = _models;
    final queue = _queue;
    final playback = _playback;
    if (models == null || queue == null || playback == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final compact = width < Breakpoints.compact;
        final threePane = width >= Breakpoints.threePane;

        // With the library permanently on screen there is nothing for its own
        // destination to do, so it is dropped rather than left as a no-op.
        final panes = <ShellPane>[
          ShellPane.create,
          if (!threePane) ShellPane.library,
          ShellPane.models,
        ];
        final selected = panes.contains(_pane) ? _pane : ShellPane.create;

        void remix(Track track) {
          setState(() {
            _remix = track.params;
            _pane = ShellPane.create;
          });
        }

        final main = switch (selected) {
          ShellPane.create => CreatePage(
              queue: queue,
              models: models,
              remix: _remix,
              onRemixApplied: () => setState(() => _remix = null),
              onBrowseModels: () => setState(() => _pane = ShellPane.models),
            ),
          ShellPane.library => LibraryPane(
              queue: queue,
              playback: playback,
              onRemix: remix,
            ),
          ShellPane.models => ModelsPage(controller: models),
        };

        final body = threePane
            ? Row(
                children: <Widget>[
                  Expanded(child: main),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 380,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: LibraryPane(
                        queue: queue,
                        playback: playback,
                        onRemix: remix,
                      ),
                    ),
                  ),
                ],
              )
            : main;

        // Playable order follows what the library shows, so "next" in the
        // player means the next row on screen.
        final playable = <Track>[
          for (final Track track in queue.tracks)
            if (track.hasAudio) track,
        ];

        Widget withPlayer(Widget content) => Column(
              children: <Widget>[
                Expanded(child: content),
                NowPlayingBar(playback: playback, playable: playable),
              ],
            );

        if (compact) {
          return Scaffold(
            body: SafeArea(bottom: false, child: withPlayer(body)),
            bottomNavigationBar: NavigationBar(
              selectedIndex: panes.indexOf(selected),
              onDestinationSelected: (int index) =>
                  setState(() => _pane = panes[index]),
              destinations: <Widget>[
                for (final ShellPane pane in panes)
                  NavigationDestination(
                    icon: Icon(_iconFor(pane, selected: false)),
                    selectedIcon: Icon(_iconFor(pane, selected: true)),
                    label: _labelFor(pane),
                  ),
              ],
            ),
          );
        }

        return Scaffold(
          body: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: panes.indexOf(selected),
                onDestinationSelected: (int index) =>
                    setState(() => _pane = panes[index]),
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Icon(Icons.graphic_eq),
                ),
                destinations: <NavigationRailDestination>[
                  for (final ShellPane pane in panes)
                    NavigationRailDestination(
                      icon: Icon(_iconFor(pane, selected: false)),
                      selectedIcon: Icon(_iconFor(pane, selected: true)),
                      label: Text(_labelFor(pane)),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: withPlayer(body)),
            ],
          ),
        );
      },
    );
  }

  static IconData _iconFor(ShellPane pane, {required bool selected}) {
    return switch (pane) {
      ShellPane.create =>
        selected ? Icons.auto_awesome : Icons.auto_awesome_outlined,
      ShellPane.library =>
        selected ? Icons.library_music : Icons.library_music_outlined,
      ShellPane.models => selected ? Icons.download : Icons.download_outlined,
    };
  }

  static String _labelFor(ShellPane pane) => switch (pane) {
        ShellPane.create => 'Create',
        ShellPane.library => 'Library',
        ShellPane.models => 'Models',
      };
}
