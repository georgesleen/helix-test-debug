# Fixture firmware for tests/integration.sh. A cross CMake build, so the
# check exercises the file API the same way it would on a real project. The
# lines of blinky.c are stopped at by the check, so their numbering matters.
cmake_minimum_required(VERSION 3.20)
project(blinky C)

add_executable(blinky blinky.c)
target_link_libraries(blinky PRIVATE support)
set_target_properties(blinky PROPERTIES SUFFIX ".elf")
target_compile_options(blinky PRIVATE -mcpu=cortex-m0plus -mthumb -Og -g2)
target_link_options(blinky PRIVATE -mcpu=cortex-m0plus -mthumb -nostdlib -Wl,-e,main)

# A library too, so the file API has something that must NOT be picked.
add_library(support STATIC support.c)
target_compile_options(support PRIVATE -mcpu=cortex-m0plus -mthumb)
