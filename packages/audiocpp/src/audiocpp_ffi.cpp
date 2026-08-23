// Implementation of the C ABI declared in audiocpp_ffi.h.
//
// Everything here follows one rule: an exception must never unwind past an
// extern "C" boundary. Each entry point routes its body through guard(), which
// catches, records a thread-local message, and maps to an audiocpp_status.

#include "audiocpp_ffi.h"

#include "engine/framework/audio/wav_writer.h"
#include "engine/framework/core/backend.h"
#include "engine/framework/core/module.h"
#include "engine/framework/runtime/model.h"
#include "engine/framework/runtime/registry.h"
#include "engine/framework/runtime/session.h"

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <windows.h>
#endif

#include <exception>
#include <filesystem>
#include <memory>
#include <optional>
#include "engine/framework/core/cancel.h"

#include <atomic>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

// Process-wide rather than per-session, and deliberately so.
//
// The isolate that calls audiocpp_session_run is blocked inside it for minutes,
// so the stop request has to arrive from somewhere else entirely. Anything
// reached through a handle would mean touching that handle concurrently, which
// is exactly what the rest of this ABI rules out. A flag owned here is the one
// thing safe to poke from another thread -- and because Dart statics are
// per-isolate but dlopen is per-process, the UI isolate opening its own
// bindings still lands on this same object.
//
// Sound only while one generation runs at a time, which the engine requires for
// other reasons anyway.
engine::core::RunControl g_control;

// ---------------------------------------------------------------------------
// Error plumbing
// ---------------------------------------------------------------------------

// Thread-local so concurrent callers cannot clobber each other's message, even
// though individual handles are single-threaded.
thread_local std::string g_last_error;

void set_error(std::string message) {
    g_last_error = std::move(message);
}

void clear_error() {
    g_last_error.clear();
}

// Runs `body` and converts any escaping exception into a status code.
// `failure` is the status used for exceptions the body itself did not classify.
template <typename Body>
audiocpp_status guard(audiocpp_status failure, Body && body) {
    clear_error();
    try {
        return body();
    } catch (const std::exception & error) {
        set_error(error.what());
        return failure;
    } catch (...) {
        set_error("unknown non-std exception raised inside audio.cpp");
        return AUDIOCPP_ERROR_UNKNOWN;
    }
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

std::unordered_map<std::string, std::string> to_option_map(const audiocpp_options & options) {
    if (options.count <= 0) {
        return {};
    }
    if (options.keys == nullptr || options.values == nullptr) {
        throw std::invalid_argument("option arrays are null but count is positive");
    }

    std::unordered_map<std::string, std::string> result;
    result.reserve(static_cast<size_t>(options.count));
    for (int32_t i = 0; i < options.count; ++i) {
        const char * key = options.keys[i];
        const char * value = options.values[i];
        if (key == nullptr || value == nullptr) {
            throw std::invalid_argument("option key or value at index " + std::to_string(i) + " is null");
        }
        result.emplace(key, value);
    }
    return result;
}

// Returns nullopt for a null or empty string so callers can leave optional
// fields unset by passing "" as readily as NULL.
std::optional<std::string> to_optional_string(const char * value) {
    if (value == nullptr || *value == '\0') {
        return std::nullopt;
    }
    return std::string(value);
}

// Builds a filesystem path from one of this ABI's UTF-8 strings.
//
// Never construct std::filesystem::path straight from a const char* here. The
// narrow constructor decodes using the platform's native narrow encoding, which
// on Windows is the active code page and not UTF-8 -- so any path outside ASCII
// silently becomes the wrong path. It matters in practice: model and track
// paths are rooted at the user's profile directory, so a single non-ASCII
// character in an account name breaks model loading and WAV export.
//
// POSIX platforms already treat the bytes as-is, so there the widening is
// skipped entirely rather than round-tripped.
std::filesystem::path to_path(const char * utf8) {
#if defined(_WIN32)
    if (utf8 == nullptr || *utf8 == '\0') {
        return std::filesystem::path{};
    }
    const int needed = ::MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (needed <= 0) {
        throw std::runtime_error("path is not valid UTF-8");
    }
    // `needed` counts the terminating null; the wstring must not.
    std::wstring wide(static_cast<size_t>(needed - 1), L'\0');
    if (::MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), needed) <= 0) {
        throw std::runtime_error("path is not valid UTF-8");
    }
    return std::filesystem::path(std::move(wide));
