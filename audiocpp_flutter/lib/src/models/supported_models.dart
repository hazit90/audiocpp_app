/// Families this app can actually run.
///
/// Availability is a decision we make, not something discovered at runtime.
/// Three things have to agree before a family works, and this list is the one
/// a person reads:
///
///  1. it is linked into the native library — `AUDIOCPP_MODELS` in
///     `packages/audiocpp/tool/build_macos.sh`;
///  2. its spec is present in `assets/model_specs/`, copied by hand from
///     `third_party/audio.cpp/model_specs/`;
///  3. the Create pane knows how to build its request — today that is
///     `MiniMaxMusic3Request` and nothing else.
///
/// Adding a family means doing all three, not just this list. Until then it is
/// not offered for download: a 14 GB download for something that cannot load is
/// worse than not showing it at all.
const Set<String> kSupportedFamilies = <String>{
  'minimax_music3',
};
