#
# CocoaPods spec for the macOS side of the `audiocpp` FFI plugin.
#
# This pod does not compile audio.cpp. It vendors the dylib produced by
# tool/build_macos.sh, so Xcode links and embeds a prebuilt binary instead of
# rebuilding a multi-minute C++ tree on every Flutter build.
#
# Run `packages/audiocpp/tool/build_macos.sh` before building the app.
#
Pod::Spec.new do |s|
  s.name             = 'audiocpp'
  s.version          = '0.1.0'
  s.summary          = 'Dart FFI bindings for the audio.cpp inference engine.'
  s.description      = <<-DESC
Vendors libaudiocpp_ffi.dylib, a stable C ABI over the audio.cpp C++ engine,
for use from Dart via dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/0xShug0/audio.cpp'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'audiocpp_app' => 'hazit90@googlemail.com' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '13.3'
  s.dependency 'FlutterMacOS'

  # Placeholder translation unit: CocoaPods requires at least one source file
  # for a pod target, and everything real lives in the vendored dylib.
  s.source_files     = 'Classes/**/*'

  s.vendored_libraries = 'Libs/libaudiocpp_ffi.dylib'

  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=macosx*]' => 'i386'
  }
end
