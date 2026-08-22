import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../exceptions.dart';
import '../ffi/audiocpp_bindings.g.dart';
import '../ffi/library.dart';
import '../types.dart';

/// Synchronous, blocking driver over the native ABI.
///
/// Every method here can block for minutes (model loads, generation), so this
/// class is only ever driven from the worker isolate in `engine.dart`. It owns
/// all native handles and hands the outside world integer ids instead of
/// pointers, which keeps raw addresses from leaking across isolate boundaries.
final class NativeBridge {
  NativeBridge();

  AudioCppBindings get _bindings => AudioCppLibrary.instance;

  final Map<int, Pointer<audiocpp_model>> _models = {};
  final Map<int, Pointer<audiocpp_session>> _sessions = {};
  final Map<int, Pointer<audiocpp_audio>> _audios = {};

  /// Sessions borrow their model, so disposing a model must dispose the
  /// sessions created from it first. This tracks that ownership.
  final Map<int, Set<int>> _sessionsByModel = {};

  int _nextHandleId = 1;

  int _allocateHandleId() => _nextHandleId++;

  // ---------------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------------

  List<AudioCppDevice> listDevices() {
    final bindings = _bindings;
    final count = bindings.audiocpp_device_count();
    if (count <= 0) {
      return const [];
    }

    return using((Arena arena) {
      final backend = arena<Pointer<Char>>();
      final name = arena<Pointer<Char>>();
      final type = arena<Pointer<Char>>();
      final index = arena<Int32>();

      final devices = <AudioCppDevice>[];
      for (var i = 0; i < count; i++) {
        final status = bindings.audiocpp_device_info(i, backend, name, type, index);
        // A single bad device should not hide the rest of the machine.
        if (status != audiocpp_status.AUDIOCPP_OK.value) {
          continue;
        }
        devices.add(
          AudioCppDevice(
            backend: backend.value.cast<Utf8>().toDartString(),
            name: name.value.cast<Utf8>().toDartString(),
            type: type.value.cast<Utf8>().toDartString(),
            index: index.value,
          ),
        );
      }
      return devices;
    });
  }

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------

  /// Loads a model package and returns its handle id. Blocking.
  int loadModel(ModelDescriptor descriptor) {
    final bindings = _bindings;
    return using((Arena arena) {
      final params = arena<audiocpp_model_params>();
      final ref = params.ref;
      ref.model_path = descriptor.path.toNativeUtf8(allocator: arena).cast();
      ref.family = _optionalString(descriptor.family, arena);
      ref.model_spec_override = _optionalString(descriptor.modelSpecOverride, arena);
      ref.config_id = _optionalString(descriptor.configId, arena);
      ref.weight_id = _optionalString(descriptor.weightId, arena);
      _fillOptions(ref.load_options, descriptor.loadOptions, arena);

      final out = arena<Pointer<audiocpp_model>>();
      _check(bindings.audiocpp_model_load(params, out), 'load model at ${descriptor.path}');

      final id = _allocateHandleId();
      _models[id] = out.value;
      _sessionsByModel[id] = <int>{};
      return id;
    });
  }

  String modelFamily(int modelId) {
    final model = _requireModel(modelId);
    final family = _bindings.audiocpp_model_family(model);
    return family == nullptr ? '' : family.cast<Utf8>().toDartString();
  }

  bool modelSupportsTask(int modelId, AudioCppTask task) {
    final model = _requireModel(modelId);
    return _bindings.audiocpp_model_supports_task(model, task.nativeValue) != 0;
  }

