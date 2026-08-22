import 'dart:math';
import 'dart:typed_data';

/// Number of peak buckets stored per track.
///
/// About one bar every three pixels in a full-width player, which is enough to
/// read the shape of a track and cheap enough to keep in the index — 200 bytes
/// per track against several megabytes of audio.
const int kPeakCount = 200;

/// Reduces PCM samples to [kPeakCount] amplitude buckets, each 0-255.
///
/// Peak rather than RMS: this is a navigation aid, and peaks make transients —
/// a drum hit, the start of a vocal — visible at this resolution, which is what
/// makes a waveform worth scrubbing against.
///
/// Interleaved channels are folded together, since the display is mono.
List<int> reducePeaks(Float32List samples, {int buckets = kPeakCount}) {
  if (samples.isEmpty || buckets <= 0) {
    return List<int>.filled(buckets < 0 ? 0 : buckets, 0);
  }

  final peaks = List<int>.filled(buckets, 0);
  final perBucket = samples.length / buckets;

  for (var i = 0; i < buckets; i++) {
    final start = (i * perBucket).floor();
    final end = min(samples.length, ((i + 1) * perBucket).ceil());
    var peak = 0.0;
    for (var j = start; j < end; j++) {
      final value = samples[j].abs();
      if (value > peak) {
        peak = value;
      }
    }
    // Clamped rather than normalised against the loudest bucket: a track that
    // is quiet throughout should look quiet, not be stretched to full height.
    peaks[i] = (peak.clamp(0.0, 1.0) * 255).round();
  }
  return peaks;
}
