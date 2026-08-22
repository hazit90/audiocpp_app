import 'dart:math';
import 'dart:typed_data';

import 'package:audiocpp_flutter/src/tracks/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('produces the requested number of buckets', () {
    final samples = Float32List.fromList(
      List<double>.generate(44100, (int i) => sin(i / 20)),
    );
    expect(reducePeaks(samples), hasLength(kPeakCount));
    expect(reducePeaks(samples, buckets: 32), hasLength(32));
  });

  test('silence reads as zero and full scale as 255', () {
    expect(
      reducePeaks(Float32List(1000), buckets: 4),
      <int>[0, 0, 0, 0],
    );
    expect(
      reducePeaks(Float32List.fromList(List<double>.filled(1000, 1)),
          buckets: 4),
      <int>[255, 255, 255, 255],
    );
  });

  test('a quiet track stays quiet rather than being normalised', () {
    final quiet = Float32List.fromList(List<double>.filled(1000, 0.1));
    expect(reducePeaks(quiet, buckets: 4).first, closeTo(26, 1));
  });

  test('follows the envelope: a burst shows only in its own bucket', () {
    final samples = Float32List(400);
    for (var i = 200; i < 300; i++) {
      samples[i] = 0.9;
    }
    final peaks = reducePeaks(samples, buckets: 4);
    // 229, not 230: float32 stores 0.9 as 0.899999976.
    expect(peaks, <int>[0, 0, 229, 0]);
  });

  test('negative swings count: peak is absolute', () {
    final samples = Float32List.fromList(<double>[-1, 0, 0, 0]);
    expect(reducePeaks(samples, buckets: 1), <int>[255]);
  });

  test('empty input is not a crash', () {
    expect(reducePeaks(Float32List(0), buckets: 8), List<int>.filled(8, 0));
  });
}
