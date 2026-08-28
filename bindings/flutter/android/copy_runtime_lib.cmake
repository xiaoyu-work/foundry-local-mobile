# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Post-build helper: find LIB_NAME under SRC_DIR and copy it to DST_DIR.
# Invoked by CMake add_custom_command via -P so it runs at build time when
# the nested OGA/ORT libraries have actually been produced or downloaded.

cmake_minimum_required(VERSION 3.20)

if(NOT DEFINED SRC_DIR OR NOT DEFINED DST_DIR OR NOT DEFINED LIB_NAME)
    message(FATAL_ERROR "copy_runtime_lib.cmake requires -DSRC_DIR, -DDST_DIR, and -DLIB_NAME")
endif()

file(GLOB_RECURSE _candidates "${SRC_DIR}/${LIB_NAME}")
list(LENGTH _candidates _count)

if(_count EQUAL 0)
    message(FATAL_ERROR "${LIB_NAME} not found under ${SRC_DIR}; the APK would be incomplete")
endif()

# Prefer the library from the requested Android ABI when multiple ORT packages
# are present in the build tree.
if(DEFINED ABI AND NOT ABI STREQUAL "")
    set(_abi_candidates "")
    foreach(_candidate IN LISTS _candidates)
        string(REPLACE "\\" "/" _normalized "${_candidate}")
        if(_normalized MATCHES "/${ABI}/")
            list(APPEND _abi_candidates "${_candidate}")
        endif()
    endforeach()
    if(_abi_candidates)
        set(_candidates "${_abi_candidates}")
    endif()
endif()
list(SORT _candidates)
list(GET _candidates 0 _src)

message(STATUS "Copying ${_src} -> ${DST_DIR}/${LIB_NAME}")
file(COPY "${_src}" DESTINATION "${DST_DIR}")
