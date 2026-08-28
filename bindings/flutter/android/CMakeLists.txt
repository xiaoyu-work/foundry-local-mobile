# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.26)

project(foundry_local_mobile_plugin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Absolute path to the shared C++ core sources.
# The plugin lives at bindings/flutter/android; the core lives at core/.
get_filename_component(FLM_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(FLM_CORE_DIR "${FLM_REPO_ROOT}/core")

if(NOT EXISTS "${FLM_CORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "Could not locate the foundry_local_mobile core at ${FLM_CORE_DIR}. "
        "The Flutter plugin builds the core from source and must live inside the "
        "monorepo checkout.")
endif()

# Build the core as a shared library. It includes the Dart callback trampolines so
# DynamicLibrary.open('libfoundry_local_mobile.so') resolves everything through one
# handle.
set(FLM_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(FLM_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

add_subdirectory(${FLM_CORE_DIR} core-build)
