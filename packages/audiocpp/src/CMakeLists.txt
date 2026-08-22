cmake_minimum_required(VERSION 3.20)
project(audiocpp_ffi LANGUAGES C CXX)

# Standalone entry point for the FFI shim. Platform build scripts configure this
# directory directly (see tool/build_macos.sh); Flutter's own platform builds
# consume the artifact it produces rather than recompiling audio.cpp per build.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if (NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# audio.cpp composes engine_runtime out of OBJECT libraries. Those objects end
# up inside our shared library, so every one of them has to be PIC.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(AUDIOCPP_FFI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/audio.cpp"
    CACHE PATH "Path to the audio.cpp checkout")
get_filename_component(AUDIOCPP_FFI_SOURCE_DIR "${AUDIOCPP_FFI_SOURCE_DIR}" ABSOLUTE)

if (NOT EXISTS "${AUDIOCPP_FFI_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "audio.cpp not found at ${AUDIOCPP_FFI_SOURCE_DIR}.\n"
        "Run: git submodule update --init --recursive")
endif()

# Only link the model families we actually ship. `full` compiles all ~50, which
# costs build time and binary size we have no use for.
set(AUDIOCPP_MODEL_SET "custom" CACHE STRING "audio.cpp model composite")
set(AUDIOCPP_MODELS "minimax_music3" CACHE STRING "audio.cpp model targets")

# Compile model_specs/*.json into the runtime. Without this the engine resolves
# specs by walking up from the model directory and the process cwd -- neither of
# which is dependable inside a packaged .app bundle.
set(AUDIOCPP_DEPLOYMENT_BUILD ON CACHE BOOL "Embed model specs" FORCE)

# The submodule's CMakeLists also defines audiocpp_cli, audiocpp_server and the
# other tools. EXCLUDE_FROM_ALL keeps them out of the default build; they stay
# buildable by name when we want the CLI for comparison runs.
add_subdirectory("${AUDIOCPP_FFI_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/audio.cpp" EXCLUDE_FROM_ALL)

add_library(audiocpp_ffi SHARED
    audiocpp_ffi.cpp
)

target_include_directories(audiocpp_ffi PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(audiocpp_ffi PRIVATE engine_runtime ggml)

target_compile_definitions(audiocpp_ffi PRIVATE AUDIOCPP_FFI_BUILDING)

# Only the AUDIOCPP_API entry points should be exported. Hiding the rest keeps
# audio.cpp's and ggml's C++ symbols from leaking into the host process, where
# they could collide with another ggml-based library.
set_target_properties(audiocpp_ffi PROPERTIES
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

if (APPLE)
    # @rpath so the dylib resolves from inside the .app bundle's Frameworks dir.
    set_target_properties(audiocpp_ffi PROPERTIES
        INSTALL_NAME_DIR "@rpath"
        BUILD_WITH_INSTALL_NAME_DIR ON
    )

    # The visibility presets above only reach our own sources. The static
    # archives we link (ggml, sentencepiece, the engine objects) carry default
    # visibility, so an explicit export list is what actually keeps their
    # symbols in.
    set(AUDIOCPP_FFI_EXPORT_LIST "${CMAKE_CURRENT_SOURCE_DIR}/audiocpp_ffi.exports")
    target_link_options(audiocpp_ffi PRIVATE
        "-Wl,-exported_symbols_list,${AUDIOCPP_FFI_EXPORT_LIST}")
    set_property(TARGET audiocpp_ffi APPEND
        PROPERTY LINK_DEPENDS "${AUDIOCPP_FFI_EXPORT_LIST}")
endif()

install(TARGETS audiocpp_ffi LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
