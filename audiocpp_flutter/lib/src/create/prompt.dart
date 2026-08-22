/// Style chips offered on the Style tab.
///
/// Deliberately short and genre-led. The model conditions on free text, so
/// these are a starting point people edit, not a taxonomy it understands.
const List<String> kStyleTags = <String>[
  'pop rock',
  'electronic',
  'hip hop',
  'jazz',
  'classical',
  'film score',
  'lo-fi',
  'ambient',
  'folk',
  'funk',
  'metal',
  'world',
  'female vocal',
  'male vocal',
  'instrumental',
  'upbeat',
  'melancholic',
  'cinematic',
];

/// Builds the caption sent to the engine.
///
/// Chips are appended to whatever was typed rather than replacing it: the two
/// tabs are two ways of describing the same track, and silently dropping the
/// prose someone wrote because they then tapped a chip would be worse than a
/// slightly redundant caption.
String composeCaption({required String described, required List<String> tags}) {
  final prose = described.trim();
  final extra = tags.where((String tag) => !_mentions(prose, tag)).toList();
  if (extra.isEmpty) {
    return prose;
  }
  final joined = extra.join(', ');
  if (prose.isEmpty) {
    return joined;
  }
  return prose.endsWith('.') || prose.endsWith(',')
      ? '$prose $joined'
      : '$prose, $joined';
}

bool _mentions(String prose, String tag) =>
    prose.toLowerCase().contains(tag.toLowerCase());

/// Words too generic to make a title out of.
const Set<String> _stopWords = <String>{
  'a', 'an', 'the', 'with', 'and', 'of', 'for', 'in', 'on', 'to', 'song',
  'track', 'music', 'clean', 'clear', 'bright', 'polished', 'studio',
  'production', 'style', 'sound', 'vocal', 'vocals',
};

/// Derives a track title from the caption.
///
/// A placeholder, not a naming feature: the point is that a library of forty
/// tracks does not read as forty rows of the same first eight words. Renaming
/// is one tap away, and the caption is still shown underneath.
String deriveTitle(String caption) {
  final words = caption
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s-]'), ' ')
      .split(RegExp(r'\s+'))
      .where((String word) => word.length > 2 && !_stopWords.contains(word))
      .toList();

  if (words.isEmpty) {
    return 'Untitled';
  }

  final picked = words.take(3).map(
        (String word) => word[0].toUpperCase() + word.substring(1),
      );
  return picked.join(' ');
}