#else
    return std::filesystem::path(utf8 == nullptr ? "" : utf8);
#endif
}

std::filesystem::path to_path(const std::string & utf8) {
    return to_path(utf8.c_str());
}

engine::core::BackendType to_backend_type(int32_t backend) {
    switch (backend) {
        case AUDIOCPP_BACKEND_CPU:
            return engine::core::BackendType::Cpu;
        case AUDIOCPP_BACKEND_CUDA:
            return engine::core::BackendType::Cuda;
        case AUDIOCPP_BACKEND_HIP:
            return engine::core::BackendType::Hip;
        case AUDIOCPP_BACKEND_VULKAN:
            return engine::core::BackendType::Vulkan;
        case AUDIOCPP_BACKEND_METAL:
            return engine::core::BackendType::Metal;
        case AUDIOCPP_BACKEND_BEST_AVAILABLE:
            return engine::core::BackendType::BestAvailable;
        default:
            throw std::invalid_argument("unknown backend id " + std::to_string(backend));
    }
}

engine::runtime::VoiceTaskKind to_task_kind(int32_t task) {
    using engine::runtime::VoiceTaskKind;
    switch (task) {
        case AUDIOCPP_TASK_VAD:
            return VoiceTaskKind::Vad;
        case AUDIOCPP_TASK_ASR:
            return VoiceTaskKind::Asr;
        case AUDIOCPP_TASK_DIARIZATION:
            return VoiceTaskKind::Diarization;
        case AUDIOCPP_TASK_SOURCE_SEPARATION:
            return VoiceTaskKind::SourceSeparation;
        case AUDIOCPP_TASK_AUDIO_GENERATION:
            return VoiceTaskKind::AudioGeneration;
        case AUDIOCPP_TASK_TTS:
            return VoiceTaskKind::Tts;
        case AUDIOCPP_TASK_VOICE_CLONING:
            return VoiceTaskKind::VoiceCloning;
        case AUDIOCPP_TASK_VOICE_CONVERSION:
            return VoiceTaskKind::VoiceConversion;
        case AUDIOCPP_TASK_SPEECH_TO_SPEECH:
            return VoiceTaskKind::SpeechToSpeech;
        case AUDIOCPP_TASK_ALIGNMENT:
            return VoiceTaskKind::Alignment;
        case AUDIOCPP_TASK_VOICE_DESIGN:
            return VoiceTaskKind::VoiceDesign;
        case AUDIOCPP_TASK_SPEAKER_RECOGNITION:
            return VoiceTaskKind::SpeakerRecognition;
        case AUDIOCPP_TASK_SVC:
            return VoiceTaskKind::Svc;
        case AUDIOCPP_TASK_MIDI:
            return VoiceTaskKind::Midi;
        default:
            throw std::invalid_argument("unknown task id " + std::to_string(task));
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Handle definitions
// ---------------------------------------------------------------------------

// The registry is rebuilt per model load. It is a cheap vector of loader
// shared_ptrs, and keeping it here rather than in a process-wide singleton
// avoids ordering surprises around static destruction on library unload.
struct audiocpp_model_t {
    engine::runtime::ModelRegistry registry;
    std::unique_ptr<engine::runtime::ILoadedVoiceModel> model;
    std::string family;
};

struct audiocpp_session_t {
    std::unique_ptr<engine::runtime::IVoiceTaskSession> session;
    // Non-owning view of `session`, resolved once at creation so run() does not
    // repeat the dynamic_cast.
    engine::runtime::IOfflineVoiceTaskSession * offline = nullptr;
};

struct audiocpp_audio_t {
    engine::runtime::AudioBuffer buffer;
};

// ---------------------------------------------------------------------------
// Library-level entry points
// ---------------------------------------------------------------------------

int32_t audiocpp_abi_version_major(void) {
    return AUDIOCPP_FFI_ABI_VERSION_MAJOR;
}

int32_t audiocpp_abi_version_minor(void) {
    return AUDIOCPP_FFI_ABI_VERSION_MINOR;
}

const char * audiocpp_last_error(void) {
    return g_last_error.c_str();
}

int32_t audiocpp_device_count(void) {
    try {
        return static_cast<int32_t>(engine::core::list_backend_devices().size());
    } catch (...) {
        return 0;
    }
}

int32_t audiocpp_device_info(
    int32_t index,
    const char ** out_backend,
    const char ** out_name,
    const char ** out_type,
    int32_t * out_device_index) {
    // Held across the return so the borrowed char pointers stay valid until the
    // next call on this thread, as the header promises.
    thread_local engine::core::BackendDeviceInfo cached;

    return guard(AUDIOCPP_ERROR_UNKNOWN, [&]() -> audiocpp_status {
        const auto devices = engine::core::list_backend_devices();
        if (index < 0 || static_cast<size_t>(index) >= devices.size()) {
            set_error("device index " + std::to_string(index) + " out of range (" +
                      std::to_string(devices.size()) + " devices)");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }

        cached = devices[static_cast<size_t>(index)];
        if (out_backend != nullptr) {
            *out_backend = cached.backend.c_str();
        }
        if (out_name != nullptr) {
            *out_name = cached.name.c_str();
        }
        if (out_type != nullptr) {
            *out_type = cached.type.c_str();
        }
        if (out_device_index != nullptr) {
            *out_device_index = static_cast<int32_t>(cached.index);
        }
        return AUDIOCPP_OK;
    });
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

int32_t audiocpp_model_load(
    const audiocpp_model_params * params,
    audiocpp_model ** out_model) {
    return guard(AUDIOCPP_ERROR_MODEL_LOAD, [&]() -> audiocpp_status {
        if (params == nullptr || out_model == nullptr) {
            set_error("audiocpp_model_load requires non-null params and out_model");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }
        if (params->model_path == nullptr || *params->model_path == '\0') {
            set_error("model_path is required");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }

        *out_model = nullptr;

        engine::runtime::ModelLoadRequest request;
        request.model_path = to_path(params->model_path);
        request.family_hint = to_optional_string(params->family);
        request.config_id = to_optional_string(params->config_id);
        request.weight_id = to_optional_string(params->weight_id);
        request.options = to_option_map(params->load_options);
        if (const auto spec = to_optional_string(params->model_spec_override)) {
            request.model_spec_override = to_path(*spec);
        }

        auto handle = std::make_unique<audiocpp_model_t>();
        handle->registry = engine::runtime::make_default_registry();
        handle->model = handle->registry.load(request);
        if (!handle->model) {
            set_error("registry returned no model for " + request.model_path.string());
            return AUDIOCPP_ERROR_MODEL_LOAD;
        }
        handle->family = handle->model->metadata().family;

        *out_model = handle.release();
        return AUDIOCPP_OK;
    });
}

void audiocpp_model_free(audiocpp_model * model) {
    delete model;
}

const char * audiocpp_model_family(const audiocpp_model * model) {
    return model == nullptr ? nullptr : model->family.c_str();
}

int32_t audiocpp_model_supports_task(const audiocpp_model * model, int32_t task) {
    if (model == nullptr || !model->model) {
        return 0;
    }
    try {
        const auto kind = to_task_kind(task);
        for (const auto & capability : model->model->capabilities().supported_tasks) {
            if (capability.task != kind) {
                continue;
            }
            for (const auto mode : capability.modes) {
                if (mode == engine::runtime::RunMode::Offline) {
                    return 1;
                }
            }
        }
        return 0;
    } catch (...) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

int32_t audiocpp_session_create(
    audiocpp_model * model,
    const audiocpp_session_params * params,
    audiocpp_session ** out_session) {
    return guard(AUDIOCPP_ERROR_SESSION_CREATE, [&]() -> audiocpp_status {
        if (model == nullptr || params == nullptr || out_session == nullptr) {
            set_error("audiocpp_session_create requires non-null model, params and out_session");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }
        if (params->threads <= 0) {
            set_error("threads must be positive, got " + std::to_string(params->threads));
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }
        if (params->device < 0) {
            set_error("device must be non-negative, got " + std::to_string(params->device));
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }

        *out_session = nullptr;

        const engine::runtime::TaskSpec spec{
            to_task_kind(params->task),
            engine::runtime::RunMode::Offline,
        };

        engine::runtime::SessionOptions options;
        options.backend.type = to_backend_type(params->backend);
        options.backend.device = params->device;
        options.backend.threads = params->threads;
        options.options = to_option_map(params->session_options);

        auto handle = std::make_unique<audiocpp_session_t>();
        handle->session = model->model->create_task_session(spec, options);
        if (!handle->session) {
            set_error("model '" + model->family + "' returned no session for the requested task");
            return AUDIOCPP_ERROR_SESSION_CREATE;
        }

        handle->offline =
            dynamic_cast<engine::runtime::IOfflineVoiceTaskSession *>(handle->session.get());
        if (handle->offline == nullptr) {
            set_error("model '" + model->family + "' session does not support offline execution");
            return AUDIOCPP_ERROR_SESSION_CREATE;
        }

        *out_session = handle.release();
        return AUDIOCPP_OK;
    });
}

void audiocpp_session_free(audiocpp_session * session) {
    delete session;
}

int32_t audiocpp_cancel_request(void) {
    // Also wakes a paused run, which is the only way one ever unwinds.
    g_control.request_cancel();
    return AUDIOCPP_OK;
}

int32_t audiocpp_pause_request(void) {
    g_control.request_pause();
    return AUDIOCPP_OK;
}

int32_t audiocpp_resume_request(void) {
    g_control.request_resume();
    return AUDIOCPP_OK;
}

int32_t audiocpp_session_run(
    audiocpp_session * session,
    const audiocpp_request * request,
    audiocpp_audio ** out_audio) {
    return guard(AUDIOCPP_ERROR_RUN, [&]() -> audiocpp_status {
        if (session == nullptr || request == nullptr || out_audio == nullptr) {
            set_error("audiocpp_session_run requires non-null session, request and out_audio");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }

        *out_audio = nullptr;

        engine::runtime::TaskRequest task_request;
        task_request.options = to_option_map(request->request_options);
        if (const auto text = to_optional_string(request->text)) {
            engine::runtime::Transcript transcript;
            transcript.text = *text;
            transcript.language = to_optional_string(request->language).value_or(std::string{});
            task_request.text_input = std::move(transcript);
        }

        // Cleared here rather than on completion: a stop or a pause that
        // arrives while nothing is running must not carry into whatever starts
        // next -- and a leftover pause would hang the next run outright.
        g_control.reset();
        task_request.cancel = &g_control;

        // Mirrors audiocpp_cli: prepare() lets the session size its graphs and
        // caches from the request before run() executes.
        session->session->prepare(engine::runtime::build_preparation_request(task_request));

        engine::runtime::TaskResult result;
        try {
            result = session->offline->run(task_request);
        } catch (...) {
            // Asking the flag rather than matching the exception: the throw
            // comes from upstream, and coupling this to its type or its wording
            // would break the first time either is refactored.
            if (engine::core::cancel_requested(&g_control)) {
                set_error("run cancelled");
                return AUDIOCPP_CANCELLED;
            }
            throw;
        }

        if (!result.audio_output.has_value()) {
            set_error("session produced no audio output");
            return AUDIOCPP_ERROR_NO_AUDIO_OUTPUT;
        }

        auto audio = std::make_unique<audiocpp_audio_t>();
        audio->buffer = std::move(*result.audio_output);
        *out_audio = audio.release();
        return AUDIOCPP_OK;
    });
}

// ---------------------------------------------------------------------------
// Audio results
// ---------------------------------------------------------------------------

void audiocpp_audio_free(audiocpp_audio * audio) {
    delete audio;
}

int32_t audiocpp_audio_sample_rate(const audiocpp_audio * audio) {
    return audio == nullptr ? 0 : static_cast<int32_t>(audio->buffer.sample_rate);
}

int32_t audiocpp_audio_channels(const audiocpp_audio * audio) {
    return audio == nullptr ? 0 : static_cast<int32_t>(audio->buffer.channels);
}

int64_t audiocpp_audio_sample_count(const audiocpp_audio * audio) {
    return audio == nullptr ? 0 : static_cast<int64_t>(audio->buffer.samples.size());
}

const float * audiocpp_audio_samples(const audiocpp_audio * audio) {
    if (audio == nullptr || audio->buffer.samples.empty()) {
        return nullptr;
    }
    return audio->buffer.samples.data();
}

int32_t audiocpp_audio_write_wav(const audiocpp_audio * audio, const char * path) {
    return guard(AUDIOCPP_ERROR_IO, [&]() -> audiocpp_status {
        if (audio == nullptr || path == nullptr || *path == '\0') {
            set_error("audiocpp_audio_write_wav requires a non-null audio handle and path");
            return AUDIOCPP_ERROR_INVALID_ARGUMENT;
        }
        engine::audio::write_pcm16_wav(
            to_path(path),
            audio->buffer.sample_rate,
            audio->buffer.channels,
            audio->buffer.samples);
        return AUDIOCPP_OK;
    });
}
