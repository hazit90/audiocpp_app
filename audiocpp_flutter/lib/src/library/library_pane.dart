import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../create/enqueue_button.dart' show formatDuration;
import '../platform/reveal.dart';
import '../player/playback_controller.dart';
import '../theme/app_theme.dart';
import '../tracks/failure_message.dart';
import '../tracks/generation_queue.dart';
import '../tracks/track.dart';
import 'track_artwork.dart';

/// The library: the queue at the top, everything generated below it.
class LibraryPane extends StatefulWidget {
  const LibraryPane({
    required this.queue,
    required this.playback,
    this.onRemix,
    super.key,
  });

  final GenerationQueue queue;
  final PlaybackController playback;

  /// Loads a track's settings back into the Create form.
  final ValueChanged<Track>? onRemix;

  @override
  State<LibraryPane> createState() => _LibraryPaneState();
}

class _LibraryPaneState extends State<LibraryPane> {
  final TextEditingController _search = TextEditingController();
  bool _favouritesOnly = false;

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_onChanged);
    widget.playback.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.queue.removeListener(_onChanged);
    widget.playback.removeListener(_onChanged);
    _search.dispose();
    super.dispose();
  }

  /// Finished tracks after the search box and the favourites filter.
  ///
  /// Matches title and caption: people remember what they asked for more often
  /// than they remember the name the app derived from it.
  List<Track> _visible(List<Track> all) {
    final query = _search.text.trim().toLowerCase();
    return all.where((Track track) {
      if (track.isPending) {
        return false;
      }
      if (_favouritesOnly && !track.favourite) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return track.title.toLowerCase().contains(query) ||
          track.params.caption.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = widget.queue;
    // Pending tracks live in the queue section above; the list below is the
    // library proper, so a track does not appear in two places at once.
    final finished = queue.tracks
        .where((Track track) => !track.isPending)
        .toList(growable: false);
    final tracks = _visible(queue.tracks);
    final filtered = tracks.length != finished.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Library', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    filtered
                        ? '${tracks.length} of ${finished.length}'
                        : '${finished.length} track'
                            '${finished.length == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (finished.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _search,
                          onChanged: (String _) => setState(() {}),
                          textAlignVertical: TextAlignVertical.center,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search',
                            prefixIcon: const Icon(Icons.search, size: 17),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    iconSize: 15,
                                    icon: const Icon(Icons.clear),
                                    onPressed: () => setState(_search.clear),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: _favouritesOnly
                          ? 'Showing favourites'
                          : 'Show favourites only',
                      isSelected: _favouritesOnly,
                      onPressed: () => setState(
                        () => _favouritesOnly = !_favouritesOnly,
                      ),
                      icon: const Icon(Icons.star_border),
                      selectedIcon: const Icon(
                        Icons.star,
                        color: AppTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (queue.running case final Track running)
          _RunningStrip(queue: queue, track: running)
        // The track is already gone; this is about the machine still being busy
        // with it, which is why it carries no title and no controls.
        else if (queue.isStopping)
          _StoppingStrip(queue: queue),
        if (queue.waitingCount > 0) _QueueSection(queue: queue),
        const Divider(),
        Expanded(
          child: tracks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      finished.isEmpty
                          ? 'Nothing here yet. Describe a track and add it to '
                              'the queue.'
                          : 'No tracks match.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 24),
                  itemCount: tracks.length,
                  itemBuilder: (BuildContext context, int index) => _TrackRow(
                    track: tracks[index],
                    queue: queue,
                    playback: widget.playback,
                    onRemix: widget.onRemix,
                  ),
                ),
        ),
      ],
    );
  }
}

/// The tracks waiting their turn, in the order they will run.
///
/// Drag to reorder. Only the queued ones move: the running track cannot be
/// displaced, because it is already in the engine. Discard stops it instead.
class _QueueSection extends StatelessWidget {
  const _QueueSection({required this.queue});

