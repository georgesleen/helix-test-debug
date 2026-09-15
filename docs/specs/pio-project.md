# Driving a PlatformIO project

PlatformIO's unit of execution is a test folder, not a test function:
`pio test` builds one program per folder under `test/` and runs every
registered test in it. So a single Unity test is debugged by building its
folder's program and stopping at the test's first line — there is no filter
to pass, which is why this reuses the `program at line` template.

`pio test --list-tests` names only folders, never functions, so discovery is
the source's job. See `docs/specs/unity-cursor-to-test.md`.

## `(pio-environments text)`

The environment names an `platformio.ini` declares, in the order declared.

- One entry per `[env:NAME]` section header, with `NAME` trimmed.
- A bare `[env]` section is the defaults for every environment, not an
  environment, and is excluded.
- `[platformio]` and any other section are excluded.
- Leading whitespace before the header is allowed; a header with trailing
  text after the closing bracket is still the header.
- The empty list when nothing declares an environment, which is what a
  malformed or missing file looks like.
- Names are returned verbatim, duplicates kept.

## `(pio-environment text)`

The environment to build, or `#f` when there is none.

- An environment named `native` when the file declares one, because that is
  the one that builds for the host and is therefore the one a local
  debugger can attach to.
- Otherwise the first declared environment: a project with a single
  embedded environment should still resolve, and reporting the wrong one is
  better than reporting none, since the launch will name it.
- `#f` for no environments.

## `(pio-test-folder relative-path)`

The test folder a source file belongs to, or `#f`.

- `test/test_divider/test_divider.c` is `test_divider`: the first segment
  under `test/`.
- `test/test_divider/helpers/util.c` is also `test_divider`; everything
  below the folder belongs to it.
- `test/test_main.c` is `#f`. A file directly under `test/` is built into
  every folder's program by PlatformIO's rules rather than being a folder of
  its own, so there is no single program to launch.
- `#f` for a path whose first segment is not `test`, and for a bare file
  name.

## `(pio-build-arguments environment folder)`

The invocation that builds a folder's test program without running it:
`("test" "-e" environment "-f" folder "--without-testing")`.

- `--without-testing` is what separates building from running; a debugger
  needs the program, not its output.

## `(pio-debug-build environment folder)`

The same build, forced to carry debug info, as an argument list for `sh`.

A PlatformIO `native` build has no `-g`, so a breakpoint on it resolves to
no locations and the program runs to completion: the failure looks like the
breakpoint was ignored rather than like a build problem. PlatformIO takes
the flags from `PLATFORMIO_BUILD_FLAGS`, and it has no command-line
equivalent, so the build has to run under a shell that sets it. Steel's
process API cannot set a child's environment.

- The first element is `-c`, the second a script that exports the flags and
  execs `pio` with `"$@"`, and the rest are `pio` and the build arguments.
- Values reach the shell through `$@` and never through the script text, so
  an environment or folder name cannot be interpreted as shell syntax.
- The flags are `-g -O0`: a debugger needs line information, and an
  optimised build steps through lines out of order even when it has it.
- Only the build is wrapped. A run needs no debug info, so
  `pio-run-arguments` stays a plain `pio` invocation.

## `(pio-run-arguments environment folder)`

The invocation that builds and runs it: the same without
`--without-testing`.

## `(pio-program-path environment)`

Where PlatformIO leaves the built program, relative to the project root:
`.pio/build/<environment>/program`.

- The name is fixed for every test folder in an environment; the folder
  selected at build time decides which one is there, which is why the build
  and the launch must name the same folder.

## `(pio-outcome output)`

What `pio test` reported, or `#f`.

- The trimmed summary line, which reads
  `3 test cases: 3 succeeded in 00:00:06.519`, recognised by the
  `test cases:` marker rather than by the counts.
- The last such line when several are printed, as one appears per
  environment.
- `#f` when no line carries the marker, which is what a build failure looks
  like.
- The `=` rules PlatformIO draws around the summary are stripped, so the
  line can go straight on the statusline.
