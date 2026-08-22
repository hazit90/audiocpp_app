import 'package:audiocpp_flutter/src/player/now_playing_bar.dart';
import 'package:audiocpp_flutter/src/theme/app_theme.dart';
import 'package:audiocpp_flutter/src/tracks/track.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The player bar is the densest row in the app; these pin the two failures it
/// actually shipped with — a misparented Flexible and an 85px overflow.
void main() {
  final track = Track(
    id: 'a',
    title: 'Neon Overpass',
    params: const GenerationParams(
      caption: 'A bright pop rock song with crisp rhythm guitars, a clear '
          'female vocal, and polished studio production.',
      lyrics: '',
      seed: 41207,
    ),
    modelPackageId: 'minimax_music3_q4_0',
    createdAt: DateTime.now(),
    status: TrackStatus.done,
    audioFileName: 'a.wav',
    duration: const Duration(seconds: 32),
    peaks: List<int>.generate(200, (int i) => (i * 7) % 255),
  );

  Future<void> showAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const Spacer(),
              PlayerBarContent(
                track: track,
                position: const Duration(seconds: 12),
                duration: const Duration(seconds: 32),
                progress: 0.375,
                isPlaying: true,
                onToggle: () {},
                onPrevious: () {},
                onNext: () {},
                onSeek: (double _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final double width in <double>[1440, 1200, 900, 760, 700, 500, 380]) {
    testWidgets('lays out without overflowing at ${width.toInt()}px',
        (WidgetTester tester) async {
      await showAt(tester, width);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide shows the waveform and both times',
      (WidgetTester tester) async {
    await showAt(tester, 1200);

    expect(find.text('12s'), findsOneWidget);
    expect(find.text('32s'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('narrow drops the waveform for a progress line',
      (WidgetTester tester) async {
    await showAt(tester, 500);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('12s'), findsNothing);
    // The transport survives at every width — it is the point of the bar.
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('transport buttons fire', (WidgetTester tester) async {
    var toggled = 0;
    var nexts = 0;
    tester.view.physicalSize = const Size(1200, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PlayerBarContent(
              track: track,
              position: Duration.zero,
              duration: const Duration(seconds: 32),
              progress: 0,
              isPlaying: false,
              onToggle: () => toggled++,
              onPrevious: () {},
              onNext: () => nexts++,
              onSeek: (double _) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.pump();

    expect(toggled, 1);
    expect(nexts, 1);
  });
}
