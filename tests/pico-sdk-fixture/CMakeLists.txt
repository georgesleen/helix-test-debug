# Fixture firmware for tests/hardware-check.sh: a real Pico SDK project, so
# the check faces the codemodel a real SDK produces rather than a reduced
# one. That is the shape that broke an earlier version of the selection
# rule, which assumed a project builds a single executable.
#
# pico_sdk_import.cmake is taken from PICO_SDK_PATH rather than vendored, so
# nothing here has to be kept in step with an SDK release.
cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(pico_sdk_fixture C CXX ASM)

pico_sdk_init()

add_executable(pico_sdk_fixture main.c)
target_link_libraries(pico_sdk_fixture pico_stdlib)
