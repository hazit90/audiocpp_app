#
# CocoaPods spec for the iOS side of the `audiocpp` FFI plugin.
#
# This pod does not compile audio.cpp. It vendors the xcframework produced by
# tool/build_ios.sh, so Xcode links a prebuilt binary instead of rebuilding a
# multi-minute C++ tree on every Flutter build.
#
# Unlike macOS, the binary is a *static* library inside an .xcframework: that is
# Apple's distribution format for a prebuilt library, and a static slice has
# nothing to embed in the .app and nothing to code-sign.
#
# Run `packages/audiocpp/tool/build_ios.sh` before building the app.
#
Pod::Spec.new do |s|
  s.name             = 'audiocpp'
  s.version          = '0.1.0'
  s.summary          = 'Dart FFI bindings for the audio.cpp inference engine.'
  s.description      = <<-DESC
Vendors audiocpp.xcframework, a stable C ABI over the audio.cpp C++ engine,
for use from Dart via dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/0xShug0/audio.cpp'
  s.license          = { :type => 'MIT' }
  s.author           = { 'audiocpp_app' => 'hazit90@googlemail.com' }
  s.source           = { :path => '.' }

  # audio.cpp calls std::to_chars on floats, which libc++ only exposes from
  # iOS 16.3. Must match DEPLOYMENT_TARGET in tool/build_ios.sh, the app's
  # IPHONEOS_DEPLOYMENT_TARGET, and `platform :ios` in the Podfile.
  s.platform         = :ios, '16.3'
  s.dependency 'Flutter'

  # Placeholder translation unit: CocoaPods requires at least one source file
  # for a pod target, and everything real lives in the vendored xcframework.
  s.source_files     = 'Classes/**/*'

  s.vendored_frameworks = 'Frameworks/audiocpp.xcframework'

  # The Podfile says use_frameworks!, which would otherwise build this pod as a
  # dynamic framework -- one that contains nothing but the placeholder source
  # above, yet still gets embedded and signed. Static keeps the app free of it.
  s.static_framework = true

  # The static slice pulls these in: Accelerate for ggml's BLAS backend, Metal
  # and Foundation for ggml-metal. A static library cannot record its own
  # dependencies, so the host target has to link them.
  s.frameworks       = 'Accelerate', 'Metal', 'MetalKit', 'Foundation'
  s.libraries        = 'c++'

  # Two separate problems keep the entry points out of the app, and each needs
  # its own flag.
  #
  # 1. Archive member selection. Dart reaches the entry points through dlsym, so
  #    nothing references them at link time and the linker would not pull their
  #    object file out of the archive at all. -force_load loads every member.
  #
  # 2. Dead stripping. Release builds pass -dead_strip, which then removes the
  #    very symbols -force_load just brought in, for the same reason: nothing
  #    reaches them. -u makes each one an undefined symbol the link must
  #    resolve, which makes it a dead-strip root and keeps it (and everything it
  #    calls) alive. Without this the app links clean and fails at runtime.
  #
  # The list is read from the header rather than written out here, so adding an
  # AUDIOCPP_API function cannot silently leave it unreachable on iOS.
  header = File.expand_path('../src/include/audiocpp_ffi.h', __dir__)
  entry_points = File.read(header).scan(/^AUDIOCPP_API\s+(?:[\w\s*\/]*?)\b(audiocpp_\w+)\s*\(/).flatten.uniq
  raise "no AUDIOCPP_API entry points found in #{header}" if entry_points.empty?
  # -Wl,-u,_sym rather than the plain `-u _sym`: CocoaPods parses OTHER_LDFLAGS
  # into a set of flags and de-duplicates them, so eighteen `-u` flags collapse
  # into one and seventeen entry points quietly vanish. One token per symbol
  # keeps them all distinct.
  keep_alive = entry_points.map { |name| "-Wl,-u,_#{name}" }.join(' ')

  # The slice directory differs per SDK, but OTHER_LDFLAGS itself must stay
  # unconditional: an `OTHER_LDFLAGS[sdk=...]` line *replaces* the unconditional
  # one rather than adding to it, which silently drops every other pod's linker
  # flags. So only the slice name is conditional, and CocoaPods merges the
  # -force_load into the OTHER_LDFLAGS it generates.
  #
  # -force_load points into the vendored xcframework rather than at the copy
  # CocoaPods unpacks into PODS_XCFRAMEWORKS_BUILD_DIR. That copy is made by a
  # script phase on this pod's target, but Xcode validates the *app* target's
  # linker inputs before that phase runs, so a clean build fails with "Build
  # input file cannot be found". The source slice is already on disk before the
  # build starts, so nothing has to be ordered.
  xcframework = '$(PODS_ROOT)/../.symlinks/plugins/audiocpp/ios/Frameworks/audiocpp.xcframework'
  s.user_target_xcconfig = {
    # Release builds default to DEAD_CODE_STRIPPING = YES, and -u only protects
    # the entry points named above. Everything reached indirectly is fair game:
    # measured on a release build, the linker dropped the entire embedded
    # model-spec table that AUDIOCPP_DEPLOYMENT_BUILD compiles in (212 spec
    # strings in a debug build, 0 in release), so every model load failed with
    # "model contract spec not found" while debug builds worked. The macOS
    # dylib escapes this only because CMake does not pass -dead_strip when
    # linking a shared library.
    'DEAD_CODE_STRIPPING' => 'NO',
    'AUDIOCPP_SLICE[sdk=iphoneos*]' => 'ios-arm64',
    'AUDIOCPP_SLICE[sdk=iphonesimulator*]' => 'ios-arm64-simulator',
    'OTHER_LDFLAGS' =>
      "-force_load \"#{xcframework}/$(AUDIOCPP_SLICE)/libaudiocpp_ffi.a\" #{keep_alive}"
  }

  # Safety net for builds that did not go through tool/setup_ios.sh (a plain
  # `flutter build`, Xcode, CI). Without it a missing xcframework is not an
  # error: the glob above matches nothing, the app builds clean, and the failure
  # only appears at runtime as a "library not found" message.
  s.script_phase = {
    :name => 'Verify audiocpp native library',
    :execution_position => :before_compile,
    # The check is a single `test -d`, so running it every build is free.
    # Declaring it always-out-of-date is what stops Xcode warning about a
    # script phase with no declared outputs.
    :always_out_of_date => '1',
    :script => <<-SCRIPT
      LIB="${PODS_TARGET_SRCROOT}/Frameworks/audiocpp.xcframework"
      if [ ! -d "${LIB}" ]; then
        echo "error: audiocpp.xcframework is missing."
        echo "error: build it with packages/audiocpp/tool/setup_ios.sh, then build again."
        exit 1
      fi
    SCRIPT
  }

  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
