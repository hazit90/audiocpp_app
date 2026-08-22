/*
 * audiocpp_ffi.h -- stable C ABI over the audio.cpp C++ engine.
 *
 * audio.cpp exposes only C++ types (std::filesystem::path, std::optional,
 * std::unordered_map, virtual interfaces). Dart FFI cannot bind to those, so
 * this header defines the narrow C surface the Dart package talks to.
 *
 * Contract:
 *   - No C++ exception ever crosses this boundary. Every entry point returns an
 *     audiocpp_status; on failure, audiocpp_last_error() describes what went
 *     wrong for the calling thread.
 *   - Every handle is opaque and must be released with its matching *_free.
 *     Freeing NULL is a no-op.
 *   - Strings are UTF-8 and are copied by the callee; the caller may release
 *     them as soon as the call returns.
 *   - Handles are NOT thread-safe. A handle may be used from any one thread at
 *     a time, but never concurrently. The Dart package enforces this by keeping
 *     all handles inside a single worker isolate.
 */

#ifndef AUDIOCPP_FFI_H
#define AUDIOCPP_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(AUDIOCPP_FFI_BUILDING)
#    define AUDIOCPP_API __declspec(dllexport)
#  else
#    define AUDIOCPP_API __declspec(dllimport)
#  endif
#else
#  define AUDIOCPP_API __attribute__((visibility("default")))
#endif

/* Bump the minor on additive changes, the major on breaking ones. The Dart
 * package checks the major matches what its bindings were generated against. */
#define AUDIOCPP_FFI_ABI_VERSION_MAJOR 1
#define AUDIOCPP_FFI_ABI_VERSION_MINOR 0

/* -------------------------------------------------------------------------- */
/* Status codes                                                               */
/* -------------------------------------------------------------------------- */

typedef enum audiocpp_status {
    AUDIOCPP_OK = 0,
    /* A required argument was NULL, or an array length did not match. */
    AUDIOCPP_ERROR_INVALID_ARGUMENT = 1,
    /* The model directory is missing, unreadable, or has no matching loader. */
    AUDIOCPP_ERROR_MODEL_LOAD = 2,
    /* The loaded model does not support the requested task/mode combination. */
    AUDIOCPP_ERROR_SESSION_CREATE = 3,
    /* Inference started but failed. */
    AUDIOCPP_ERROR_RUN = 4,
    /* The session completed but produced no audio output. */
    AUDIOCPP_ERROR_NO_AUDIO_OUTPUT = 5,
    /* Filesystem read/write failed. */
    AUDIOCPP_ERROR_IO = 6,
    /* An exception escaped that we could not classify. */
    AUDIOCPP_ERROR_UNKNOWN = 99
} audiocpp_status;

/* -------------------------------------------------------------------------- */
/* Enums mirroring engine::core::BackendType / engine::runtime::VoiceTaskKind  */
/* -------------------------------------------------------------------------- */

typedef enum audiocpp_backend {
    AUDIOCPP_BACKEND_CPU = 0,
    AUDIOCPP_BACKEND_CUDA = 1,
    AUDIOCPP_BACKEND_HIP = 2,
    AUDIOCPP_BACKEND_VULKAN = 3,
    AUDIOCPP_BACKEND_METAL = 4,
    AUDIOCPP_BACKEND_BEST_AVAILABLE = 5
} audiocpp_backend;

typedef enum audiocpp_task {
    AUDIOCPP_TASK_VAD = 0,
    AUDIOCPP_TASK_ASR = 1,
    AUDIOCPP_TASK_DIARIZATION = 2,
    AUDIOCPP_TASK_SOURCE_SEPARATION = 3,
    AUDIOCPP_TASK_AUDIO_GENERATION = 4,
    AUDIOCPP_TASK_TTS = 5,
    AUDIOCPP_TASK_VOICE_CLONING = 6,
    AUDIOCPP_TASK_VOICE_CONVERSION = 7,
    AUDIOCPP_TASK_SPEECH_TO_SPEECH = 8,
    AUDIOCPP_TASK_ALIGNMENT = 9,
    AUDIOCPP_TASK_VOICE_DESIGN = 10,
    AUDIOCPP_TASK_SPEAKER_RECOGNITION = 11,
    AUDIOCPP_TASK_SVC = 12,
    AUDIOCPP_TASK_MIDI = 13
} audiocpp_task;

/* -------------------------------------------------------------------------- */
/* Opaque handles                                                             */
/* -------------------------------------------------------------------------- */

typedef struct audiocpp_model_t audiocpp_model;
typedef struct audiocpp_session_t audiocpp_session;
typedef struct audiocpp_audio_t audiocpp_audio;

/* -------------------------------------------------------------------------- */
/* Parameter structs                                                          */
/* -------------------------------------------------------------------------- */

/*
 * A flat key/value map: `keys` and `values` are parallel arrays of `count`
 * UTF-8 strings. Pass count == 0 with NULL arrays for "no options".
 *
 * These pass through to audio.cpp's --load-option / --session-option /
 * --request-option maps verbatim, which is why they stay untyped here: the
 * option set is per model family and evolves upstream. The Dart package layers
 * typed request builders (e.g. MiniMaxMusic3Request) on top.
 */
typedef struct audiocpp_options {
    const char * const * keys;
    const char * const * values;
    int32_t count;
} audiocpp_options;

