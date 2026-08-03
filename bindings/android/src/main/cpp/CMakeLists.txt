# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Builds two shared libraries into each ABI slice of the AAR:
#   * libfoundry_local_mobile.so — the C++ core (built from ../../../../../core).
#   * libfoundry_local_mobile_jni.so — the JNI bridge in this directory, which
#     links against the core and is loaded by System.loadLibrary("foundry_local_mobile_jni").
#
# The core is a plain SHARED library so it can be dlopened independently by
# unit-test hosts or other bindings inside the same process. The JNI wrapper is
# a separate .so because a symbol clash between the core's exports (flm_*) and
# the JNI entry points (Java_com_microsoft_*) would only surface at runtime.

cmake_minimum_required(VERSION 3.22)

project(foundry_local_mobile_android LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --------------------------------------------------------------------------
# Locate the core sources.
#
# The Android module lives at bindings/android relative to the repository root,
# and the core lives at core/ from that same root. Gradle sets CMAKE_SOURCE_DIR
# to this file's directory, which is bindings/android/src/main/cpp.
# --------------------------------------------------------------------------
get_filename_component(FLM_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(FLM_CORE_DIR "${FLM_REPO_ROOT}/core")

if(NOT EXISTS "${FLM_CORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Foundry Local Mobile core not found at ${FLM_CORE_DIR}. "
                        "Check the repository layout.")
endif()

# Turn off examples in the nested build.
set(FLM_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FLM_BUILD_SHARED   ON  CACHE BOOL "" FORCE)

add_subdirectory("${FLM_CORE_DIR}" "${CMAKE_BINARY_DIR}/flm_core" EXCLUDE_FROM_ALL)

# --------------------------------------------------------------------------
# JNI bridge
# --------------------------------------------------------------------------
add_library(foundry_local_mobile_jni SHARED
    jni_common.cc
    jni_manager.cc
    jni_model.cc
    jni_session.cc
    jni_job.cc
    jni_transport.cc
    jni_log.cc
)

target_include_directories(foundry_local_mobile_jni PRIVATE
    ${FLM_CORE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_options(foundry_local_mobile_jni PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    # JNI entry points are extern "C" and marked JNIEXPORT; no other exports.
)

target_link_options(foundry_local_mobile_jni PRIVATE
    # 16 KB page alignment for Android 15+ arm64.
    "-Wl,-z,max-page-size=16384"
)

# `log` for __android_log_print via the shared core, `android` for AAssetManager
# in case a future revision of the bridge streams assets directly to native code.
find_library(ANDROID_LOG_LIB log)
find_library(ANDROID_LIB android)

target_link_libraries(foundry_local_mobile_jni PRIVATE
    foundry_local_mobile
    ${ANDROID_LOG_LIB}
    ${ANDROID_LIB}
)
