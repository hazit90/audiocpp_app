import 'package:audiocpp_flutter/src/create/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('composeCaption', () {
    test('keeps the prose when there are no tags', () {
      expect(
        composeCaption(described: 'A bright pop song.', tags: <String>[]),
        'A bright pop song.',
      );
    });

    test('appends tags to the prose rather than replacing it', () {
      expect(
        composeCaption(described: 'A bright song', tags: <String>['jazz']),
        'A bright song, jazz',
      );
    });

    test('does not double up a tag the prose already mentions', () {
      expect(
        composeCaption(
          described: 'A jazz trio, brushed drums',
          tags: <String>['jazz', 'lo-fi'],
        ),
        'A jazz trio, brushed drums, lo-fi',
      );
    });

    test('tags alone are a valid caption', () {
      expect(
        composeCaption(described: '   ', tags: <String>['ambient', 'cinematic']),
        'ambient, cinematic',
      );
    });

    test('does not produce a double separator after a full stop', () {
      expect(
        composeCaption(described: 'Soft and slow.', tags: <String>['ambient']),
        'Soft and slow. ambient',
      );
    });
  });

  group('deriveTitle', () {
    test('skips filler words', () {
      expect(
        deriveTitle('A bright pop rock song with clean drums'),
        'Pop Rock Drums',
      );
    });

    test('handles punctuation and casing', () {
      expect(deriveTitle('FILM SCORE, strings & brass'), 'Film Score Strings');
    });

    test('falls back rather than returning an empty title', () {
      expect(deriveTitle('a the of'), 'Untitled');
      expect(deriveTitle(''), 'Untitled');
    });

    test('different captions give different titles', () {
      expect(
        deriveTitle('hip hop trap beat'),
        isNot(deriveTitle('ambient textural drone')),
      );
    });
  });
}
