import 'package:audiocpp_flutter/src/tracks/failure_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('memory failures suggest smaller settings', () {
    final message = FailureMessage.from(
      'audiocpp: ggml_backend_alloc failed to allocate 4096 MB on MTL:0',
    );

    expect(message.summary, contains('memory'));
    expect(message.suggestion, contains('shorter'));
    // The engine's own words survive for the tooltip.
    expect(message.detail, contains('ggml_backend_alloc'));
  });

  test('a missing model points at the Models screen', () {
    final message = FailureMessage.from(
      'Model package "minimax_music3_q4_0" is not installed. Install it from '
      'Models and retry this track.',
    );

    expect(message.summary, contains('not installed'));
    expect(message.suggestion, contains('Models'));
  });

  test('an interrupted run explains itself', () {
    final message = FailureMessage.from(
      'Interrupted — the app closed while this was generating.',
    );

    expect(message.summary, contains('Interrupted'));
    expect(message.suggestion, isNotNull);
  });

  test('anything unrecognised is passed through, not flattened', () {
    const raw = 'engine_runtime: flow sampler produced no frames';
    final message = FailureMessage.from(raw);

    expect(message.summary, raw);
    expect(message.suggestion, isNull);
  });

  test('oneLine joins summary and suggestion', () {
    final message = FailureMessage.from('out of memory');

    expect(message.oneLine, startsWith(message.summary));
    expect(message.oneLine, contains(message.suggestion!));
  });
}
