# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.26)

project(foundry_local_mobile_android LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(FLM_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(FLM_CORE_DIR "${FLM_REPO_ROOT}/core")

if(NOT EXISTS "${FLM_CORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Foundry Local Mobile core not found at ${FLM_CORE_DIR}. Check the repository layout.")
endif()

set(FLM_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FLM_BUILD_SHARED   ON  CACHE BOOL "" FORCE)

add_subdirectory("${FLM_CORE_DIR}" "${CMAKE_BINARY_DIR}/flm_core" EXCLUDE_FROM_ALL)

add_library(foundry_local_mobile_jni SHARED
    jni_common.cc
    jni_manager.cc
    jni_model.cc
    jni_session.cc
    jni_job.cc
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
)

target_link_options(foundry_local_mobile_jni PRIVATE
    "-Wl,-z,max-page-size=16384"
)

find_library(ANDROID_LOG_LIB log)
find_library(ANDROID_LIB android)

target_link_libraries(foundry_local_mobile_jni PRIVATE
    foundry_local_mobile
    ${ANDROID_LOG_LIB}
    ${ANDROID_LIB}
)

# --------------------------------------------------------------------------
# Package OGA and ORT shared libraries into jniLibs so Gradle ships them in
# the AAR. AGP only auto-packages libraries that are direct CMake targets or
# live under src/main/jniLibs. The nested OGA subdirectory build produces
# libonnxruntime-genai.so as a CMake target, and ORT's libonnxruntime.so is
# downloaded by cmake/ortlib.cmake into the build tree. We copy both into the
# CMake output directory so AGP's jniLibs scanner picks them up alongside
# libfoundry_local_mobile.so and libfoundry_local_mobile_jni.so.
# --------------------------------------------------------------------------

# libonnxruntime-genai.so — produced by the OGA add_subdirectory.
if(TARGET onnxruntime-genai)
    add_custom_command(TARGET foundry_local_mobile_jni POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:onnxruntime-genai>
            $<TARGET_FILE_DIR:foundry_local_mobile_jni>/$<TARGET_FILE_NAME:onnxruntime-genai>
        COMMENT "Copying libonnxruntime-genai.so for AAR packaging"
    )
endif()

# libonnxruntime.so — fetched by OGA's cmake/ortlib.cmake. ORT_LIB_DIR is set
# in the OGA child scope; ONNXRUNTIME_LIB_DIR is set there too. Both are
# propagated as cache variables, and also available at the parent scope via the
# OGA build. Use a post-build find-and-copy since the exact path depends on
# whether ORT_HOME was provided or ORT was auto-downloaded.
add_custom_command(TARGET foundry_local_mobile_jni POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -DSRC_DIR=${CMAKE_BINARY_DIR}
        -DDST_DIR=$<TARGET_FILE_DIR:foundry_local_mobile_jni>
        -DLIB_NAME=libonnxruntime.so
        -DABI=${ANDROID_ABI}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/copy_runtime_lib.cmake
    COMMENT "Copying libonnxruntime.so for AAR packaging"
)
