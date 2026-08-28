# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.26)

project(foundry_local_mobile_plugin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Absolute paths to the shared C++ core sources and the Dart bridge shim.
# The plugin lives at bindings/flutter/android; the core lives at core/.
get_filename_component(FLM_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(FLM_CORE_DIR "${FLM_REPO_ROOT}/core")
set(FLM_BRIDGE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")

if(NOT EXISTS "${FLM_CORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "Could not locate the foundry_local_mobile core at ${FLM_CORE_DIR}. "
        "The Flutter plugin builds the core from source and must live inside the "
        "monorepo checkout.")
endif()

# Build the core as a shared library. The Dart bridge symbols will be added to
# the same .so so ffi's DynamicLibrary.open('libfoundry_local_mobile.so') can
# resolve both the ABI and the trampolines through one handle.
set(FLM_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(FLM_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

add_subdirectory(${FLM_CORE_DIR} core-build)

# Compile the Dart bridge sources directly into the core .so. The alternative —
# a second .so — would force the plugin to open two libraries at runtime and
# would multiply symbol lookups. This is cheaper.
target_sources(foundry_local_mobile PRIVATE
    "${FLM_BRIDGE_DIR}/flm_dart_bridge.c"
)
target_include_directories(foundry_local_mobile PRIVATE "${FLM_BRIDGE_DIR}")

# The bridge symbols must be reachable from dlsym for
# DynamicLibrary.lookup to find them. FLM_EXPORT already handles this on the
# core side; make sure the shim uses default visibility even when the core is
# built with -fvisibility=hidden.
set_source_files_properties(
    "${FLM_BRIDGE_DIR}/flm_dart_bridge.c"
    TARGET_DIRECTORY foundry_local_mobile
    PROPERTIES COMPILE_FLAGS "-fvisibility=default"
)

# --------------------------------------------------------------------------
# Package OGA and ORT shared libraries so Gradle ships them in the APK.
# The nested OGA subdirectory build produces libonnxruntime-genai.so as a
# CMake target, and ORT's libonnxruntime.so is fetched into the build tree.
# --------------------------------------------------------------------------
if(TARGET onnxruntime-genai)
    add_custom_command(TARGET foundry_local_mobile POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:onnxruntime-genai>
            $<TARGET_FILE_DIR:foundry_local_mobile>/$<TARGET_FILE_NAME:onnxruntime-genai>
        COMMENT "Copying libonnxruntime-genai.so for Flutter APK packaging"
    )
endif()

# Use a post-build script to locate libonnxruntime.so in the build tree,
# since ORT_LIB_DIR is set in the OGA child scope.
add_custom_command(TARGET foundry_local_mobile POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -DSRC_DIR=${CMAKE_BINARY_DIR}
        -DDST_DIR=$<TARGET_FILE_DIR:foundry_local_mobile>
        -DLIB_NAME=libonnxruntime.so
        -DABI=${ANDROID_ABI}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/copy_runtime_lib.cmake
    COMMENT "Copying libonnxruntime.so for Flutter APK packaging"
)