  final GenerationQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = queue.pending
        .where((Track track) => track.status == TrackStatus.queued)
        .toList(growable: false);
    final runningOffset = queue.running == null ? 0 : 1;

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: <Widget>[
                Text(
                  'UP NEXT · ${waiting.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                // Clearing the queue is the only stop the app can honestly
                // offer: what has started cannot be interrupted, but nothing
                // after it has to happen.
                TextButton(
                  onPressed: queue.clearQueue,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                    textStyle: theme.textTheme.labelSmall,
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: waiting.length,
              onReorder: (int oldIndex, int newIndex) => queue.reorder(
                // The queue indexes the running track too, so shift past it.
                oldIndex + runningOffset,
                newIndex + runningOffset,
              ),
              itemBuilder: (BuildContext context, int index) {
                final track = waiting[index];
                return _QueuedRow(
                  key: ValueKey<String>(track.id),
                  track: track,
                  position: index,
                  queue: queue,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({
    required this.track,
    required this.position,
    required this.queue,
    super.key,
  });

  final Track track;
  final int position;
  final GenerationQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: <Widget>[
          ReorderableDragStartListener(
            index: position,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Icon(
                Icons.drag_indicator,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            '${position + 1}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              track.title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          IconButton(
            tooltip: 'Remove from queue',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () => queue.cancel(track.id),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// What the engine is doing right now.
class _RunningStrip extends StatelessWidget {
  const _RunningStrip({required this.queue, required this.track});

  final GenerationQueue queue;

  /// Passed in rather than read back off the queue: a run can finish between
  /// the check and the build, and a `!` there would be a crash rather than a
  /// stale frame.
  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = queue.runningElapsed;
    final remaining = queue.runningEstimatedRemaining;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      color: AppTheme.accent.withValues(alpha: 0.06),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Generating',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppTheme.accent,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                <String>[
                  if (elapsed != null) formatDuration(elapsed),
                  // No progress callback exists in the ABI, so anything beyond
                  // elapsed time is an extrapolation and is labelled as one.
                  if (remaining != null) '~${formatDuration(remaining)} left',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(track.title, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => queue.cancel(track.id),
              child: const Text('Stop'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown only when a stop is taking longer than usual.
///
/// The track is gone the moment it is stopped, so nothing here names it. What
/// is left to report is that the machine is not free yet, which happens when a
/// run is already past its last check and finishes on its own. That is
/// invisible from outside and would otherwise read as the app hanging.
class _StoppingStrip extends StatelessWidget {
  const _StoppingStrip({required this.queue});

  final GenerationQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = queue.runningElapsed;
    final remaining = queue.runningEstimatedRemaining;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      // The raised panel colour rather than the accent tint the running strip
      // uses: this still has to read as its own region, but it is no longer
      // something the user is waiting on.
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Stopping',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: muted,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                <String>[
                  if (elapsed != null) formatDuration(elapsed),
                  if (remaining != null) '~${formatDuration(remaining)} left',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            queue.waitingCount > 0
                ? 'The engine stops at the end of the current step. The next '
                    'track starts then.'
                : 'The engine stops at the end of the current step.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            minHeight: 3,
            color: muted,
            backgroundColor: muted.withValues(alpha: 0.15),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.queue,
    required this.playback,
    required this.onRemix,
  });

  final Track track;
  final GenerationQueue queue;
  final PlaybackController playback;
  final ValueChanged<Track>? onRemix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = playback.isCurrent(track);

    return Material(
      color: isCurrent
          ? theme.colorScheme.surfaceContainerHighest
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: track.hasAudio ? () => playback.playOrToggle(track) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: <Widget>[
              _Thumbnail(track: track, playback: playback),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: isCurrent ? AppTheme.accent : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.params.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _StatusLine(track: track, queue: queue),
                  ],
                ),
              ),
              IconButton(
                tooltip: track.favourite ? 'Remove favourite' : 'Favourite',
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                onPressed: () => queue.setFavourite(track.id, !track.favourite),
                icon: Icon(
                  track.favourite ? Icons.star : Icons.star_border,
                  color: track.favourite ? AppTheme.accent : null,
                ),
              ),
              _RowMenu(
                track: track,
                queue: queue,
                playback: playback,
                onRemix: onRemix,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Artwork that doubles as the play control once a track has audio.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.track, required this.playback});

  final Track track;
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final playing = playback.isCurrent(track) && playback.isPlaying;

    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          TrackArtwork(track: track),
          if (track.hasAudio)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({
    required this.track,
    required this.queue,
    required this.playback,
    required this.onRemix,
  });

  final Track track;
  final GenerationQueue queue;
  final PlaybackController playback;
  final ValueChanged<Track>? onRemix;

  /// Renames the track, replacing the title derived from the caption.
  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: track.title);
    final title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (String value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null) {
      // Blank titles are ignored by the queue rather than rejected here, so
      // clearing the field simply leaves the name alone.
      await queue.rename(track.id, title);
    }
  }

  Future<void> _reveal(BuildContext context) async {
    final file = queue.store.audioFileFor(track);
    if (file == null || !file.existsSync()) {
      return;
    }
    await revealFile(file);
  }

  Future<void> _delete() async {
    if (playback.isCurrent(track)) {
      await playback.clear();
    }
    await queue.delete(track.id);
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined, size: 18),
          onPressed: () => _rename(context),
          child: const Text('Rename'),
        ),
        if (onRemix != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.tune, size: 18),
            onPressed: () => onRemix!(track),
            child: const Text('Remix these settings'),
          ),
        if (track.hasAudio && canRevealInFileManager)
          MenuItemButton(
            leadingIcon: const Icon(Icons.folder_open, size: 18),
            onPressed: () => _reveal(context),
            child: Text('Reveal in $fileManagerName'),
          ),
        if (track.status == TrackStatus.failed)
          MenuItemButton(
            leadingIcon: const Icon(Icons.refresh, size: 18),
            onPressed: () => queue.retry(track.id),
            child: const Text('Retry'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline, size: 18),
          onPressed: _delete,
          child: const Text('Delete'),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return IconButton(
          tooltip: 'More',
          iconSize: 18,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.more_horiz),
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.track, required this.queue});

  final Track track;
  final GenerationQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    switch (track.status) {
      case TrackStatus.queued:
        return Text('Queued', style: style);
      case TrackStatus.running:
        return Text('Generating…',
            style: style?.copyWith(color: AppTheme.accent));
      case TrackStatus.done:
        return Text(
          <String>[
            if (track.duration != null) formatDuration(track.duration!),
            'seed ${track.params.seed}',
          ].join(' · '),
          style: style,
        );
      case TrackStatus.failed:
        final failure = FailureMessage.from(track.errorMessage ?? 'Failed');
        return Row(
          children: <Widget>[
            Flexible(
              // The engine's own text stays reachable two ways: a tooltip for a
              // pointer, and a tap for a finger. A tooltip alone is useless on
              // a touch device, and this row is exactly where an unrecognised
              // engine failure gets truncated to nothing usable.
              child: Tooltip(
                message: failure.detail ?? failure.summary,
                child: InkWell(
                  onTap: () => _showFailureDetail(context, track, failure),
                  child: Text(
                    failure.oneLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style?.copyWith(
                      color: theme.colorScheme.error,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => queue.retry(track.id),
              child: const Text('Retry'),
            ),
          ],
        );
    }
  }

  /// Shows the engine's own words, in full and selectable.
  ///
  /// [FailureMessage] deliberately rewrites what it recognises, but anything it
  /// does not falls through as raw engine text -- which is long, starts with a
  /// container path on iOS, and is the only thing that says what actually went
  /// wrong. Two ellipsised lines are not enough to debug from.
  void _showFailureDetail(
    BuildContext context,
    Track track,
    FailureMessage failure,
  ) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(track.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(failure.summary),
              if (failure.suggestion != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(failure.suggestion!),
              ],
              if (failure.detail != null &&
                  failure.detail != failure.summary) ...<Widget>[
                const SizedBox(height: 16),
                SelectableText(
                  failure.detail!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: failure.detail ?? failure.summary));
              Navigator.of(context).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
