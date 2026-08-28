# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# The parent project() declares LANGUAGES CXX only, so C has to be turned on here.
# The whole point of this subdirectory is to compile the public headers as C: if a
# C++-only construct sneaks into flm_api.h or flm_types.h the four FFI bindings
# (Kotlin/JNI, Swift, Dart, TypeScript) all silently break at once, and the earliest
# we would otherwise find out is when someone tries to build an app.
enable_language(C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_executable(hello_flm hello_flm.c)

target_link_libraries(hello_flm PRIVATE foundry_local_mobile)

# Match the strictness the core builds under. -Werror in particular is what promotes
# a "compiles-but-warns as C" situation into a build failure — we do not want a
# warning that is easily missed on a green CI run to become the four-binding regression
# this whole example is here to prevent.
if(MSVC)
    target_compile_options(hello_flm PRIVATE /W4 /WX)
    target_compile_definitions(hello_flm PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(hello_flm PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
