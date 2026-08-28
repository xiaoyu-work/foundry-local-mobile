# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.26)

project(foundry_local_mobile VERSION 0.2.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
option(FLM_BUILD_SHARED "Build the shared library" ON)
option(FLM_BUILD_EXAMPLES "Build the native example programs" OFF)

# Resolve our JSON dependency before adding OGA. Some OGA dependencies also use a
# FetchContent key named nlohmann_json without creating its namespaced CMake target;
# resolving ours first prevents that global-key collision in parent builds.
include(FetchContent)
find_package(nlohmann_json 3.11 QUIET)
if(NOT nlohmann_json_FOUND)
    FetchContent_Declare(nlohmann_json
        GIT_REPOSITORY https://github.com/nlohmann/json.git
        GIT_TAG v3.11.3
        GIT_SHALLOW TRUE)
    set(JSON_BuildTests OFF CACHE INTERNAL "")
    FetchContent_MakeAvailable(nlohmann_json)
endif()

# Path to a staged or checked-out onnxruntime-genai source tree. When set
# and the directory contains CMakeLists.txt + src/ort_genai_c.h, the tree is
# added as a subdirectory and built from source. Otherwise an installed
# package is required (set onnxruntime-genai_DIR to its CMake config dir).
set(FLM_ORT_GENAI_ROOT "" CACHE PATH
    "Root of the ONNX Runtime GenAI source tree (contains src/ort_genai_c.h)")

# --------------------------------------------------------------------------
# Find ONNX Runtime GenAI — installed package or source subdirectory
# --------------------------------------------------------------------------

# Prefer an installed package when the caller provides one. This keeps incremental
# builds fast even when a staged source checkout also exists.
find_package(onnxruntime-genai CONFIG QUIET)

if(onnxruntime-genai_FOUND)
    message(STATUS "onnxruntime-genai found via find_package: ${onnxruntime-genai_VERSION}")
    set(FLM_OGA_VERSION_STRING "${onnxruntime-genai_VERSION}")
    get_target_property(_oga_includes onnxruntime-genai::onnxruntime-genai INTERFACE_INCLUDE_DIRECTORIES)
    foreach(_dir IN LISTS _oga_includes)
        if(EXISTS "${_dir}/ort_genai_c.h")
            set(FLM_OGA_INCLUDE_DIR "${_dir}")
            break()
        endif()
    endforeach()
else()
    # Probe the default staging path only when no installed package was selected.
    if(NOT FLM_ORT_GENAI_ROOT)
        get_filename_component(_staged "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/onnxruntime-genai" ABSOLUTE)
        if(EXISTS "${_staged}/src/ort_genai_c.h" AND EXISTS "${_staged}/CMakeLists.txt")
            set(FLM_ORT_GENAI_ROOT "${_staged}" CACHE PATH "" FORCE)
            message(STATUS "Auto-detected staged OGA source: ${FLM_ORT_GENAI_ROOT}")
        endif()
    endif()

    if(NOT FLM_ORT_GENAI_ROOT
       OR NOT EXISTS "${FLM_ORT_GENAI_ROOT}/src/ort_genai_c.h"
       OR NOT EXISTS "${FLM_ORT_GENAI_ROOT}/CMakeLists.txt")
        message(FATAL_ERROR
            "ONNX Runtime GenAI was not found.\n"
            "  Option A: run scripts/fetch_onnxruntime_genai.sh to stage the source tree,\n"
            "            or set FLM_ORT_GENAI_ROOT to an existing checkout.\n"
            "  Option B: install onnxruntime-genai and set onnxruntime-genai_DIR to its\n"
            "            CMake config directory.")
    endif()

    message(STATUS "Building ONNX Runtime GenAI from source: ${FLM_ORT_GENAI_ROOT}")
    set(ENABLE_TESTS    OFF CACHE BOOL "" FORCE)
    set(ENABLE_PYTHON   OFF CACHE BOOL "" FORCE)
    set(ENABLE_JAVA     OFF CACHE BOOL "" FORCE)
    set(ENABLE_TELEMETRY OFF CACHE BOOL "" FORCE)
    set(ENABLE_MODEL_BENCHMARK OFF CACHE BOOL "" FORCE)
    set(ENABLE_ENGINE_BENCHMARK OFF CACHE BOOL "" FORCE)
    set(USE_GUIDANCE    OFF CACHE BOOL "" FORCE)
    set(USE_CUDA        OFF CACHE BOOL "" FORCE)
    set(USE_TRT_RTX     OFF CACHE BOOL "" FORCE)
    set(USE_DML         OFF CACHE BOOL "" FORCE)
    set(USE_WINML       OFF CACHE BOOL "" FORCE)

    add_subdirectory("${FLM_ORT_GENAI_ROOT}" "${CMAKE_BINARY_DIR}/onnxruntime-genai" EXCLUDE_FROM_ALL)

    # The OGA build produces a target; verify it exists.
    if(NOT TARGET onnxruntime-genai)
        message(FATAL_ERROR
            "add_subdirectory of ${FLM_ORT_GENAI_ROOT} did not produce an "
            "'onnxruntime-genai' target. Check the OGA CMakeLists.txt.")
    endif()
    # Create the namespaced alias if the subdirectory build did not.
    if(NOT TARGET onnxruntime-genai::onnxruntime-genai)
        add_library(onnxruntime-genai::onnxruntime-genai ALIAS onnxruntime-genai)
    endif()
    set(FLM_OGA_INCLUDE_DIR "${FLM_ORT_GENAI_ROOT}/src")
    if(EXISTS "${FLM_ORT_GENAI_ROOT}/VERSION_INFO")
        file(STRINGS "${FLM_ORT_GENAI_ROOT}/VERSION_INFO" FLM_OGA_VERSION_STRING LIMIT_COUNT 1)
    endif()
endif()

if(NOT FLM_OGA_INCLUDE_DIR)
    message(FATAL_ERROR "The selected ONNX Runtime GenAI target does not expose ort_genai_c.h")
endif()
if(NOT FLM_OGA_VERSION_STRING)
    set(FLM_OGA_VERSION_STRING "unknown")
endif()

message(STATUS "OGA headers: ${FLM_OGA_INCLUDE_DIR}")

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------
set(FLM_SOURCES
    src/error.cc
    src/encoding.cc
    src/handle_table.cc
    src/job.cc
    src/flm_dart_bridge.c
    src/runtime.cc
    src/device_profile.cc
    src/manager.cc
    src/model.cc
    src/session.cc
    src/api.cc
    src/platform/device_profile_android.cc
    src/platform/device_profile_apple.cc
    src/platform/device_profile_desktop.cc
)

if(FLM_BUILD_SHARED)
    add_library(foundry_local_mobile SHARED ${FLM_SOURCES})
else()
    add_library(foundry_local_mobile STATIC ${FLM_SOURCES})
    target_compile_definitions(foundry_local_mobile PUBLIC FLM_STATIC)
endif()

add_library(foundry_local_mobile::foundry_local_mobile ALIAS foundry_local_mobile)

set_target_properties(foundry_local_mobile PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

target_include_directories(foundry_local_mobile
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${FLM_OGA_INCLUDE_DIR}
)

target_compile_definitions(foundry_local_mobile PRIVATE
    FLM_BUILDING_SHARED
    FLM_OGA_VERSION_STRING="${FLM_OGA_VERSION_STRING}"
)
target_link_libraries(foundry_local_mobile
    PRIVATE
        nlohmann_json::nlohmann_json
        onnxruntime-genai::onnxruntime-genai
)

if(MSVC)
    target_compile_options(foundry_local_mobile PRIVATE /W4 /permissive-)
else()
    target_compile_options(foundry_local_mobile PRIVATE
        -Wall -Wextra -Wpedantic -Wshadow -Wnon-virtual-dtor -Wno-unused-parameter)
endif()

# --------------------------------------------------------------------------
# Platform linkage
# --------------------------------------------------------------------------
if(ANDROID)
    target_link_libraries(foundry_local_mobile PRIVATE log dl)
    target_link_options(foundry_local_mobile PRIVATE "-Wl,-z,max-page-size=16384")

    # OGA links ONNX Runtime dynamically on Android. Copy the matching ABI runtime
    # next to this target so AGP packages a complete set of shared libraries.
    if(TARGET onnxruntime-genai)
        get_target_property(_oga_link_dirs onnxruntime-genai LINK_DIRECTORIES)
        set(_ort_android_runtime "")
        foreach(_dir IN LISTS _oga_link_dirs)
            if(EXISTS "${_dir}/libonnxruntime.so")
                set(_ort_android_runtime "${_dir}/libonnxruntime.so")
                break()
            endif()
        endforeach()
        if(NOT _ort_android_runtime)
            message(FATAL_ERROR
                "The source-built OGA target does not expose its Android libonnxruntime.so. "
                "Pass a matching ORT_HOME or use the pinned staged OGA source.")
        endif()
        add_custom_command(TARGET foundry_local_mobile POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${_ort_android_runtime}"
                "$<TARGET_FILE_DIR:foundry_local_mobile>/libonnxruntime.so"
            COMMENT "Copying libonnxruntime.so next to Foundry Local Mobile"
        )
    endif()
elseif(APPLE)
    target_link_libraries(foundry_local_mobile PRIVATE "-framework Foundation")
    set_target_properties(foundry_local_mobile PROPERTIES
        OUTPUT_NAME FoundryLocalMobile
        FRAMEWORK TRUE
        FRAMEWORK_VERSION A
        MACOSX_FRAMEWORK_IDENTIFIER com.microsoft.ai.foundry.local.mobile
        MACOSX_FRAMEWORK_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING ${PROJECT_VERSION}
    )
elseif(UNIX)
    target_link_libraries(foundry_local_mobile PRIVATE dl pthread)
endif()

if(FLM_BUILD_SHARED AND NOT APPLE AND NOT MSVC)
    include(CheckLinkerFlag OPTIONAL RESULT_VARIABLE FLM_HAVE_CHECK_LINKER_FLAG)
    set(FLM_VERSION_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/flm.map")
    if(FLM_HAVE_CHECK_LINKER_FLAG)
        check_linker_flag(CXX "-Wl,--version-script=${FLM_VERSION_SCRIPT}" FLM_LINKER_ACCEPTS_VERSION_SCRIPT)
    else()
        set(FLM_LINKER_ACCEPTS_VERSION_SCRIPT ON)
    endif()
    if(FLM_LINKER_ACCEPTS_VERSION_SCRIPT)
        target_link_options(foundry_local_mobile PRIVATE "-Wl,--version-script=${FLM_VERSION_SCRIPT}")
        set_target_properties(foundry_local_mobile PROPERTIES LINK_DEPENDS "${FLM_VERSION_SCRIPT}")
    endif()
endif()

if(FLM_BUILD_EXAMPLES)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/examples/CMakeLists.txt")
        add_subdirectory(examples)
    else()
        message(WARNING "FLM_BUILD_EXAMPLES is ON but core/examples does not exist; skipping.")
    endif()
endif()

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS foundry_local_mobile
    EXPORT foundry_local_mobile-targets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    FRAMEWORK DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
