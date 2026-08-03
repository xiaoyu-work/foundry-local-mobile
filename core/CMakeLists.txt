# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

cmake_minimum_required(VERSION 3.22)

project(foundry_local_mobile VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Hide everything that is not explicitly exported. The ABI surface is small and
# deliberate, and on Android a leaked symbol can collide with an app's own ONNX Runtime.
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
option(FLM_BUILD_SHARED "Build the shared library" ON)
option(FLM_BUILD_EXAMPLES "Build the native example programs" OFF)

# The core needs the upstream Foundry Local C headers to bind its API tables.
# Point this at <Foundry-Local>/sdk_v2/cpp/include, or let the fallback below find a
# sibling checkout, which is the common developer layout.
set(FLM_FOUNDRY_LOCAL_INCLUDE_DIR "" CACHE PATH "Path to the Foundry Local C SDK headers")

if(NOT FLM_FOUNDRY_LOCAL_INCLUDE_DIR)
    foreach(candidate
            "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/foundry-local/include"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../foundry-local/sdk_v2/cpp/include")
        if(EXISTS "${candidate}/foundry_local/foundry_local_c.h")
            set(FLM_FOUNDRY_LOCAL_INCLUDE_DIR "${candidate}")
            break()
        endif()
    endforeach()
endif()

if(NOT FLM_FOUNDRY_LOCAL_INCLUDE_DIR OR NOT EXISTS "${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}/foundry_local/foundry_local_c.h")
    message(FATAL_ERROR
        "Foundry Local headers not found. Run scripts/fetch_foundry_local.sh, or configure with "
        "-DFLM_FOUNDRY_LOCAL_INCLUDE_DIR=<path to Foundry-Local/sdk_v2/cpp/include>.")
endif()
message(STATUS "Foundry Local headers: ${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}")

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------
set(FLM_SOURCES
    src/error.cc
    src/handle_table.cc
    src/job.cc
    src/runtime.cc
    src/device_profile.cc
    src/model_package.cc
    src/manager.cc
    src/catalog.cc
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

target_include_directories(foundry_local_mobile
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}
)

target_compile_definitions(foundry_local_mobile PRIVATE FLM_BUILDING_SHARED)
target_link_libraries(foundry_local_mobile PRIVATE nlohmann_json::nlohmann_json)

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
    # `log` for __android_log_print, `dl` for the runtime loader.
    target_link_libraries(foundry_local_mobile PRIVATE log dl)

    # 16 KB page alignment is required for Android 15+ on 64-bit devices; without it the
    # library fails to load on newer hardware.
    target_link_options(foundry_local_mobile PRIVATE "-Wl,-z,max-page-size=16384")
elseif(APPLE)
    target_link_libraries(foundry_local_mobile PRIVATE "-framework Foundation")
    set_target_properties(foundry_local_mobile PROPERTIES
        FRAMEWORK TRUE
        FRAMEWORK_VERSION A
        MACOSX_FRAMEWORK_IDENTIFIER com.microsoft.ai.foundry.local.mobile
        MACOSX_FRAMEWORK_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING ${PROJECT_VERSION}
    )
elseif(UNIX)
    target_link_libraries(foundry_local_mobile PRIVATE dl pthread)
endif()

if(FLM_BUILD_EXAMPLES)
    add_subdirectory(examples)
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
