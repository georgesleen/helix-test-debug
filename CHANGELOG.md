# Changelog

Versions stay below 1.0.0 while the command surface and the Steel API it
depends on are still moving. Breaking changes may land in any 0.y bump.

## Unreleased

- PlatformIO and Unity: `:debug-here` builds a test folder's program and
  stops in the test under the cursor. A `RUN_TEST` call in the folder is
  what makes a function a test, since Unity marks nothing. `:run-here` runs
  the folder and reports PlatformIO's summary.
- A workspace can declare a breakpoint budget, for targets with a fixed
  number of hardware breakpoints.
- The commands are renamed: `:test-debug` is `:debug-here` (alias `:dbgh`),
  `:test-run` is `:run-here`, and the other `test-` commands that are no
  longer test-specific take the `debug-` prefix. `:test-pick` keeps its
  name, being the one command that is only about tests.

- A line that is not in a test is debuggable: `:debug-here` builds the
  crate's binary and stops at the cursor. `:run-here` runs it and reports
  its last line, `:debug-failure` stops where it panicked. Needs the
  new `program at line` template.

- `:debug-breakpoint` remembers a breakpoint in
  `.helix/test-debug-breakpoints` under the workspace root, and it is placed
  again on the first launch after a restart. `:debug-breakpoints` and
  `:debug-breakpoints-clear` drive it by hand.

- `:test-pick` picks a test from anywhere in the crate and debugs it: type
  to filter by subsequence, up and down to move, enter to debug. Rust only.
- Removed the libtest `--list` parser. Discovery reads the sources instead,
  which needs no build and yields the line to stop on.

- C and C++ support for `:debug-here`, through CMake and ctest. Detection is
  a macro table covering GoogleTest, Catch2, doctest and Boost; ctest is the
  authority on which tests exist and how they are run.
- The pure half is split into one module per spec under `test-debug/`, with
  only `test-debug/rust/` and `test-debug/cpp/` knowing a language.

- Commands renamed for discoverability: `test-debug`, `test-run`,
  `test-again`, `test-doctor` act on the test under the cursor; `debug-*`
  act on a running session.
- `:debug-failure` runs the test and, when it fails, starts a session
  stopped at the line that panicked.
- `:debug-cancel` abandons the wait on a build in flight.
- A dirty buffer is written before building.
- `docs/specs/` holds one behavioural spec per concern. The tests for this
  round were written from those specs by an author who could not see the
  implementation.

## 0.1.0

- `:debug-test` builds the cargo test target holding the cursor and starts a
  debug session stopped on the test's first line.
- `:run-test` runs that test without a debugger and reports its result.
- `:debug-test-again` repeats the last request from any buffer.
- `:debug-variables` shows the variables popup and keeps it fresh, which
  Helix's own snapshot popup does not do.
- `:debug-step-over`, `:debug-step-in`, `:debug-step-out` and
  `:debug-continue` step and then refresh that popup.
- Tests are selected by full module path with `--exact`, so exactly one runs.
- Builds run off the editor thread, with elapsed time on the statusline.
