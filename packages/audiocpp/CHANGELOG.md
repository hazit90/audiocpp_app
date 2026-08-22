# Changelog

## 0.1.0

Initial release.

- C ABI (`audiocpp_ffi.h`, ABI 1.0) over the audio.cpp C++ runtime: model
  loading, offline task sessions, audio results, device enumeration.
- ffigen-generated low-level bindings.
- `AudioCppEngine` async API backed by a dedicated worker isolate.
- `MiniMaxMusic3Request` typed request builder.
- macOS build script with Metal support and a CocoaPods podspec that vendors
  the resulting dylib.
