import 'dart:io';

import 'package:audiocpp_flutter/src/library/library_pane.dart';
import 'package:audiocpp_flutter/src/player/playback_controller.dart';
import 'package:audiocpp_flutter/src/theme/app_theme.dart';
import 'package:audiocpp_flutter/src/tracks/generation_queue.dart';
import 'package:audiocpp_flutter/src/tracks/track.dart';
import 'package:audiocpp_flutter/src/tracks/track_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

void main() {
  late Directory root;
  late TrackStore store;
  late FakeEngine engine;
  late GenerationQueue queue;
  late PlaybackController playback;
  Track? remixed;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audiocpp_library_test');
    store = TrackStore(root: root);
    await store.load();
    engine = FakeEngine();
    queue = GenerationQueue(
      store: store,
      engine: engine,
      resolveModelPath: (String id) async => '/models/$id',
    );
    queue.restore();
    // Never plays in these tests, so the platform player is never created.
    playback = PlaybackController(store: store);
    remixed = null;
  });

  tearDown(() async {
    // Let any held generation finish before the directory goes away — the run
    // still writes its output, and a half-torn-down store is not what these
    // tests are about.
    engine.release();
    for (var i = 0; i < 200 && queue.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    queue.dispose();
    playback.dispose();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: LibraryPane(
            queue: queue,
            playback: playback,
            onRemix: (Track track) => remixed = track,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Enqueues on the real event loop.
  ///
  /// `testWidgets` runs its body in a zone where timers are faked, and the
  /// store's file I/O never completes there — `runAsync` is what lets genuinely
  /// asynchronous work finish inside a widget test.
  Future<Track> enqueue(WidgetTester tester, String caption) async {
    final track = await tester.runAsync(
      () => queue.enqueue(
        // A caption distinct from the title, so a finder for one does not
        // also match the other.
        params: GenerationParams(caption: '$caption style, brushed drums',
            lyrics: ''),
        modelPackageId: 'minimax_music3_q4_0',
        title: caption,
      ),
    );
    return track!;
  }

  /// Lets a store mutation started by a tap run to completion.
  ///
  /// A tap runs in the zone where timers are faked, so everything after the
  /// store's `await` on a file write only resumes on a `pump()` — while the
  /// write itself only progresses in real time, which only `runAsync` allows.
  /// Neither alone gets there: a single `runAsync` leaves the continuation
  /// parked, and pumping alone never lets the write finish. Alternating does.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  testWidgets('empty library explains what to do', (WidgetTester tester) async {
    await show(tester);
    expect(find.textContaining('Nothing here yet'), findsOneWidget);
  });

  testWidgets('a queued track appears immediately', (WidgetTester tester) async {
    engine.hold();
    await enqueue(tester, 'first');
    await enqueue(tester, 'second');
    await show(tester);

    expect(find.text('first'), findsWidgets);
    // Waiting tracks live in the queue section, not the library list.
    expect(find.text('second'), findsOneWidget);
    expect(find.text('UP NEXT · 1'), findsOneWidget);
    // The running track gets the strip at the top rather than a plain row.
    expect(find.text('Generating'), findsOneWidget);
  });

  testWidgets('discarding a running track takes it out of the library at once',
      (WidgetTester tester) async {
    engine.hold();
    final track = await enqueue(tester, 'first');
    await show(tester);

    await tester.tap(find.text('Discard'));
    await settle(tester);

    // The track is gone from the pane entirely — strip, queue and list.
    expect(find.text('first'), findsNothing);
    expect(find.text('Generating'), findsNothing);
    // What remains is the engine, still busy on work nobody wants.
    expect(find.text('Discarded'), findsOneWidget);
    expect(find.textContaining('cannot be interrupted'), findsOneWidget);
    expect(queue.isAbandoned(track.id), isTrue);
  });

  testWidgets('clearing the queue leaves the running track alone',
      (WidgetTester tester) async {
    engine.hold();
    await enqueue(tester, 'running');
    await enqueue(tester, 'waiting');
    await show(tester);

    expect(find.text('UP NEXT · 1'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await settle(tester);

    expect(find.text('waiting'), findsNothing);
    expect(find.text('UP NEXT · 1'), findsNothing);
    // The one already generating is untouched: it cannot be stopped, and the
    // Clear button does not pretend otherwise.
    expect(find.text('Generating'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
  });

  testWidgets('a failed track shows its error and offers a retry',
      (WidgetTester tester) async {
    engine.failCaptions.add('bad');
    await enqueue(tester, 'bad');
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && queue.isBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await show(tester);

    expect(find.textContaining('out of memory'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the row menu offers the actions for a finished track',
      (WidgetTester tester) async {
    await enqueue(tester, 'second');
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && queue.isBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await show(tester);

    final row = find
        .ancestor(of: find.text('second'), matching: find.byType(Row))
        .first;
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_horiz)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remix these settings'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Remix these settings'));
    await tester.pump();
    expect(remixed?.title, 'second');
  });

  testWidgets('the queue section lists waiting tracks in order and can drag',
      (WidgetTester tester) async {
    engine.hold();
    await enqueue(tester, 'running');
    await enqueue(tester, 'b');
    await enqueue(tester, 'c');
    await show(tester);

    expect(find.text('UP NEXT · 2'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));

    // Drag c above b. The queue's own indices include the running track, so
    // this also covers the offset the section applies.
    final handle = find.byIcon(Icons.drag_indicator).last;
    await tester.drag(handle, const Offset(0, -40));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();

    expect(
      queue.pending.map((Track t) => t.title),
      <String>['running', 'c', 'b'],
    );
  });

  testWidgets('a deleted track leaves the list', (WidgetTester tester) async {
    final second = await enqueue(tester, 'second');
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && queue.isBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await show(tester);
    expect(find.text('second'), findsOneWidget);

    // Driven through the controller rather than the menu: deletion itself is
    // covered by the queue's own tests, and what matters here is that the pane
    // notices. Real time has to pass for the disk work behind it to finish.
    await tester.runAsync(() async {
      await queue.delete(second.id);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();

    expect(find.text('second'), findsNothing);
    expect(find.text('0 tracks'), findsOneWidget);
  });
}
