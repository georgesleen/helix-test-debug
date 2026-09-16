# Finding a CMake project's firmware

PlatformIO is not how most firmware is built. CMake is: Zephyr through
`west`, ESP-IDF through `idf.py`, the Pico SDK, STM32CubeMX's generated
projects, and hand-written cross builds with `arm-none-eabi-gcc` are all
CMake underneath. So the general answer to "which image do I flash" has to
come from CMake itself.

It does. CMake's **file API** answers it exactly, offline, for any project
and any toolchain: drop a query file in the build directory, configure, and
CMake writes a reply describing every target, its type, and the artifacts
it produces. No vendor knowledge, no globbing for `*.elf`, no assuming a
naming convention.

```
<build>/.cmake/api/v1/query/codemodel-v2      written by the cog, empty
<build>/.cmake/api/v1/reply/index-*.json      written by cmake
<build>/.cmake/api/v1/reply/codemodel-v2-*.json
<build>/.cmake/api/v1/reply/target-blinky-*.json
```

## `(cmake-cross-system? system)`

Whether the build targets another machine, from
`<build>/CMakeFiles/<version>/CMakeSystem.cmake`.

`CMAKE_CROSSCOMPILING` is *not* in `CMakeCache.txt`: it is derived, not
cached, which a first attempt at this got wrong. What is written to disk is
the pair CMake derives it from:

```cmake
set(CMAKE_HOST_SYSTEM_NAME "Linux")
set(CMAKE_SYSTEM_NAME "Generic")
```

- `#t` when both are assigned and differ, which is the same comparison
  CMake makes. `Generic` against `Linux` is the usual bare-metal case, but
  so is `Darwin` against `Linux`, and no list of systems appears here.
- `#f` when they are equal, and when either is missing: an unconfigured or
  half-written build directory is not evidence of cross-compiling.
- Quotes around the values are optional, since a hand-edited file may omit
  them.

## `(cmake-toolchain-file cache)`

The toolchain file a build was configured with, or `#f`.

A second, independent signal: a build may name `CMAKE_SYSTEM_NAME` on the
command line with no toolchain file, or use a toolchain file whose system
name matches the host. Either alone is enough to treat the build as cross.

- The value of `CMAKE_TOOLCHAIN_FILE` in the cache, which unlike
  `CMAKE_CROSSCOMPILING` really is cached.
- `#f` when unset or empty.

## `(cmake-build-type cache)`

The configured build type, or `#f` when the cache declares none.

The cog does not change it. A firmware project's optimisation level is its
own business, and rebuilding someone's image at `-O0` can push it past the
flash it has to fit in. This is read only to *say* when an image will have
no line table, which otherwise reads as a breakpoint the debugger ignored.

## `(build-type-debuggable? type flags)`

Whether an image built this way will carry line information.

- `#t` for `"Debug"` and `"RelWithDebInfo"`, whatever the case, since those
  are exactly the types that add debug flags.
- `#t` for any type when `flags` contains `-g`, so a project that adds it
  by hand in `CMAKE_C_FLAGS` is not wrongly warned about.
- `#f` for `"Release"`, `"MinSizeRel"`, and for `#f`, unless the flags say
  otherwise.

## `(codemodel-reply index)`

The name of the codemodel reply file, from the file API's `index-*.json`,
or `#f`.

- The `jsonFile` of the object whose `kind` is `codemodel`.
- `#f` when no object has that kind, and for text that is not JSON: an
  absent or half-written reply must not raise.

## `(codemodel-targets codemodel)`

The target reply files a codemodel names, as a list of `jsonFile` values,
across every configuration.

- The empty list for JSON with no configurations or no targets, and for
  text that is not JSON.
- Order is the order CMake wrote them, which is deterministic per
  configure.

## `(firmware-artifact targets source)`

The image to flash for the file under the cursor, as a path relative to the
build directory, or `#f`. `targets` is the text of every target reply the
codemodel named.

It is the one non-imported `EXECUTABLE` that either compiles `source` or
reaches a target that does, through `dependencies` in CMake's own graph.

Two things make both halves of that necessary:

- A real SDK build has several executables. The Pico SDK's codemodel also
  names `picotool`, `pioasm` and a boot stage, so "the only executable" is
  not an answer. Ownership of the source is.
- A build system may compile the user's own code into a library. ESP-IDF
  puts `main.c` in its `__idf_main` component and builds the executable
  from a *generated empty* source (`project.cmake`: `add_executable(
  ${project_elf} "${project_elf_src}")`), so no executable owns `main.c`
  at all. Following the link graph finds it; ownership alone finds nothing.

Neither rule names a vendor, a component system, a filename or an
extension: `dependencies` is the same field for every generator and
toolchain.

- `#f` for none, and `#f` for several: if two executables both reach the
  source they cannot be distinguished safely, and flashing the wrong image
  means physically recovering the device.
- `#f` for a target with no artifacts, and for replies that are not JSON:
  a half-written reply must not raise.
- A diamond in the graph is walked once and a cycle terminates, since an
  editor command must not hang on either.
