/// Turns an engine failure into something a person can act on.
///
/// The engine's own text names the component that failed, which is right for a
/// log and wrong for a library row. Each case here pairs a plain sentence with
/// the thing to try next; anything unrecognised falls through unchanged rather
/// than being flattened into "something went wrong".
class FailureMessage {
  const FailureMessage({required this.summary, this.suggestion, this.detail});

  /// One sentence, no jargon.
  final String summary;

  /// What to do about it, when there is something to do.
  final String? suggestion;

  /// The original text, kept for the tooltip and for bug reports.
  final String? detail;

  static FailureMessage from(String raw) {
    final text = raw.toLowerCase();

    if (text.contains('not installed')) {
      return FailureMessage(
        summary: 'That model is not installed.',
        suggestion: 'Install it from Models, then retry.',
        detail: raw,
      );
    }
    if (text.contains('out of memory') ||
        text.contains('oom') ||
        text.contains('failed to allocate') ||
        text.contains('cannot allocate')) {
      return FailureMessage(
        summary: 'Ran out of memory while generating.',
        suggestion: 'Try a shorter length budget or fewer inference steps.',
        detail: raw,
      );
    }
    if (text.contains('interrupted')) {
      return FailureMessage(
        summary: 'Interrupted — the app closed while this was generating.',
        suggestion: 'Retry when you are ready.',
        detail: raw,
      );
    }
    if (text.contains('audio file is missing') || text.contains('no such file')) {
      return FailureMessage(
        summary: 'The audio file is missing.',
        suggestion: 'Retry to generate it again.',
        detail: raw,
      );
    }
    if (text.contains('lyrics')) {
      return FailureMessage(
        summary: 'The model rejected the lyrics.',
        suggestion: 'This model needs lyrics; check they are not empty.',
        detail: raw,
      );
    }
    if (text.contains('load a model')) {
      return FailureMessage(
        summary: 'No model was loaded.',
        suggestion: 'Pick a model in Create and retry.',
        detail: raw,
      );
    }
    return FailureMessage(summary: raw, detail: raw);
  }

  /// Summary and suggestion on one line, for a compact row.
  String get oneLine =>
      suggestion == null ? summary : '$summary $suggestion';
}