  void disposeModel(int modelId) {
    final model = _models.remove(modelId);
    if (model == null) {
      return;
    }
    // Free dependent sessions first: they hold raw references into the model.
    for (final sessionId in _sessionsByModel.remove(modelId) ?? const <int>{}) {
      final session = _sessions.remove(sessionId);
      if (session != null) {
        _bindings.audiocpp_session_free(session);
      }
    }
    _bindings.audiocpp_model_free(model);
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  int createSession(int modelId, SessionConfig config) {
    final model = _requireModel(modelId);
    final bindings = _bindings;

    return using((Arena arena) {
      final params = arena<audiocpp_session_params>();
      final ref = params.ref;
      ref.task = config.task.nativeValue;
      ref.backend = config.backend.nativeValue;
      ref.device = config.device;
      ref.threads = config.threads;
      _fillOptions(ref.session_options, config.sessionOptions, arena);

      final out = arena<Pointer<audiocpp_session>>();
      _check(
        bindings.audiocpp_session_create(model, params, out),
        'create ${config.task.name} session',
      );

      final id = _allocateHandleId();
      _sessions[id] = out.value;
      _sessionsByModel[modelId]!.add(id);
      return id;
    });
  }

  /// Runs one inference and returns the resulting audio handle id. Blocking,
  /// and for music generation that means minutes.
  int runSession(int sessionId, InferenceRequest request) {
    final session = _requireSession(sessionId);
    final bindings = _bindings;

    return using((Arena arena) {
      final native = arena<audiocpp_request>();
      final ref = native.ref;
      ref.text = _optionalString(request.text, arena);
      ref.language = _optionalString(request.language, arena);
      _fillOptions(ref.request_options, request.options, arena);

      final out = arena<Pointer<audiocpp_audio>>();
      _check(bindings.audiocpp_session_run(session, native, out), 'run inference');

      final id = _allocateHandleId();
      _audios[id] = out.value;
      return id;
    });
  }

  void disposeSession(int sessionId) {
    final session = _sessions.remove(sessionId);
    if (session == null) {
      return;
    }
    for (final sessions in _sessionsByModel.values) {
      sessions.remove(sessionId);
    }
    _bindings.audiocpp_session_free(session);
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  ({int sampleRate, int channels, int sampleCount}) audioInfo(int audioId) {
    final audio = _requireAudio(audioId);
    final bindings = _bindings;
    return (
      sampleRate: bindings.audiocpp_audio_sample_rate(audio),
      channels: bindings.audiocpp_audio_channels(audio),
      sampleCount: bindings.audiocpp_audio_sample_count(audio),
    );
  }

  /// Copies the interleaved samples out of native memory into the Dart heap.
  ///
  /// This is a real copy of potentially tens of megabytes. Prefer
  /// [writeWav] when the samples only need to reach a file.
  Float32List readSamples(int audioId) {
    final audio = _requireAudio(audioId);
    final bindings = _bindings;
    final count = bindings.audiocpp_audio_sample_count(audio);
    if (count <= 0) {
      return Float32List(0);
    }
    final samples = bindings.audiocpp_audio_samples(audio);
    if (samples == nullptr) {
      return Float32List(0);
    }
    // asTypedList is a view over native memory; copy so the result stays valid
    // after the audio handle is freed.
    return Float32List.fromList(samples.asTypedList(count));
  }

  void writeWav(int audioId, String path) {
    final audio = _requireAudio(audioId);
    final bindings = _bindings;
    using((Arena arena) {
      final nativePath = path.toNativeUtf8(allocator: arena).cast<Char>();
      _check(bindings.audiocpp_audio_write_wav(audio, nativePath), 'write WAV to $path');
    });
  }

  void disposeAudio(int audioId) {
    final audio = _audios.remove(audioId);
    if (audio != null) {
      _bindings.audiocpp_audio_free(audio);
    }
  }

  /// Releases every handle still open. Called when the worker isolate shuts
  /// down so a forgotten handle cannot leak the whole model's memory.
  void disposeAll() {
    for (final id in _models.keys.toList()) {
      disposeModel(id);
    }
    for (final id in _sessions.keys.toList()) {
      disposeSession(id);
    }
    for (final id in _audios.keys.toList()) {
      disposeAudio(id);
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Pointer<audiocpp_model> _requireModel(int id) =>
      _models[id] ?? (throw AudioCppDisposedException('model handle $id is not open'));

  Pointer<audiocpp_session> _requireSession(int id) =>
      _sessions[id] ?? (throw AudioCppDisposedException('session handle $id is not open'));

  Pointer<audiocpp_audio> _requireAudio(int id) =>
      _audios[id] ?? (throw AudioCppDisposedException('audio handle $id is not open'));

  /// Null and empty both mean "unset" on the native side, so they collapse to
  /// a null pointer here rather than an allocated empty string.
  Pointer<Char> _optionalString(String? value, Arena arena) {
    if (value == null || value.isEmpty) {
      return nullptr;
    }
    return value.toNativeUtf8(allocator: arena).cast();
  }

  /// Populates an `audiocpp_options` in place with arena-owned string arrays.
  void _fillOptions(audiocpp_options options, Map<String, String> values, Arena arena) {
    if (values.isEmpty) {
      options.keys = nullptr;
      options.values = nullptr;
      options.count = 0;
      return;
    }

    final keys = arena<Pointer<Char>>(values.length);
    final vals = arena<Pointer<Char>>(values.length);
    var i = 0;
    for (final entry in values.entries) {
      keys[i] = entry.key.toNativeUtf8(allocator: arena).cast();
      vals[i] = entry.value.toNativeUtf8(allocator: arena).cast();
      i++;
    }

    options.keys = keys;
    options.values = vals;
    options.count = values.length;
  }

  /// Turns a non-OK status into an exception carrying the engine's own message.
  void _check(int status, String action) {
    if (status == audiocpp_status.AUDIOCPP_OK.value) {
      return;
    }
    final message = _bindings.audiocpp_last_error().cast<Utf8>().toDartString();
    throw AudioCppNativeException(
      audiocpp_status.fromValue(status),
      message.isEmpty ? 'failed to $action' : 'failed to $action: $message',
    );
  }
}
