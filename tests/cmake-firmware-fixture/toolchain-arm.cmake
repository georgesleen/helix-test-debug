# Minimal bare-metal toolchain file. Naming CMAKE_SYSTEM_NAME is what makes
# CMake set CMAKE_CROSSCOMPILING, which is the signal the cog reads.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
