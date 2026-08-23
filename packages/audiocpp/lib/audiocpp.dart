/// Dart FFI bindings for the [audio.cpp](https://github.com/0xShug0/audio.cpp)
/// inference engine.
///
/// The native side is a thin C ABI (`src/include/audiocpp_ffi.h`) over
/// audio.cpp's C++ runtime, built by `tool/build_macos.sh`. All calls into it
/// run on a worker isolate, so nothing here blocks the UI.
///
/// Start with `AudioCppEngine`.
library;

export 'src/catalog/model_option.dart'
    show ModelOption, ModelOptionType, ModelOptions;
export 'src/catalog/model_package.dart'
    show DownloadKind, DownloadSource, ModelPackage, UnsafeModelPathException;
export 'src/catalog/model_spec.dart' show ModelCatalog, ModelCategory, ModelSpec;
export 'src/engine/audiocpp_engine.dart'
    show AudioCppEngine, AudioCppModel, AudioCppSession, GeneratedAudio;
export 'src/exceptions.dart'
    show
        AudioCppAbiMismatchException,
        AudioCppCancelledException,
        AudioCppDisposedException,
        AudioCppException,
        AudioCppLibraryNotFoundException,
        AudioCppNativeException;
export 'src/requests/minimax_music3.dart' show MiniMaxMusic3Request;
export 'src/types.dart'
    show
        AudioCppBackend,
        AudioCppDevice,
        AudioCppTask,
        GenerationPhase,
        InferenceRequest,
        ProgressSnapshot,
        ModelDescriptor,
        SessionConfig;