typedef struct audiocpp_model_params {
    /* Required. Directory holding the model package, e.g. MiniMax-Music3-GGUF. */
    const char * model_path;
    /* Optional. Family hint, e.g. "minimax_music3". Without it the registry has
     * to infer the family from the package contents. */
    const char * family;
    /* Optional. Explicit path to a model_specs/<family>.json. Needed when the
     * library was not built with AUDIOCPP_DEPLOYMENT_BUILD=ON and no
     * model_specs/ directory sits near the model or the process cwd. */
    const char * model_spec_override;
    /* Optional. Select a named config/weight asset inside the package. */
    const char * config_id;
    const char * weight_id;
    audiocpp_options load_options;
} audiocpp_model_params;

typedef struct audiocpp_session_params {
    int32_t task;     /* audiocpp_task */
    int32_t backend;  /* audiocpp_backend */
    /* Device index within the chosen backend's ggml registry. */
    int32_t device;
    /* Must be > 0. */
    int32_t threads;
    audiocpp_options session_options;
} audiocpp_session_params;

typedef struct audiocpp_request {
    /* Optional. Primary text input. For MiniMax Music 3 this is the style
     * caption; the lyrics travel in request_options under "lyrics". */
    const char * text;
    /* Optional. BCP-47-ish language tag passed alongside `text`. */
    const char * language;
    audiocpp_options request_options;
} audiocpp_request;

/* -------------------------------------------------------------------------- */
/* Library-level entry points                                                 */
/* -------------------------------------------------------------------------- */

/* Major/minor of the ABI this library was compiled with. */
AUDIOCPP_API int32_t audiocpp_abi_version_major(void);
AUDIOCPP_API int32_t audiocpp_abi_version_minor(void);

/*
 * Message for the most recent failing call on the calling thread. Valid until
 * the next audiocpp_* call on that same thread. Never NULL; returns "" when no
 * error has been recorded.
 */
AUDIOCPP_API const char * audiocpp_last_error(void);

/* Number of ggml devices visible across all compiled-in backends. */
AUDIOCPP_API int32_t audiocpp_device_count(void);

/*
 * Describes device `index` (0 <= index < audiocpp_device_count()).
 * Each out parameter may be NULL if that field is not wanted. The returned
 * strings are owned by the library and stay valid until the next
 * audiocpp_device_info call on the same thread.
 */
AUDIOCPP_API int32_t /* audiocpp_status */ audiocpp_device_info(
    int32_t index,
    const char ** out_backend,
    const char ** out_name,
    const char ** out_type,
    int32_t * out_device_index);

/* -------------------------------------------------------------------------- */
/* Model                                                                      */
/* -------------------------------------------------------------------------- */

/*
 * Loads a model package. This reads config and weight metadata but does not
 * necessarily fault in every tensor -- that happens lazily per session.
 * Blocking and potentially slow; call off the UI thread.
 */
AUDIOCPP_API int32_t /* audiocpp_status */ audiocpp_model_load(
    const audiocpp_model_params * params,
    audiocpp_model ** out_model);

AUDIOCPP_API void audiocpp_model_free(audiocpp_model * model);

/* Family reported by the loaded model, e.g. "minimax_music3". Owned by the
 * model handle; valid until the model is freed. Returns NULL for a NULL model. */
AUDIOCPP_API const char * audiocpp_model_family(const audiocpp_model * model);

/* Non-zero when the model advertises support for `task` in offline mode. */
AUDIOCPP_API int32_t audiocpp_model_supports_task(
    const audiocpp_model * model,
    int32_t task /* audiocpp_task */);

/* -------------------------------------------------------------------------- */
/* Session                                                                    */
/* -------------------------------------------------------------------------- */

/*
 * Creates an offline task session against a loaded model. Streaming mode is not
 * exposed yet -- MiniMax Music 3 is offline-only, and a streaming surface needs
 * a pull/callback design that this ABI would have to grow deliberately.
 *
 * The session borrows `model`; the model must outlive the session.
 */
AUDIOCPP_API int32_t /* audiocpp_status */ audiocpp_session_create(
    audiocpp_model * model,
    const audiocpp_session_params * params,
    audiocpp_session ** out_session);

AUDIOCPP_API void audiocpp_session_free(audiocpp_session * session);

/*
 * Runs one offline inference. Calls prepare() then run() as audiocpp_cli does.
 * Blocking; for MiniMax Music 3 this is minutes, not milliseconds.
 *
 * On success `*out_audio` owns the generated samples and must be released with
 * audiocpp_audio_free.
 */
AUDIOCPP_API int32_t /* audiocpp_status */ audiocpp_session_run(
    audiocpp_session * session,
    const audiocpp_request * request,
    audiocpp_audio ** out_audio);

/* -------------------------------------------------------------------------- */
/* Audio results                                                              */
/* -------------------------------------------------------------------------- */

AUDIOCPP_API void audiocpp_audio_free(audiocpp_audio * audio);

AUDIOCPP_API int32_t audiocpp_audio_sample_rate(const audiocpp_audio * audio);
AUDIOCPP_API int32_t audiocpp_audio_channels(const audiocpp_audio * audio);

/* Total float count across all channels (interleaved), not per-channel frames. */
AUDIOCPP_API int64_t audiocpp_audio_sample_count(const audiocpp_audio * audio);

/*
 * Borrowed pointer to the interleaved float samples. Valid until the audio
 * handle is freed. NULL when the handle is NULL or holds no samples.
 */
AUDIOCPP_API const float * audiocpp_audio_samples(const audiocpp_audio * audio);

/*
 * Convenience: encode to a 16-bit PCM WAV file at `path`, using audio.cpp's own
 * writer. Saves the Dart side from reimplementing WAV framing, and keeps large
 * buffers out of the Dart heap.
 */
AUDIOCPP_API int32_t /* audiocpp_status */ audiocpp_audio_write_wav(
    const audiocpp_audio * audio,
    const char * path);

#ifdef __cplusplus
}
#endif

#endif /* AUDIOCPP_FFI_H */
